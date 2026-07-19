# NestJS DI — Injection Scopes (Lesson 2b)

> Long-form walkthrough: why scopes exist, the three of them, the contagious cost of REQUEST scope, and AsyncLocalStorage as the cheaper way to get per-request context. Builds on `02a-nestjs-di-wiring.md`; distilled in `02-nestjs-di-scopes.md`.

---

## The tension: a singleton meets interleaving

Two facts from earlier collide here:

- **DI default:** every provider is one shared instance for the whole app lifetime.
- **Async runtime:** requests interleave at every `await` — request A parks, request B runs on the same thread, A resumes later.

Put them together and you get a real bug. A singleton that remembers "the current request's user" in a field:

```ts
// ❌ Singleton (default scope) holding per-request state
@Injectable()
export class RequestContext {
  private userId: string;            // ONE field, shared by every request
  setUser(id: string) { this.userId = id; }
  getUser() { return this.userId; }
}
```

Trace two interleaved requests through the *same* instance:

```
Request A: setUser('alice')      → field = 'alice'
Request A: await loadOrders()    → A parks at the yield point
Request B: setUser('bob')        → field = 'bob'   (ran in A's gap)
Request A: resumes, getUser()    → 'bob'  ❌  A now sees B's user
```

Not a rare race — the *default* outcome under load, and a genuine security bug (one user reading another's identity).

> **A singleton is safe only if it holds no per-request mutable state.** Stateless services (a reward HTTP client, a repository) are perfect singletons. The moment a provider must remember something *about the current request*, a single shared instance can't do it safely.

## The three scopes, built on each other

Three lifetimes a provider can have — each relaxes the sharing of the one before.

- **`Scope.DEFAULT` — singleton.** One instance, created once at bootstrap, reused forever. Cheapest and fastest; correct for anything stateless. The default because it's what you want ~95% of the time.
- **`Scope.REQUEST` — one instance per request.** A fresh instance per incoming request, used for that request only, then discarded. Two interleaved requests get two separate instances → the leak above disappears.
- **`Scope.TRANSIENT` — a fresh instance per consumer.** Every provider that injects a transient gets its own private copy; never shared between injectors.

```ts
import { Injectable, Scope } from '@nestjs/common';

@Injectable()                              // DEFAULT — singleton
export class RewardClient {}

@Injectable({ scope: Scope.REQUEST })      // one per request
export class RequestContext {}

@Injectable({ scope: Scope.TRANSIENT })    // one per injecting consumer
export class ScratchpadHelper {}
```

## What REQUEST scope buys you: the request object

The main reason to reach for `REQUEST` is that a request-scoped provider can inject the *actual request object* — now there genuinely is "a request" tied to this instance:

```ts
import { Inject, Injectable, Scope } from '@nestjs/common';
import { REQUEST } from '@nestjs/core';
import { Request } from 'express';

@Injectable({ scope: Scope.REQUEST })
export class CurrentUser {
  constructor(@Inject(REQUEST) private readonly req: Request) {}
  get id(): string | undefined { return (this.req as any).user?.id; }
}
```

MO-specific detail: `REQUEST` is the HTTP token. When the "request" is a **RabbitMQ message** via the microservice transport, inject `CONTEXT` instead of `REQUEST` to reach the message context. Same scope concept, different entry token — relevant since half the traffic isn't HTTP.

## The senior payload: REQUEST scope is contagious

If a request-scoped provider is injected into another provider, what scope is *that* provider? It **cannot** be a singleton — a singleton is built once and lives forever, but it now depends on something rebuilt every request. So scope **bubbles up the injection chain**:

```
CurrentUser         (REQUEST, injects the request)
   ↓ injected into
OrdersService       (becomes REQUEST — can't be a singleton anymore)
   ↓ injected into
OrdersController    (becomes REQUEST too)
```

> **Everything on a request-scoped chain is re-instantiated on every request.** The container walks that sub-graph and builds fresh instances per request instead of once at boot. On a hot path under high traffic (e.g. a busy Cloud Run instance), that per-request construction adds latency and GC pressure — the opposite of the cheap singleton default.

So `REQUEST` isn't free isolation; it's isolation you pay for on every request, and the bill grows with how far up the chain it bubbles. One request-scoped leaf can quietly turn a whole controller's tree request-scoped.

*(Advanced escape hatch: **durable providers** mitigate this for multi-tenant setups by sharing instances per-tenant rather than per-request. Named so it isn't a surprise later; not an early reach.)*

## The better default for per-request context: AsyncLocalStorage

What we usually want: a correlation ID (and maybe user/tenant) set once at the start of a request and readable *anywhere* deeper — services, logger, wherever. Making every consumer request-scoped (and paying the bubbling cost) is a heavy way to get it.

`AsyncLocalStorage` (ALS, from Node's `async_hooks`) gives per-request data **while every service stays a singleton**.

> **ALS is like a thread-local, but for async execution flows.** You start a "store" at the request boundary; it stays attached to the request's logical async chain — across every `await`, promise, timer, callback — so any code running "inside" that request can read it, however deep.

Why it's safe under interleaving — the async model doing the work: even though A and B interleave on one thread, Node tracks which async context each continuation belongs to. When A resumes after its `await`, it resumes inside A's store; B's never bleeds in, because they're different async contexts.

```ts
// context.ts
import { AsyncLocalStorage } from 'node:async_hooks';
export interface RequestStore { requestId: string; userId?: string; }
export const als = new AsyncLocalStorage<RequestStore>();
```

```ts
// runs first for each request; establishes the store for everything downstream
export function contextMiddleware(req, res, next) {
  const store: RequestStore = {
    requestId: req.headers['x-request-id'] ?? crypto.randomUUID(),
  };
  als.run(store, () => next());   // the whole request runs "inside" this store
}
```

```ts
// a plain SINGLETON — no scope change — yet it reads per-request data
@Injectable()
export class AuditLogger {
  log(message: string) {
    const store = als.getStore();
    console.log(JSON.stringify({
      message,
      requestId: store?.requestId,   // this request's ID
      userId: store?.userId,
    }));
  }
}
```

`AuditLogger` is a singleton (built once, fast), injected normally everywhere, and *still* logs the correct per-request `requestId` — `getStore()` returns whichever request's store is currently in flight. No bubbling, no per-request instantiation. This is the machinery Topic 4 uses to thread a correlation ID through every log line and across service calls. (In practice, `nestjs-cls` wraps ALS with nicer NestJS ergonomics; the raw version above is the whole idea.)

## Decision frame

| Need | Use | Why |
|------|-----|-----|
| Stateless service (client, repo, most things) | **DEFAULT** (singleton) | Cheapest; built once |
| Per-request context read by many services (correlation ID, user, tenant) | **AsyncLocalStorage** | Per-request data, all singletons, no bubbling |
| A provider that truly needs the injected request/message object | **REQUEST** scope | The one legit case; accept the cost |
| Each consumer needs its own private, unshared instance | **TRANSIENT** | Isolation between injectors |

> **Rules of thumb:**
> 1. Default to singleton; keep services stateless.
> 2. *Never* store per-request state in a singleton field.
> 3. Prefer ALS over `REQUEST` scope for ambient per-request context — same isolation, far cheaper.
> 4. Reach for `REQUEST` only when you genuinely need the request/message object injected, and know it bubbles.
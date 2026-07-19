# The NestJS Request Pipeline — The Map (Lesson 3a)

> Long-form walkthrough: why the pipeline exists, what each stage is *for*, why they run in that order, and the one abstraction (`ExecutionContext`) that makes components work across HTTP *and* RabbitMQ. Built bottom-up. Distilled version: `03-request-pipeline.md`; interceptors & validation: `03b-interceptors-validation.md`.

---

## Where we start: the same chores wrap every request

Think about what actually has to happen around a single endpoint like "complete an order." Before your business logic runs, *something* must check the caller is authenticated and allowed. The incoming body must be validated. You probably want a log line and a timing measurement. If anything throws, it must become a clean HTTP response, not a raw crash. The response might need a consistent shape.

Now notice: **none of that is the order-completion logic itself.** It's the same set of chores that wraps *every* endpoint. Write those chores inside each controller method and two bad things happen:

- **Duplication** — the auth check, the validation, the try/catch, the logging get copy-pasted into every handler. Change the log format and you edit fifty methods.
- **Tangled logic** — your actual business logic drowns in boilerplate. The one interesting line ("grant the reward") is buried under twenty lines of plumbing.

These wrapping chores have a name: **cross-cutting concerns** — behavior that applies *across* many handlers rather than belonging to any one of them. The request pipeline exists to solve exactly this.

> **The core idea:** pull each cross-cutting concern *out* of the handler and into a dedicated stage that wraps it. The handler shrinks back to pure business logic; each concern lives in one place, written once, applied everywhere.

This is separation of concerns applied to the *lifecycle* of a request. NestJS gives you a fixed sequence of stages, each owning one kind of concern.

## The stages, in order, each with one job

The full path a request takes — read it as "a series of wrappers around your handler," outermost first:

```
Request
  → Middleware          "raw HTTP-level setup"
  → Guards              "may this request proceed?"          (yes/no)
  → Interceptors (pre)  "wrap the handler — start timing, set up context"
  → Pipes               "validate & transform the handler's inputs"
  → ROUTE HANDLER       your controller method → services    (the actual work)
  → Interceptors (post) "transform/observe the outgoing result"
  → Exception filters   "turn any thrown error into a response" (only if something threw)
Response
```

**Middleware** — runs first, at the raw HTTP level. It knows almost nothing about *which* handler will eventually run; it just sees the request and response objects, like classic Express middleware. This is where you do transport-level setup that doesn't depend on the route: attaching a request ID, setting up an ALS store, low-level parsing.

```ts
export function contextMiddleware(req, res, next) {
  als.run({ requestId: req.headers['x-request-id'] ?? crypto.randomUUID() }, () => next());
}
```

**Guards** — answer one yes/no question: *should this request be allowed to continue?* Authentication and authorization. A guard returns a boolean (or throws); `false` stops the request cold with a 403. Guards run *after* middleware because they can inspect **which route/handler** is being called and its metadata (e.g. a `@Roles('admin')` decorator), which middleware can't see.

```ts
@Injectable()
export class RolesGuard implements CanActivate {
  canActivate(ctx: ExecutionContext): boolean {
    const required = this.reflector.get('roles', ctx.getHandler()); // reads route metadata
    const user = ctx.switchToHttp().getRequest().user;
    return required ? required.includes(user?.role) : true;         // yes/no
  }
}
```

**Interceptors (the "before" half)** — wrap the handler on both sides. On the way *in* they can start a timer, set up context, or bind something to the call. Their real power is the "after" half and the RxJS stream — see Lesson 3b.

**Pipes** — operate on the **handler's actual inputs**: the body, query params, route params. Their job is *validation* ("is this DTO shaped correctly?") and *transformation* ("turn this `"42"` string into the number `42`"). Pipes run last before the handler precisely because they work on the arguments the handler is about to receive.

```ts
@Post()
completeOrder(@Body() dto: CompleteOrderDto) { /* dto is already validated by the time we're here */ }
```

**Route handler** — your controller method. By the time execution reaches here, the caller is authenticated and authorized, the input is validated and typed, context and timers are set up. The handler can be *pure business logic*.

**Interceptors (the "after" half)** — see the handler's result on its way out. Log the outcome, measure duration, reshape the response into a standard envelope.

**Exception filters** — the safety net. If *anything* above throws — a guard, a pipe, the handler, a service — execution jumps here, and the filter turns that error into a proper HTTP response. This is the `AllExceptionsFilter` from the error-handling note; here just place it in the sequence: it's the final `catch` around the whole pipeline.

> **Mental model:** the pipeline is a set of nested wrappers around your handler. Middleware is the outermost, transport-level layer; guards decide entry; pipes clean the inputs; interceptors wrap behavior around the call; filters catch whatever escapes. The handler in the middle stays clean.

## Why the order is exactly this

The order isn't arbitrary — it follows two principles that tell you where to put *new* behavior later.

**1. Each stage needs what the earlier ones established.** Guards need the route metadata that only exists once routing has happened (after middleware). Pipes need to know which handler's arguments they're validating. The handler needs validated input. Filters need something to have been thrown. Information accumulates down the pipeline.

**2. Cheap, broad rejections come before expensive, specific work.** Fail-fast applied to the lifecycle. A guard rejecting an unauthorized request should happen *before* pipes run expensive validation, which happens *before* the handler does real database work. Reject a bad request as early and as cheaply as possible, so you never pay for work it didn't earn.

```
unauthorized?   → rejected at the GUARD    (before any validation or DB work)
malformed body? → rejected at the PIPE     (before the handler runs)
business rule?  → handled in the HANDLER   (the expensive part, reached last)
```

> **Placement rule:** put a concern at the earliest stage that has enough information to handle it. Access decisions → guards (early, cheap). Input shape → pipes. "Wrap the actual call" behavior → interceptors. Error-to-response → filters (last).

## The one abstraction that ties it together: `ExecutionContext`

A problem hides in all of the above. A guard needs the request to read the user. An interceptor needs it to time the call. But **where does "the request" come from**, given these stages run in different places — and given that in a dual-transport backend, half the traffic isn't HTTP but RabbitMQ messages?

`ExecutionContext` is the answer. It's an abstraction over "whatever triggered this handler," regardless of transport. It hands you two things: *what* is running (`getHandler()` and `getClass()` — the method and controller, used to read metadata/decorators) and *the underlying arguments*, which you unwrap by transport:

```ts
canActivate(ctx: ExecutionContext) {
  // HTTP request?           → switchToHttp().getRequest()
  // RabbitMQ / RPC message? → switchToRpc().getData()
  // WebSocket?              → switchToWs().getClient()
  const req = ctx.switchToHttp().getRequest();
}
```

This is why the *same* guard, interceptor, or filter can protect both an HTTP endpoint and a RabbitMQ message handler — you just unwrap the right context. A logging interceptor or an auth guard written against `ExecutionContext` works across both surfaces.

One important caveat follows: **middleware is HTTP-only.** It's an Express-level concept, so it does *not* run for RabbitMQ message handlers. Guards, interceptors, pipes, and filters *do* (via `ExecutionContext`). So a `contextMiddleware` that sets up an ALS store works for HTTP requests, but for RabbitMQ consumers you set that context up in an **interceptor** instead — covered in Lesson 3b.

> **Mental model:** `ExecutionContext` = "the current invocation, transport-agnostic." `getHandler()`/`getClass()` for metadata; `switchToHttp()`/`switchToRpc()`/`switchToWs()` to get the raw request/message. Write pipeline components against it and they work everywhere — except middleware, which is HTTP-only.

## Decision frame: which construct for which job

| I want to… | Use | Runs | Signature/shape |
|------------|-----|------|-----------------|
| Raw HTTP setup (request ID, ALS store, low-level parsing) | **Middleware** | first, HTTP-only | `(req, res, next)` |
| Decide if the request may proceed (authn/authz) | **Guard** | after middleware | returns boolean / throws |
| Validate or transform the handler's inputs | **Pipe** | just before handler | transforms an argument |
| Wrap behavior around the call (timing, logging, response reshape, timeouts, caching) | **Interceptor** | around handler | RxJS stream (Lesson 3b) |
| Turn a thrown error into an HTTP response | **Exception filter** | on throw, last | `catch(exception, host)` |

Two rules of thumb that resolve most "which one?" confusion:

- **Guard vs interceptor:** if the question is a *yes/no gate* ("is this allowed?"), it's a guard. If you're *wrapping or transforming* the call/result, it's an interceptor.
- **Middleware vs interceptor:** if it needs route/handler awareness or must work for RabbitMQ too, it's an interceptor; if it's pure raw-HTTP plumbing, middleware is fine.

---

## The build, in order

**cross-cutting concerns** (why the pipeline exists) → **the ordered stages** (each with one job) → **why that order** (accumulating info + fail-fast) → **`ExecutionContext`** (the transport-agnostic glue, and middleware's HTTP-only caveat) → **decision frame**. The interceptor stage is deliberately parked here — its power needs RxJS, which is where Lesson 3b starts.
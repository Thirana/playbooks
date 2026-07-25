# Error Handling in JavaScript / TypeScript (Lesson — General)

> The language-level model, independent of any framework: how `throw` and promises actually behave, and the decisions you make at every `catch`. The NestJS-specific half is `error-handling-b-nestjs.md`. Distilled reference: `error-handling-js-ts-nestjs.md`.
>
> Almost every error-handling bug comes from applying a *synchronous* mental model to *asynchronous* code. So we build the model sync-first, then async.

---

## What `throw` actually does

`throw` immediately stops the current line and **unwinds the call stack** — walking back up through each caller looking for a `try` whose `catch` will take the error. First match handles it; execution resumes after that `try/catch`. Nothing catches it → "uncaught," which in Node crashes the process (or hits a global handler).

The key word is **synchronous**: the unwinding happens now, along the chain of calls currently live on the stack.

```ts
function parsePrice(raw: string): number {
  const n = Number(raw);
  if (Number.isNaN(n)) throw new Error(`not a number: ${raw}`);
  return n;
}

try {
  const price = parsePrice(req.query.price);   // if it throws, unwinds to here
  applyDiscount(price);
} catch (e) {
  // ✅ caught — parsePrice and applyDiscount are on the same synchronous stack
}
```

This model is correct — but *only* for synchronous code. Backends are almost entirely asynchronous.

## Why asynchronous code breaks that model

The single most important idea:

> **A rejected Promise does not travel up the call stack — because by the time it rejects, the stack that started it is already gone.**

When you call an async operation (`db.findUser(id)`, an HTTP call), it starts I/O and **returns immediately** with a pending Promise. Your function keeps running and its stack unwinds normally. Milliseconds later the operation settles — but the original stack no longer exists, so there's nothing above it to unwind into.

A rejection is therefore **a value stored on the promise** ("failed, here's why"), not a throw in flight. You only receive it by explicitly asking — `await` or `.catch()`. This is why the classic mistake fails silently:

```ts
// ❌ try/catch around an UN-awaited async call catches NOTHING
function loadUser(id: string) {
  try {
    const user = db.findUser(id);   // returns a pending promise; try block finishes instantly
    return user;
  } catch (e) {
    // never runs; if findUser rejects it becomes an UnhandledPromiseRejection
  }
}
```

## `await` is the bridge back

`await` re-throws a rejection as a synchronous-style throw **at that line**, inside your `async` function — reconnecting it to normal `try/catch`:

```ts
// ✅ await turns the rejection into a throw here, so catch sees it
async function loadUser(id: string) {
  try {
    return await db.findUser(id);
  } catch (e) {
    // runs on rejection
  }
}
```

> **A `try/catch` around an async call is only meaningful if you `await` inside it.** Wrapping an un-awaited promise catches nothing.

## An `async` function *always* returns a Promise — even when it throws

Inside `async`, a plain `throw` becomes a **rejected promise** to the caller — not a synchronous throw:

```ts
async function chargeCard(amount: number) {
  if (amount <= 0) throw new Error('amount must be positive');   // → rejected promise
  return gateway.charge(amount);
}

chargeCard(-5);                          // ❌ nothing catches this synchronously
try { chargeCard(-5); } catch (e) {}     // ❌ never catches
try { await chargeCard(-5); } catch (e) {} // ✅ caught
```

Consequence: once any function in a chain is `async`, **every caller up the chain must `await` (or `.catch`)** to stay in control. One missing `await` breaks the whole chain:

```ts
// ❌ missing await — the failure is lost, and we return success anyway
async function completeCheckout(order: Order) {
  chargeCard(order.total);        // fire-and-forget: rejection vanishes
  return { status: 'confirmed' }; // lies to the caller if the charge failed
}

// ✅
async function completeCheckout(order: Order) {
  await chargeCard(order.total);  // failure propagates; caller can react
  return { status: 'confirmed' };
}
```

## The gotchas that escape `try/catch` entirely

Even `await` can't save you from these.

**Timers / deferred callbacks** run later on a fresh stack:

```ts
// ❌ the throw fires 100ms later, on its own stack — this catch is dead code
try {
  setTimeout(() => { throw new Error('retry tick failed'); }, 100);
} catch (e) {}

// ✅ handle inside the callback
setTimeout(() => {
  try { runRetry(); } catch (e) { logger.error({ e }, 'retry tick failed'); }
}, 100);
```

**Node event emitters** (streams, sockets, some DB clients) signal failure via an `'error'` *event*, not a rejection. No listener → uncaught exception:

```ts
// ❌ a mid-stream failure crashes the process
const rows = db.queryStream('SELECT * FROM orders');
for await (const row of rows) process(row);
// nothing listening for rows.emit('error', ...)

// ✅
rows.on('error', (err) => logger.error({ err }, 'order stream failed'));
```

**`Promise.all` fails fast** — rejects on the first rejection, discarding the other results:

```ts
// ❌ if the notification fails, the successful reward result is thrown away
await Promise.all([sendNotification(order), grantReward(order)]);

// ✅ both run to completion; decide per outcome
const [n, r] = await Promise.allSettled([sendNotification(order), grantReward(order)]);
if (n.status === 'rejected') {
  logger.warn({ reason: n.reason }, 'notification failed; reward still granted');
}
```

## The decision at every `catch`: swallow / re-throw / translate

Three legitimate choices. Picking the right one is most of the skill.

**1. Swallow** — handle and continue. Only when you can *genuinely recover*.

```ts
// ✅ legitimate: a real fallback path
async function getProfile(id: string) {
  try {
    return await cache.get(`profile:${id}`);
  } catch (err) {
    logger.warn({ err, id }, 'cache miss/error; reading from db');
    return await db.getProfile(id);
  }
}

// ❌ swallow with no recovery — the failure silently disappears
async function grant(order: Order) {
  try { await rewardApi.grant(order); }
  catch (e) {}                              // reward never granted, nobody knows
}
```

**2. Re-throw unchanged** — you can't handle it here and you're not the layer that decides the outcome. Fine *if* the thing you re-throw is understood upstream.

**3. Translate / wrap** — catch a low-level, library-specific error and re-throw a *domain-appropriate* one. The professional default **at a boundary** between two worlds (e.g. the HTTP-client world vs your application's world).

```ts
// ❌ re-throwing a raw library error across a boundary
async function sendSms(to: string, body: string) {
  try {
    return await axios.post(SMS_URL, { to, body });
  } catch (error) {
    logger.error({ error }, 'sms failed');
    throw error;                    // callers now receive an AxiosError they don't understand
  }
}

// ✅ translate: extract what matters, throw something your app speaks
class SmsSendError extends Error {
  constructor(public readonly upstreamStatus?: number, options?: { cause?: unknown }) {
    super('failed to send SMS', options);
    this.name = 'SmsSendError';
  }
}

async function sendSms(to: string, body: string) {
  try {
    return await axios.post(SMS_URL, { to, body });
  } catch (error) {
    if (axios.isAxiosError(error)) {
      logger.error(
        { event: 'sms.send.failed', upstreamStatus: error.response?.status, data: error.response?.data },
        'SMS send failed',
      );
      throw new SmsSendError(error.response?.status, { cause: error });
    }
    throw new SmsSendError(undefined, { cause: error });
  }
}
```

Two things the ✅ version does that matter: it logs the **real reason** (`error.response?.data`) that the raw re-throw dropped, and it does so **once, at the boundary that understands the error** — not at every layer above.

> **The boundary test:** *"If I re-throw this exact object, will the layer above understand it?"* If it's an Axios/driver/library type, **translate** — don't re-throw.

## `catch (error)` is typed `unknown` — narrow before you touch it

Under strict TS (`useUnknownInCatchVariables`), the catch variable is `unknown`. Accessing `.response` or `.message` without narrowing is a compile error *and* unsafe at runtime:

```ts
// ❌ 'error' is of type 'unknown'
catch (error) {
  console.log(error.response.status);
}

// ✅ narrow first
catch (error) {
  if (axios.isAxiosError(error)) {
    error.response?.status;        // typed as AxiosError
  } else if (error instanceof Error) {
    error.message;                 // generic Error
  } else {
    logger.error({ error }, 'threw a non-Error value');  // someone did `throw 'oops'`
  }
}
```

Related red flag: **throwing a non-Error** (`throw 'failed'`) loses the stack trace and breaks every `instanceof Error` check downstream. Always `throw new Error(...)` (or a subclass).

## Operational vs programmer errors

The distinction that decides whether you handle at all.

- **Operational** — expected runtime failures in *correct* code: network down, provider rejected the request, invalid user input, disk full. **Not bugs.** Anticipate and handle (retry, fall back, clean error).
- **Programmer** — bugs: method on `undefined`, bad type assumption, off-by-one. **Do not "handle."** Catching a bug and continuing corrupts state. Let it bubble to a top-level handler, log loudly, often restart clean.

```ts
// ❌ catching a bug and continuing — hides it, corrupts downstream data
function orderTotal(order: Order) {
  try {
    return order.items.reduce((s, i) => s + i.price, 0);  // throws if items is undefined — a BUG
  } catch {
    return 0;                                              // now the order looks free
  }
}
```

Rule that connects this to severity: **`error` level should mean "a human may need to act."** Log handled/operational conditions at `warn`; reserve `error` for genuine failures, or you train yourself to ignore it.

## Preserving context when you wrap: `cause`

Translating shouldn't lose the original reason. `cause` chains it for debugging while upper layers see a clean domain error:

```ts
// ❌ context lost
throw new SmsSendError();

// ✅ original error chained underneath
throw new SmsSendError(status, { cause: error });
```

---

## The build, in order

**`throw` = synchronous stack unwinding** → **rejections don't unwind** (the stack is gone) → **`await` bridges back** → **`async` always returns a promise** (one missing `await` breaks the chain) → **escapes** (timers, emitters, `Promise.all`) → **swallow / re-throw / translate** (the boundary test) → **`unknown` catch** (narrow first) → **operational vs programmer** → **`cause`**. The framework-level story — how NestJS turns an escaped error into an HTTP response — is `error-handling-b-nestjs.md`.
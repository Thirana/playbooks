# Promises & async/await in JS/TS — From the Ground Up (Foundation Lesson)

> The substrate under every async note in this library. Built bottom-up: why sync isn't enough → the callback era and why it hurt → promises as objects (states, `.then`, chaining, composition) → async/await as syntax over those objects → the microtask mechanics that make it all predictable.
>
> Companion to `01a-event-loop.md`: that note is about the **scheduler** (what runs next); this note is about the **promise** (the object, and how `await` desugars). They cross-reference; they don't duplicate.

---

## 1. Why synchronous code isn't enough

Synchronous code does one thing at a time, top to bottom, and each line finishes before the next starts. That's easy to reason about — and fatal for a server.

The problem is the single thread (the event-loop note). If "read from the database" *blocked* — actually sat on the thread waiting for the network — then during those 40ms the one thread could do nothing else. No other request, no timer, nothing.

```ts
// ❌ imagine if this BLOCKED the thread (it doesn't, but imagine)
const user = db.findUserSync(id);   // thread frozen for 40ms
const orders = db.findOrdersSync(); // another 40ms frozen
// a server built this way serves ONE user at a time
```

So we need a way to say: "start this slow thing, and let the thread do other work until it's done." That "until it's done, then come back" is the entire problem async programming solves. Every mechanism below — callbacks, promises, async/await — is a different *ergonomics* for the same underlying idea: **hand the waiting to the runtime, and provide code to run when it finishes.**

## 2. The first answer: callbacks

The original approach: pass a function that the runtime calls back when the work completes.

```ts
db.findUser(id, (err, user) => {          // this runs LATER, when the DB responds
  if (err) return handleError(err);
  console.log(user);
});
console.log('this runs FIRST');           // the call returned immediately
```

This works, and it's honest about what's happening: the call returns immediately, the thread stays free, and your callback runs later. By convention Node used **error-first callbacks** — `(err, result)` — because there was no `throw` to rely on (see §3).

### Why callbacks hurt — three real problems

**Problem 1: nesting ("callback hell").** Sequential async steps nest, because each next step can only start *inside* the previous callback:

```ts
// ❌ each dependent step nests one level deeper
db.findUser(id, (err, user) => {
  if (err) return handleError(err);
  db.findOrders(user.id, (err, orders) => {
    if (err) return handleError(err);
    pricing.calculate(orders, (err, total) => {
      if (err) return handleError(err);
      notify.send(user, total, (err) => {
        if (err) return handleError(err);
        // …the "pyramid of doom"
      });
    });
  });
});
```

**Problem 2: error handling is manual and repetitive.** There's no `try/catch` here — a thrown error inside async work doesn't unwind to your calling code (the stack is gone; see the error-handling note). So every single callback must check `err` by hand, and forgetting one silently swallows a failure.

**Problem 3: inversion of control.** You hand your callback to `db.findUser` and *trust it* to call you back — exactly once, with the right arguments, at the right time. A buggy library might call it twice, never, or synchronously. You've given away control of your own continuation.

Promises were designed to fix all three.

## 3. Promises: making "a future value" a first-class object

The key conceptual leap: instead of *passing* a callback into the operation, the operation **returns an object that represents the eventual result**. That object is a **promise**.

> **A promise is an object standing in for a value that isn't ready yet.** You can hold it, pass it around, and attach reactions to it — before the value exists.

Because the future result is now a *value you hold* (not a callback you surrendered), you get composition, standardized error propagation, and control back. That single change — "return an object instead of taking a callback" — is what unlocks everything else.

### A promise has three states

```
        ┌─────────────┐
        │   pending   │   (not settled yet)
        └──────┬──────┘
       resolve │ reject
        ┌──────┴──────┐
        ▼             ▼
   ┌─────────┐   ┌──────────┐
   │fulfilled│   │ rejected │      ← together: "settled"
   │ (value) │   │ (reason) │
   └─────────┘   └──────────┘
```

- **pending** — the operation is in flight.
- **fulfilled** — it succeeded; the promise now holds a **value**.
- **rejected** — it failed; the promise now holds a **reason** (usually an `Error`).

Two rules that make promises trustworthy — and directly fix callback problem 3:

- **A promise settles once and only once.** Once fulfilled or rejected, it can never change again. (No "called twice" bug.)
- **Its state and value are immutable after settling.** You can attach a reaction *after* it already settled and still get the result.

### Attaching reactions: `.then` / `.catch` / `.finally`

```ts
db.findUser(id)                              // returns a Promise<User>
  .then((user) => console.log(user))         // runs if fulfilled
  .catch((err) => handleError(err))          // runs if rejected
  .finally(() => cleanup());                 // runs either way
```

`.then(onFulfilled)` registers a reaction for success; `.catch(onRejected)` for failure; `.finally` for cleanup regardless. This already reads better than error-first callbacks — success and failure paths are separated, not interleaved with manual `if (err)`.

## 4. Chaining: why promises flatten the pyramid

Here's the property that kills callback hell. **`.then` returns a *new* promise**, and what you return from inside a `.then` determines that new promise's value:

- return a plain value → the next promise fulfills with that value.
- return **another promise** → the chain **waits for it** and adopts its result (this is the magic — nested async flattens into a chain).
- `throw` inside a `.then` → the next promise rejects.

So the deeply-nested callback pyramid becomes a flat sequence:

```ts
// ✅ the pyramid from §2, flattened — each step returns a promise the chain waits for
db.findUser(id)
  .then((user) => db.findOrders(user.id))    // returning a promise → chain waits for it
  .then((orders) => pricing.calculate(orders))
  .then((total) => notify.send(total))
  .catch((err) => handleError(err))          // ONE catch handles ANY step's failure
  .finally(() => cleanup());
```

Two callback problems solved at once:

- **Nesting → linear chain.** Each step is one `.then`, not one more indent level.
- **Manual per-step error checks → one `.catch`.** A rejection anywhere *skips the remaining `.then`s* and jumps to the next `.catch`. This is promises re-creating the "unwind to a handler" behavior that async code otherwise loses — a rejection propagates down the chain until something catches it, just like a thrown error propagates up a synchronous stack until a `try/catch`.

> **Mental model:** a promise chain is a pipeline. Values flow through `.then`s; a rejection short-circuits to the nearest `.catch`. `throw` in the chain and `reject` are the same event.

### The `.catch` placement rule (a real bug source)

A `.catch` only handles rejections from links **before** it. Anything after it is unguarded:

```ts
// ❌ if send() rejects, nothing catches it → unhandled rejection
db.findUser(id).catch(handleError).then((user) => notify.send(user));

// ✅ catch at the end guards the whole chain
db.findUser(id).then((user) => notify.send(user)).catch(handleError);
```

## 5. Composing multiple promises

Chaining is for *sequential* dependent steps. When operations are independent, you compose them — this is the concurrency toolkit (covered fully in `01b`, summarized here as promise behavior):

| Combinator | Settles when | On failure |
|-----------|-------------|------------|
| `Promise.all` | all fulfill | rejects on the **first** rejection (discards other results) |
| `Promise.allSettled` | all settle | never rejects — `{status, value/reason}` per item |
| `Promise.race` | the **first** to settle (either way) | mirrors that first settle |
| `Promise.any` | the **first** to fulfill | rejects only if **all** fail |

```ts
// independent → run together, don't chain
const [user, config] = await Promise.all([db.findUser(id), loadConfig()]);
```

> **`Promise.all` fails fast but does NOT cancel** the other operations — they keep running, their results discarded. Promises aren't cancellable by themselves (that's `AbortController`, in `01b`). "Fail fast" = stop waiting, not stop the work.

## 6. async/await: syntax over the same promises

Promise chains are a big improvement, but long `.then` pipelines still read differently from normal code, and sharing variables across steps is awkward. `async`/`await` is **syntactic sugar over promises** — same objects underneath, code that reads synchronously.

Two facts define it:

- **`async` makes a function return a promise.** A `return value` fulfills it; a `throw` rejects it. Always. (This is why an `async` function's `throw` is a rejected promise to the caller, never a synchronous throw — see the error note.)
- **`await` pauses the function until a promise settles**, then gives back the value — or, if it rejected, **re-throws the reason as a normal throw at the `await` line.**

That second half is the quiet superpower: it puts async errors back inside ordinary `try/catch`.

```ts
// the §4 chain, as async/await — reads like sync, IS promises underneath
async function checkout(id: string) {
  try {
    const user = await db.findUser(id);
    const orders = await db.findOrders(user.id);
    const total = await pricing.calculate(orders);
    await notify.send(total);
  } catch (err) {                 // catches a rejection from ANY await above
    handleError(err);
  } finally {
    cleanup();
  }
}
```

Compare the mapping — it's mechanical:

| Promise form | async/await form |
|--------------|------------------|
| `.then(x => …)` | `const x = await …` |
| `.catch(err => …)` | `try { … } catch (err) { … }` |
| `.finally(…)` | `finally { … }` |
| `return anotherPromise` in `.then` | `return await anotherPromise` |

## 7. The microtask mechanics behind `.then` and `await`

This explains *why* the two `loadUser` scenarios behave differently, using the same machinery that underlies both `.then` and `await`.

Three precise facts:

**Fact 1 — settling and resuming are two different events.** The I/O completing is a **macrotask** (an I/O event). That macrotask is what *settles* the promise. Settling then *schedules your reaction* (the `.then` callback, or the `await` continuation) as a **microtask**. So:

```
[macrotask] I/O completes → settles the promise
   → schedules your reaction as a MICROTASK
[stack empties] → microtask queue drains → your reaction runs
```

**Fact 2 — a reaction only exists if something was listening.** A microtask is scheduled *only if* a reaction was attached (`.then`, `.catch`, or `await`) at the time the promise settled. If nothing is attached, settling schedules nothing — the outcome just sits on the promise. A settled-*rejected* promise with no handler → **`unhandledRejection`** (crashes modern Node).

**Fact 3 — reactions always wait for the stack to empty.** Run-to-completion (event-loop note): the currently-running synchronous code finishes and unwinds before any microtask runs. A settled promise never interrupts running code.

### Your two scenarios, explained by these facts

```ts
// SCENARIO 1 — un-awaited, no listener attached
function loadUser(id: string) {
  try {
    const user = db.findUser(id);   // pending promise; NOTHING attached
    return user;                    // returns the pending promise; try block DONE
  } catch (e) { /* unreachable for a rejection */ }
}
```

`findUser` returns a pending promise with **no reaction attached**. The `try` finishes synchronously in microseconds. Later the I/O completes and settles the promise — but per **Fact 2**, no listener means **no microtask is scheduled**, so there's nothing that could ever run the `catch`. If it rejected → `unhandledRejection`. The `try/catch` only ever guarded *synchronous* throws on the (already-gone) stack.

```ts
// SCENARIO 2 — awaited, listener attached
async function loadUser(id: string) {
  try {
    return await db.findUser(id);   // await ATTACHES a continuation + suspends
  } catch (e) { /* runs on rejection */ }
}
```

`await` **attaches a continuation** (the listener) and suspends `loadUser`, returning control to its caller. When the I/O completes and settles the promise, **Fact 2** says a listener exists → the continuation is **scheduled as a microtask**; **Fact 3** says it runs once the stack empties. On resume, `await` delivers the value — or, on rejection, **re-throws at the `await` line**, landing in the `try/catch`. That's why the `catch` fires here and not in scenario 1.

> **The hinge, one line:** the promise settling is a macrotask; *your* code resuming is a microtask — **but that microtask only exists if something (`await`/`.then`/`.catch`) was listening when it settled.**

### What runs "in between"?

In *both* scenarios, between starting the I/O and its completion, the thread runs everything else: the rest of the current synchronous code, then queued microtasks, then macrotasks. Neither version "blocks." The difference is never *what runs in the meantime* — it's *whether settlement has a listener to deliver to.*

## 8. Common promise mistakes

Each pair shows the wrong approach, why it fails, and the correction.

**Calling an async function without awaiting it.** No reaction is attached, so a rejection becomes an `unhandledRejection` and the result is lost.

```ts
// ❌ fire-and-forget: rejection is unhandled, and we return before it finishes
async function confirm(order: Order) {
  sendReceipt(order);            // no await
  return { status: 'confirmed' };
}

// ✅ await it (or explicitly .catch if it's truly fire-and-forget by design)
async function confirm(order: Order) {
  await sendReceipt(order);
  return { status: 'confirmed' };
}
```

**Awaiting in a loop over independent items.** Each iteration suspends before the next starts, so independent work runs strictly one-at-a-time.

```ts
// ❌ serial — total time = sum of every call
const results = [];
for (const id of userIds) {
  results.push(await fetchUser(id));   // waits for each before starting the next
}

// ✅ start them all, then wait together — total time ≈ the slowest one
const results = await Promise.all(userIds.map((id) => fetchUser(id)));
```

**Placing `.catch` in the middle of a chain.** A `.catch` only guards links before it; anything after it is unprotected.

```ts
// ❌ if send() rejects, nothing catches it → unhandled rejection
db.findUser(id)
  .catch(handleError)
  .then((user) => notify.send(user));

// ✅ catch at the end guards the whole chain
db.findUser(id)
  .then((user) => notify.send(user))
  .catch(handleError);
```

**Wrapping something already promise-based in `new Promise`.** Adds a layer that's easy to get wrong — a `throw` inside the executor before you wire `reject` leaks, and you can forget to forward errors at all.

```ts
// ❌ needless wrapper around an existing promise
function getUser(id: string) {
  return new Promise((resolve, reject) => {
    db.findUser(id).then(resolve);      // rejection is silently dropped — no reject wired
  });
}

// ✅ just return the promise you already have
function getUser(id: string) {
  return db.findUser(id);
}
```

**Expecting a `throw` inside `.then` to hit an outer `try/catch`.** It rejects the chain; it does not throw into the surrounding synchronous scope.

```ts
// ❌ the try/catch is synchronous — it never sees the chain's rejection
function process(id: string) {
  try {
    db.findUser(id).then((user) => {
      if (!user) throw new Error('not found');   // rejects the chain, not this try
    });
  } catch (e) {
    // never runs
  }
}

// ✅ handle it on the chain, or switch to async/await
async function process(id: string) {
  try {
    const user = await db.findUser(id);
    if (!user) throw new Error('not found');      // now the try/catch catches it
  } catch (e) {
    handleError(e);
  }
}
```

**Forgetting to `return` a promise inside `.then`.** The chain doesn't wait for it, so ordering and errors escape the pipeline.

```ts
// ❌ the chain doesn't wait for saveAudit(); its rejection is unhandled
db.findUser(id)
  .then((user) => {
    saveAudit(user);            // not returned
  })
  .then(() => console.log('done'));   // logs before saveAudit finishes

// ✅ return it so the chain waits and errors propagate
db.findUser(id)
  .then((user) => saveAudit(user))
  .then(() => console.log('done'));
```

**Catching an async function's error synchronously at the call site.** An `async` function's `throw` is a rejected promise, not a synchronous throw — a plain `try/catch` around the call won't see it.

```ts
// ❌ chargeCard is async; its rejection is not a sync throw, so this catch is dead
function pay(order: Order) {
  try {
    chargeCard(order.total);    // no await
  } catch (e) {
    // never runs
  }
}

// ✅ await inside the try so the rejection surfaces as a throw here
async function pay(order: Order) {
  try {
    await chargeCard(order.total);
  } catch (e) {
    handleError(e);
  }
}
```

---

## The build, in order

**sync is simple but blocks the one thread** → **callbacks** (honest, but nesting + manual errors + inversion of control) → **promises** (a future value as an object: three states, settles once, immutable) → **chaining** (`.then` returns a promise → flatten the pyramid, one `.catch` for the whole chain) → **composition** (`all`/`allSettled`/`race`/`any`) → **async/await** (sugar over the same promises; `await` re-throws rejections into `try/catch`) → **microtask mechanics** (settle = macrotask, resume = microtask, listener required) → **common mistakes**.
# Controlling Async Concurrency (Lesson 1b)

> Long-form walkthrough: once work is legitimately async, how you *control* it — sequential vs concurrent, the combinators, bounded parallelism, backpressure, timeouts, and cancellation. Builds on `01a-event-loop.md` (especially "`await` is a yield point"). Distilled version: `01-async-concurrency.md`.

---

## The frame

Async gives you the *ability* to have many things in flight at once. But ability isn't a strategy. Controlling concurrency means deciding four things deliberately: **how many** operations are in flight, **in what order**, **how long** you'll wait, and **what stops them**. We build those up one at a time — each resting on the yield-point insight from Lesson 1a: because `await` is a place your function steps off the stack, *you* get to choose whether operations happen one-after-another or all-at-once.

## Sequential vs concurrent: the choice hiding in every `await`

Start with the smallest real case: an order completes, and you need to both send a notification *and* grant a reward. These don't depend on each other.

The obvious code runs them one after the other:

```js
// ❌ Sequential — independent calls, but the second waits for the first.
// Total time ≈ notifyTime + rewardTime
async function completeOrder(order) {
  await sendNotification(order);   // yield point: we fully wait here
  await grantReward(order);        // only STARTS after notification finishes
}
```

From Lesson 1a you can see why this is wasteful: at the first `await`, the function suspends until `sendNotification` fully settles, and only *then* does `grantReward` begin. Two operations that could overlap are forced into a line.

The fix comes from one mechanical fact: **calling an async function returns a pending promise, and the underlying operation is already in flight** — the runtime is already doing it. `await` doesn't *start* the work; it says "I need the result at this point." So call both first, await afterward:

```js
// ✅ Concurrent — both start immediately, then we wait for both together.
// Total time ≈ max(notifyTime, rewardTime)
async function completeOrder(order) {
  const notifyP = sendNotification(order);  // in flight NOW (not awaited yet)
  const rewardP = grantReward(order);       // also in flight NOW
  await Promise.all([notifyP, rewardP]);    // wait for both to finish
}
```

> **Start the work as early as possible; `await` as late as possible.** `await` is not "do this now" — it's "I need the result here." Kick off everything that can run in parallel, then await.

The instant work depends on a previous result, you *must* await in sequence. Sequential isn't wrong; it's wrong *when the operations are independent*. Recognizing which is which is the skill.

## Choosing how to wait: the promise combinators

Once you're starting several operations at once, *how* you wait depends on what failure should mean.

| Tool | Settles when | On failure | Use when |
|------|-------------|------------|----------|
| `Promise.all` | **all** fulfill | rejects on the **first** rejection (fails fast) | need every result; any failure aborts the whole thing |
| `Promise.allSettled` | **all** settle | never rejects — `{status, value/reason}` per item | partial success OK; inspect each outcome |
| `Promise.race` | **first** to settle (fulfill *or* reject) | mirrors that first settle | whichever finishes first wins — basis for timeouts |
| `Promise.any` | **first** to **fulfill** | ignores rejections; rejects only if **all** fail | first success wins |

For `completeOrder`, the choice is a design decision. If a failed notification should *not* undo a granted reward, `Promise.all` is wrong — its fail-fast throws and you lose the other's result. `Promise.allSettled` fits: both run to completion, and you decide per outcome (log the failed notify, keep the reward).

The senior subtlety, which shapes the rest of the lesson:

> **`Promise.all` failing fast does not *cancel* the other operations.** It only stops *you waiting* for them. The other promises keep running to completion in the background — their results are just discarded. Promises are **not cancellable by default**; "fail fast" means "I'll stop paying attention," not "I'll stop the work."

That gap — between ignoring work and actually stopping it — is what timeouts and cancellation exist to close.

## Why "start everything at once" breaks at scale: bounded concurrency

Running two operations together is fine. Now scale up — notify every user in a 10,000-row list. The tempting one-liner:

```js
// ❌ Starts ALL 10,000 calls simultaneously.
await Promise.all(users.map((u) => sendNotification(u)));
```

`.map` builds 10,000 promises *immediately* → 10,000 in-flight HTTP calls at once. Every failure mode arrives together: you exhaust sockets and file descriptors, hold 10,000 pending promises in memory, and likely **overwhelm the notification service itself** — effectively a DoS on your own downstream — which then fails *your* requests too.

The fix is **bounded parallelism**: process at most **N** at a time. Conceptually a worker pool — N workers, each pulling the next task off a shared list, finishing it, pulling another, until the list is empty. Only N in flight at any instant, no matter the total.

You don't hand-roll this; a small, well-tested library does it (`p-limit`):

```js
import pLimit from 'p-limit';
const limit = pLimit(10);   // at most 10 notifications in flight at once
await Promise.all(users.map((u) => limit(() => sendNotification(u))));
```

The `.map` still wraps all 10,000 tasks, but `limit` guarantees only 10 actually *run* concurrently; the rest wait their turn. (`p-map` gives the same idea with a nicer API.)

The trade-off is a real tuning knob:

| N too low | N too high |
|-----------|-----------|
| underutilized; the batch crawls | overwhelm downstream, hit rate limits, exhaust local resources |

> The right concurrency limit is dictated by the **downstream's** capacity, not by your eagerness to finish fast.

This same idea reappears as a RabbitMQ consumer's **prefetch** — bounded concurrency at the broker level ("don't hand me more than N unacked messages at once").

## When work keeps arriving: backpressure

Bounded concurrency handles a *fixed* batch of known size. Sometimes work is a **stream** that keeps flowing — a firehose of RabbitMQ messages, a cursor over millions of rows, a large file. Here a new problem appears.

If you *accept* new work faster than you can *finish* it, the unfinished work accumulates in memory until the instance runs out and Cloud Run kills it (an OOM restart). The bottleneck isn't CPU or the loop — it's **unbounded buffering**.

**Backpressure** is the mechanism by which a slow consumer signals a fast producer to *slow down*: "don't give me the next item until I've got capacity for it." The core discipline: **don't pull the next piece of work until you're ready to handle it.**

Node's streams implement this natively (a readable pauses at a high-water mark, resumes when drained), and `for await...of` respects it — the loop pulls the next item only when the previous one's handling has progressed:

```js
// ✅ Pull-and-process: the next row isn't fetched until this one is handled,
// so memory stays flat no matter how many total rows there are.
for await (const row of queryStream) {
  await processRow(row);
}
```

Streaming solves *two* things at once: buffering a huge payload blocks the loop while you parse it (Lesson 1a) **and** spikes memory (backpressure). RabbitMQ prefetch + manual acknowledgment *is* backpressure — the broker won't send message N+1 until you've acked earlier ones.

## Bounding the wait: timeouts

We've controlled *how many* run and *how fast* we accept. Next dimension: *time*. Any call that leaves your process can **hang** — not fail, hang, indefinitely, because the network went into a black hole or the downstream is wedged. A call with no timeout waits forever.

On Cloud Run this is quietly dangerous: a hung request holds a **concurrency slot** for as long as it hangs. Enough hung requests and the instance is saturated with calls that will never complete — an outage built entirely out of "we forgot to set a timeout."

> **Every outbound call gets a timeout. No exceptions.** A call with no deadline is a latent hang.

The clean way uses the cancellation-signal mechanism (next section) — most modern clients accept an `AbortSignal`, and `AbortSignal.timeout(ms)` makes one that fires after a delay:

```js
// ✅ Real timeout — fires after 2s AND cancels the underlying request.
const res = await fetch(notifyUrl, { signal: AbortSignal.timeout(2000) });
```

You can also build one with `Promise.race` — race the call against a rejecting timer:

```js
function withTimeout(promise, ms) {
  const timeout = new Promise((_, reject) =>
    setTimeout(() => reject(new Error('timed out')), ms));
  return Promise.race([promise, timeout]);   // whichever settles first wins
}
```

But recall the subtlety, which bites hardest here:

> `Promise.race` timing out only stops *you waiting*. The underlying call **keeps running** — the socket stays open, resources stay held — because the promise wasn't cancelled. `race` gives you a timeout *value*, not a timeout *that stops the work*.

That's why the `AbortSignal.timeout` version is better: it doesn't just reject your wait, it *actually aborts the request*.

## Actually stopping work: cancellation

Everything so far — `Promise.all`'s fail-fast, `race`-based timeouts — *ignores* unwanted work but doesn't *stop* it. To truly stop it, the operation must **cooperate**, and the standard tool is `AbortController`.

An `AbortController` produces a `signal` you pass into cancellable operations. Calling `controller.abort()` fires the signal, and any operation watching it stops and rejects:

```js
const controller = new AbortController();
const res = await fetch(url, { signal: controller.signal });
controller.abort(); // actually cancels the in-flight request
```

> **Cancellation is cooperative.** You cannot force-kill an arbitrary promise. The operation must be *listening* to the signal (`fetch`, axios, many DB drivers, lots of Node APIs accept an `AbortSignal`). A purely CPU-bound synchronous computation can't be aborted mid-flight — it never yields the stack (Lesson 1a). Cancellation works for *I/O you delegated*, which is most of what a backend does.

The practical payoff is request-scoped cancellation. When a client disconnects — closed tab, navigated away, or Cloud Run hit the request deadline — there's no point still hammering the reward and notification services. Wire an `AbortController` to the request's close event and pass its signal down:

```js
// Cancel the downstream work if the caller goes away.
const ac = new AbortController();
req.on('close', () => ac.abort());

await Promise.all([
  sendNotification(order, { signal: ac.signal }),
  grantReward(order, { signal: ac.signal }),
]);
```

Now a disconnected client doesn't leave orphaned work draining your downstreams. Combined with timeouts, this closes the loop: unwanted work is not merely ignored — it's stopped, and its resources freed. Translate the resulting `AbortError` into a clean error at the boundary (the error-handling discipline; the resilience layer in Topic 6 builds directly on this).

## The decision frame

> 1. **Start early, await late** — overlap independent work instead of serializing it.
> 2. **Every piece of in-flight work needs a bound** — a concurrency limit, a timeout, or a way to cancel. Unbounded anything (parallelism, buffering, waiting) is a production incident waiting to happen.

| Situation | Reach for |
|-----------|-----------|
| A few independent operations, need all results | `Promise.all` |
| Independent operations, partial success is OK | `Promise.allSettled` |
| Many items to process (fan-out) | bounded pool — `p-limit` / `p-map` |
| A stream/firehose of work | backpressure — streams, `for await`, RabbitMQ prefetch |
| Cap how long you'll wait on a call | `AbortSignal.timeout(ms)` |
| Genuinely stop unwanted work | `AbortController` + signal propagation |

---

## The build, in order

**sequential vs concurrent** (the choice inside every `await`) → **combinators** (how to wait, and the "not cancellable" catch) → **bounded parallelism** (why all-at-once breaks, and the N knob) → **backpressure** (don't accept faster than you finish) → **timeouts** (bound the wait) → **cancellation** (actually stop the work). Two threads carry forward: cancellation + timeouts become the backbone of resilient HTTP calls (Topic 6), and backpressure/prefetch become real in RabbitMQ (Topic 7).
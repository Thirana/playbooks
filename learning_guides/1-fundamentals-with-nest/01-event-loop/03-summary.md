# Async & Concurrency — Node/TS Runtime (Reference Note)

> How the event loop schedules work, what freezes it, and how to control legitimate concurrency. Built bottom-up — each section assumes the one above.
>
> **The build:** call stack → delegate the waiting → queue + loop → run-to-completion → two lanes → `await` = yield point → control concurrency (*how many / how long / what stops it*).

---

## 1. Core mental models

- **Single-threaded = one call stack.** The thread runs whatever's on top. A frame that won't return = **blocking**.
- **Your JS never waits.** It hands async work to the runtime (libuv/OS) and pops off the stack. *Waiting is free; only running JS costs the thread.*
- **Event loop, in one line:** *when the stack is empty, push the next queued callback onto it.* That's the whole engine.
- **Run-to-completion:** code runs to the end before any queued callback runs. You're never interrupted mid-function (→ no locks needed inside a sync block).
- **`await` is a yield point:** your function steps off the stack; other work runs; it resumes *later*, as a microtask.
- **Nothing is cancellable by default.** "Fail fast" and "timeout" mean *stop waiting* — not *stop the work*.

---

## 2. The machine (part-by-part)

**Delegation — the stack stays free while the runtime waits:**

```js
console.log('before');
setTimeout(() => console.log('later'), 100); // handed to libuv, returns instantly
console.log('after');
// before, after ... 'later' ~100ms later. The stack did NOT pause on the setTimeout line.
```

**"0ms" still waits for the stack to empty** (there is no jumping the current stack):

```js
console.log('1');
setTimeout(() => console.log('2'), 0);
console.log('3');
// 1, 3, 2
```

---

## 3. Task ordering: the priority lanes

Once the current synchronous code finishes:

```
sync code runs to completion
  → drain nextTick queue      (fully)
  → drain microtask queue     (fully)   ← promises
  → take ONE macrotask
  → repeat
```

| Lane | Holds | Cadence |
|------|-------|---------|
| **nextTick** | `process.nextTick` | drained fully, highest priority |
| **microtask** | `.then/.catch/.finally`, `await` resumption, `queueMicrotask` | drained **fully** after each macrotask |
| **macrotask** | timers, I/O callbacks, `setImmediate` | **one** per loop turn |

**Trace** — output is derived, not memorized:

```js
console.log('1: sync');
setTimeout(() => console.log('2: timeout'), 0);
Promise.resolve().then(() => console.log('3: promise'));
process.nextTick(() => console.log('4: nextTick'));
console.log('5: sync');
// 1, 5, 4, 3, 2   → sync, then nextTick lane, then microtask lane, then one macrotask
```

> **Starvation:** "drain microtasks *fully*" includes microtasks scheduled *by* microtasks. An endless chain never lets the loop reach a macrotask → timers/I·O/`/health` freeze, even with no heavy work.

```js
// ❌ freezes the loop — endless microtask chain, not heavy CPU
for (const item of items) await Promise.resolve(process(item));
```

---

## 4. What blocks the loop

Blocking = **synchronous JS that runs long**. One thread, so while it runs, *nothing else does*.

| Innocent-looking blocker | Note |
|--------------------------|------|
| `JSON.parse` / `JSON.stringify` big payload | fully synchronous |
| sync crypto (`bcrypt` sync, `pbkdf2Sync`) | CPU on the request thread |
| **ReDoS** — catastrophic regex backtracking | can freeze for *seconds* on user input |
| `fs.readFileSync` in request path | sync I/O |
| large in-memory `map`/`sort`/`filter` | tens of thousands of items |

> **Cloud Run blast radius:** one instance serves many concurrent requests on **one** loop. A single blocking request stalls *all* the others → p99 tail spikes, failed health probes, misfiring autoscale. You're protecting a *shared* thread, not tuning one endpoint.

**Measure it (loop lag) — the earliest signal (feeds the observability topic):**

```js
import { monitorEventLoopDelay } from 'node:perf_hooks';
const h = monitorEventLoopDelay({ resolution: 20 });
h.enable();
setInterval(() => {
  console.log({ p99ms: (h.percentile(99) / 1e6).toFixed(2) }); // rising p99 = blocking/overload
  h.reset();
}, 10_000);
```

**Fixes:** keep CPU-bound work off the request thread (worker thread / separate job) · chunk long work and yield with `setImmediate` · stream large payloads instead of buffering + parsing whole.

---

## 5. Sequential vs concurrent (the choice in every `await`)

Calling an async fn **starts the work immediately** and returns a pending promise. `await` doesn't start it — it says "I need the result *here*."

```js
// ❌ Sequential — independent calls serialized.  total ≈ notify + reward
await sendNotification(order);
await grantReward(order);

// ✅ Concurrent — both in flight, then wait together.  total ≈ max(notify, reward)
const notifyP = sendNotification(order);
const rewardP = grantReward(order);
await Promise.all([notifyP, rewardP]);
```

> **Start early, await late.** Kick off everything independent, then await. Only await-in-sequence when the next call *depends* on the previous result.

---

## 6. Combinators: how to wait

| Tool | Settles when | On failure | Use when |
|------|-------------|------------|----------|
| `Promise.all` | all fulfill | rejects on **first** rejection (fail-fast) | need every result; any failure aborts all |
| `Promise.allSettled` | all settle | never rejects → `{status, value/reason}` each | partial success OK; inspect each |
| `Promise.race` | first to settle (fulfill *or* reject) | mirrors first settle | basis for timeouts |
| `Promise.any` | first to **fulfill** | rejects only if **all** fail | first success wins |

> **Fail-fast ≠ cancel.** `Promise.all` rejecting stops *you waiting*; the other promises keep running, results discarded. Promises aren't cancellable by default.

`completeOrder` design call: if a failed notify shouldn't undo a granted reward → use `allSettled`, not `all`.

---

## 7. Bounded parallelism (fan-out)

```js
// ❌ starts ALL at once → socket/FD exhaustion, memory, DoS your own downstream
await Promise.all(users.map((u) => sendNotification(u)));

// ✅ at most N in flight (worker-pool)
import pLimit from 'p-limit';
const limit = pLimit(10);
await Promise.all(users.map((u) => limit(() => sendNotification(u))));
```

| N too low | N too high |
|-----------|-----------|
| underutilized, batch crawls | overwhelm downstream, rate limits, local exhaustion |

> **The downstream's capacity sets N**, not your eagerness to finish. (Same idea reappears as RabbitMQ **prefetch** — topic 7.)

---

## 8. Backpressure (a stream, not a fixed list)

Accepting work faster than you finish it → unbounded buffering → OOM (Cloud Run kills the instance). Fix: **don't pull the next item until you're ready for it.**

```js
// ✅ pull-and-process: next row not fetched until this one is handled → flat memory
for await (const row of queryStream) {
  await processRow(row);
}
```

> Streaming solves **both** loop-blocking (§4) *and* memory (backpressure). RabbitMQ prefetch + manual ack **is** backpressure (topic 7).

---

## 9. Timeouts (bound the wait)

Any call leaving the process can **hang** (not fail — hang, forever). On Cloud Run a hung call holds a concurrency slot → saturation → outage.

> **Every outbound call gets a timeout. No exceptions.**

```js
// ✅ best — fires after 2s AND cancels the underlying request
const res = await fetch(url, { signal: AbortSignal.timeout(2000) });

// generic (from §6) — but see caveat
function withTimeout(promise, ms) {
  const t = new Promise((_, rej) => setTimeout(() => rej(new Error('timed out')), ms));
  return Promise.race([promise, t]);
}
```

> **`race` timeout doesn't stop the work** — socket stays open, resources held. It rejects your *wait* only. Prefer `AbortSignal.timeout`, which actually aborts.

---

## 10. Cancellation (actually stop work)

> **Cooperative only.** You can't force-kill a promise. The operation must *listen* to an `AbortSignal` (`fetch`, axios, many DB drivers do). Pure CPU-bound sync work can't be aborted — it never yields the stack (§4).

```js
const controller = new AbortController();
const res = await fetch(url, { signal: controller.signal });
controller.abort(); // cancels the in-flight request

// request-scoped: stop downstream work when the caller disconnects
const ac = new AbortController();
req.on('close', () => ac.abort());
await Promise.all([
  sendNotification(order, { signal: ac.signal }),
  grantReward(order, { signal: ac.signal }),
]);
```

Translate the resulting `AbortError` into a clean response at the boundary (→ error-handling note). Resilience layer builds on this (topic 6).

---

## 11. Footguns → fix

| Footgun | Why it bites | Fix |
|---------|--------------|-----|
| Floating promise (no `await`/`.catch`) | unhandled rejection → crash; error lost | `await` it, or `.catch()` |
| `await` in a loop over *independent* items | serializes; total = sum | start all → `Promise.all`, or bounded pool |
| `Promise.all(bigList.map(fn))` | all in flight → DoS downstream / OOM | `p-limit` bounded pool |
| Outbound call, no timeout | hangs forever, holds a Cloud Run slot | `AbortSignal.timeout(ms)` |
| `race` timeout, expecting work to stop | work keeps running in background | pass an `AbortSignal` to truly cancel |
| big `JSON.parse` / regex on request thread | blocks loop → p99 spikes for everyone | stream / worker / bound input size |
| read shared state before `await`, write after | another request interleaved in the gap → stale | re-read after `await` / avoid shared mutable state |

---

## 12. Decision frame

> 1. **Start early, await late** — overlap independent work.
> 2. **Every in-flight thing needs a bound** — a concurrency limit, a timeout, or a cancel. Unbounded anything (parallelism, buffering, waiting) is a latent incident.

| Situation | Reach for |
|-----------|-----------|
| A few independent ops, need all results | `Promise.all` |
| Independent ops, partial success OK | `Promise.allSettled` |
| Many items (fan-out) | bounded pool — `p-limit` / `p-map` |
| A stream/firehose | backpressure — streams, `for await`, RMQ prefetch |
| Cap how long you wait | `AbortSignal.timeout(ms)` |
| Genuinely stop unwanted work | `AbortController` + propagate signal |

---

## Connects to

- **error-handling note** — translate `AbortError`/timeouts into proper `HttpException`s at the boundary; `Promise.all` fail-fast.
- **Topic 6 (HTTP resilience)** — timeouts + retries + cancellation on calls to notification/reward.
- **Topic 7 (RabbitMQ)** — prefetch = bounded concurrency + backpressure.
- **Topic 4 (observability)** — loop-lag p99 as an alerting signal.
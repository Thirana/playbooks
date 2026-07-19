# The Event Loop, From the Ground Up (Lesson 1a)

> Long-form walkthrough: how the single-threaded runtime schedules work, the micro/macro/nextTick queues, what freezes the loop, and why `await` is a yield point. Built bottom-up — each section rests on the one before. Distilled version: `01-async-concurrency.md`; concurrency control: `01b-concurrency-control.md`.

---

## Where we start: one thread means one call stack

Everything begins here, because the whole event loop exists to work around one hard limit.

When we say Node is "single-threaded," the concrete thing we mean is: there is exactly **one call stack**. The call stack is just the runtime's record of "what function am I inside right now." Calling a function *pushes* a frame onto the stack; the function returning *pops* it off. The thread does precisely one thing at any instant — run whatever function is on top of the stack.

```js
function total(a, b) { return a + b; }
function handle()     { return total(2, 3); }
handle();
```

Trace the stack:

```
push handle          →  [handle]
  push total         →  [handle, total]
  total returns 5    →  [handle]        (total popped)
handle returns 5     →  []              (handle popped)
```

Two consequences the rest of the topic leans on:

- **While a frame is on the stack, nothing else can run.** The thread is committed to it until it returns. This is the *physical* meaning of "blocking" — a function that takes 300ms to return keeps the stack occupied for 300ms, and nothing else moves.
- **Waiting cannot happen *on* the stack.** If `await db.query()` literally sat on the stack doing nothing for 40ms, the one thread would be frozen for 40ms per query — a server that serves one user at a time. So the real question the event loop answers is: *how do we wait for something without keeping a frame on the stack?*

## The trick: hand the waiting to someone else

Here's the move that makes Node work. Your JavaScript itself never waits. When you start an async operation — a timer, a database socket read, an HTTP call, a file read — your code does **not** pause on the stack. It *registers the request with the runtime* and returns immediately, popping its frame off.

It helps to separate two things that both live inside "Node":

- **The JS engine (V8)** — runs your JavaScript. It owns the call stack. It only knows how to execute code, not how to wait for a network socket.
- **The runtime around it (libuv + the OS)** — provides the actual async machinery: timers, socket I/O, file I/O, a small background thread pool for the few things that can't be done via the OS asynchronously.

So `setTimeout(cb, 100)` really means: "Hey runtime, hold onto `cb`, and in 100ms let me know it's ready." Your code keeps running immediately; the stack is free the entire 100ms. Same for a DB query: the request goes out over a socket the OS manages, your frame pops, and the thread is free to run other requests. **The waiting is delegated; the stack stays empty.**

```js
console.log('before');
setTimeout(() => console.log('later'), 100);   // handed to libuv, returns instantly
console.log('after');
// prints: before, after   ... then 'later' ~100ms afterward
// the stack was free the whole 100ms — it did NOT pause on the setTimeout line
```

This raises the next question: when the runtime finishes waiting, *how does `cb` get back onto the stack to run?* It can't just barge in — the thread might be busy. It has to wait its turn somewhere. That "somewhere" is a queue.

## The return path: queues + the event loop

When a delegated operation finishes, the runtime places its callback into a **queue** — a waiting line of "callbacks that are ready to run but haven't run yet." It does *not* execute the callback on the spot.

The thing that moves callbacks from a queue onto the stack is the **event loop**. Its core logic is almost embarrassingly simple — you can hold the whole thing in one sentence:

> **When the call stack is empty, take the next ready callback from a queue and push it onto the stack. If the stack isn't empty, wait.**

That's the engine of the entire system. Everything else is refinement of *which* queue it pulls from and *in what order*.

One profoundly important consequence falls straight out of "only when the stack is empty":

> **Run-to-completion:** once a piece of JavaScript starts running, it runs all the way to the end — until its stack fully unwinds — before *any* queued callback gets a turn. You are never interrupted in the middle of a function.

This is why you don't need locks around a normal synchronous block in Node. If you read-modify-write an in-memory variable across several synchronous lines, no other callback can sneak in between them — the loop can't pull the next callback until your current code finishes. (The moment there's an `await` in the middle, that guarantee changes — see the final section.)

Even a zero-delay timer obeys this:

```js
console.log('1');
setTimeout(() => console.log('2'), 0);   // "0ms" — but still waits for the stack to empty
console.log('3');
// prints: 1, 3, 2   — '2' can't run until the synchronous run (1 and 3) completes
```

`0` doesn't mean "now." It means "as soon as possible, which is *after* the current synchronous work unwinds the stack." There's no jumping the current stack.

*(Under the hood libuv runs the loop in repeating **phases** — timers, pending, poll/I·O, check/`setImmediate`, close — each with its own queue. You rarely need the phase names. The two facts that matter: the **poll** phase is where the loop efficiently sleeps waiting for I/O, and the microtask queues drain between callbacks, which is the rule the next section builds.)*

## Why one queue wasn't enough: two priority lanes

So far, one queue would do. But there's a tension. Promises are meant to feel *tight* — when a promise resolves, its `.then` should run as soon as the current work finishes, **not** wait behind a pile of timers and I/O callbacks. If promise callbacks shared one lane with timers, a `.then` could be delayed surprisingly long.

The fix is two lanes with different priority:

- A **macrotask queue** (the task queue) — holds the "big, discrete units of work": a timer callback, an I/O completion callback, a `setImmediate` callback. The loop takes **one** of these per turn.
- A **microtask queue** — the priority express lane, holding promise continuations: `.then` / `.catch` / `.finally`, the resumption of an `await`, and `queueMicrotask`.

Now the ordering rule stops being arbitrary — it's the natural way to give promises their priority:

> After the initial synchronous run, and after **each single macrotask**, the loop **drains the entire microtask queue** before it touches another macrotask.

So the real rhythm is: *run one macrotask → empty the microtask queue completely → run one macrotask → empty the microtask queue completely → …*

There's a sharp edge in "empty the microtask queue **completely**." If a microtask, while running, schedules another microtask, that new one *also* runs before the loop moves on — the queue is drained to truly empty, not just the items present when draining started. Usually fine. But it's exactly the mechanism behind **starvation**:

```js
// Each awaited resolved promise queues another microtask, which queues another…
// The microtask queue never empties, so the loop NEVER advances to a macrotask —
// timers don't fire, I/O callbacks don't run, /health can't answer.
async function drain(items) {
  for (const item of items) {
    await Promise.resolve(process(item));
  }
}
```

It's not slow *work* that freezes the loop here — it's an endless microtask chain denying the loop its chance to move to the next macrotask. Same freeze, different cause than a blocking computation.

## One more lane on top: `process.nextTick`

Node adds a lane with even *higher* priority than promise microtasks. `process.nextTick(cb)` schedules `cb` to run after the current operation finishes but **before** the promise microtask queue is processed.

So the true priority order, once the current synchronous code finishes, is:

```
current sync code runs to completion
  → drain the nextTick queue      (fully)
  → drain the promise microtask queue (fully)
  → take ONE macrotask
  → repeat
```

It exists so Node's own APIs can say "run this the instant the current operation is done, ahead of everything else." Same warning as microtasks, magnified: a recursive `nextTick` starves the loop even more aggressively, because it sits at the very front.

## Watch the whole machine run

Here's a puzzle — but this time we trace the *state of every queue*, and the output becomes something you compute rather than recall.

```js
console.log('1: sync');
setTimeout(() => console.log('2: timeout'), 0);
Promise.resolve().then(() => console.log('3: promise'));
process.nextTick(() => console.log('4: nextTick'));
console.log('5: sync');
```

| Step | Action | nextTick Q | microtask Q | macrotask Q | Printed |
|------|--------|-----------|-------------|-------------|---------|
| 1 | run `log('1')` | — | — | — | **1** |
| 2 | `setTimeout` registers | — | — | [t] | |
| 3 | `.then` registers | — | [p] | [t] | |
| 4 | `nextTick` registers | [n] | [p] | [t] | |
| 5 | run `log('5')` | [n] | [p] | [t] | **5** |
| 6 | sync done → stack empty; drain nextTick | — | [p] | [t] | **4** |
| 7 | drain microtasks | — | — | [t] | **3** |
| 8 | take one macrotask | — | — | — | **2** |

Output: `1, 5, 4, 3, 2`. Every line is forced by rules we built, not conventions to remember: sync first (run-to-completion), then nextTick lane, then microtask lane, then one macrotask.

*(One ordering you can't rely on: at the **top level**, `setTimeout(…, 0)` vs `setImmediate` race — order isn't guaranteed. Inside an I/O callback, `setImmediate` deterministically wins.)*

## What actually blocks the loop

Blocking = **synchronous JS that runs long**. One thread, so while it runs, *nothing else does* — no other request progresses, no timers fire, no I/O callbacks run, `/health` can't answer.

The blockers people don't notice because they look innocent:

| Innocent-looking blocker | Note |
|--------------------------|------|
| `JSON.parse` / `JSON.stringify` big payload | fully synchronous — a 5MB body serialized on the request thread is real blocking |
| sync crypto (`bcrypt` sync, `crypto.pbkdf2Sync`) | CPU on the request thread |
| **ReDoS** — catastrophic regex backtracking | a bad regex on user input can freeze for *seconds* |
| `fs.readFileSync` in the request path | sync I/O |
| large in-memory `map`/`sort`/`filter` | tens of thousands of items |

**Why it bites specifically on Cloud Run:** each instance serves **multiple concurrent requests** (default concurrency 80) on **one** Node process = one event loop = one thread. So:

- **Noisy neighbor inside your own app.** One request doing synchronous CPU work stalls the *other 79*. Invisible in averages; shows up as **p99 tail spikes** — the metric that hurts users.
- **Health/readiness probes fail.** A blocked loop can't answer `/health` in time → Cloud Run may recycle the instance. Blocking *looks like* an outage to the platform.
- **Autoscaling misfires.** Inflated in-flight counts trigger scale-ups, but more instances don't fix a single slow synchronous request.

> **Senior framing:** on Cloud Run you're never tuning one request in isolation — you're protecting a *shared thread* an entire instance's traffic depends on. "Is this synchronous?" becomes a question about blast radius.

**Measure it — event loop delay (lag):**

```js
import { monitorEventLoopDelay } from 'node:perf_hooks';
const h = monitorEventLoopDelay({ resolution: 20 });
h.enable();
setInterval(() => {
  console.log({ p99ms: (h.percentile(99) / 1e6).toFixed(2) }); // rising p99 = blocking/overload
  h.reset();
}, 10_000);
```

Rising p99 lag is the earliest, clearest sign you're blocking or overloading the loop — usually before users complain. (This becomes a real alert in the observability topic.)

**Fixes:** keep CPU-bound work off the request thread (worker thread / separate job) · chunk long work and yield with `setImmediate` between chunks · stream large payloads instead of buffering + parsing them whole.

## `await` is a yield point

Real handlers mix in `await`, and that's where the single most useful practical insight lives. Watch what `await` does to control flow:

```js
async function handleOrder() {
  console.log('A: start');
  const order = await saveOrder();          // ← control LEAVES this function here
  console.log('B: after save');             // ← this line is a microtask, later
  flushLog().then(() => console.log('C: log flushed'));
  setTimeout(() => console.log('D: retry tick'), 0);
  console.log('E: end of sync part');
}

console.log('X: before call');
handleOrder();
console.log('Y: after call');
```

Rough order: `X, A, Y, B, E, C, D`.

The part that matters: **at `await saveOrder()`, `handleOrder` suspends and hands control back to its caller** — that's why `Y` prints *before* `B`. Under the hood, everything after the `await` (from line `B`) is packaged as a *continuation* and scheduled as a **microtask** to run once `saveOrder()` settles. `await` is, mechanically, "run the rest of this function later, as a microtask, when the awaited thing is ready."

> **Every `await` is a yield point** — a place where your function voluntarily steps off the stack and lets *other* queued work run before it resumes.

Two consequences, both of which drive the concurrency lesson:

**1. `await` in a loop serializes.** Each iteration suspends and only resumes before the next iteration starts, so calls happen strictly one-after-another:

```js
for (const userId of userIds) {
  await notify(userId);   // waits for each to finish before starting the next
}
```

If those calls are independent, running them sequentially wastes the point of async — firing them together is a *concurrency* decision (Lesson 1b).

**2. Requests interleave at yield points.** Run-to-completion made a synchronous block effectively atomic. The instant you `await`, that block ends — the loop is free to run another request's handler while yours is parked. Two requests on one instance don't run *simultaneously* (one thread), but they **interleave**: request A runs to its first `await` and parks, request B's handler runs to *its* first `await`, and so on. This is how one thread juggles 80 concurrent requests.

That interleaving is why "single-threaded" does **not** mean "no concurrency concerns." Shared mutable state read before an `await` and written after can be stale, because another request may have changed it in the gap.

---

## The build, in order

**call stack** (one thread, one thing at a time) → **delegation** (the runtime waits, the stack stays free) → **queue + event loop** (callbacks wait, the loop feeds the empty stack) → **run-to-completion** (no mid-function interruption) → **two lanes** (microtasks drain fully between macrotasks) → **nextTick** (the express lane) → **`await` as a yield point** (where interleaving enters). Concurrency *control* — running work in parallel, bounding it, cancelling it — is `01b-concurrency-control.md`.
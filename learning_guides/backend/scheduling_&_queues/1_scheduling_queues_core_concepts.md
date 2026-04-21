# NestJS Scheduling and Queues Core Concepts
Purpose: This note explains the core ideas behind cron jobs and background queues in NestJS before the full implementation walkthrough.

## Related Notes
- [2. Full Scheduling and Queues Learning Guide](./2_scheduling_queues_learning_guide.md)
- [3. NestJS Scheduling and Queue Runtime Flow](./3_nestjs_scheduling_queue_runtime_flow.md)
- [4. Scheduling and Queues Revision Cheatsheet](./4_scheduling_queues_revision_cheatsheet.md)

## 1. Why these tools exist
TaskFlow needs two kinds of background work:
- a daily digest email that must run every morning at 8am
- a welcome email after user registration that should not slow down the HTTP request

Those are different problems:
- time-driven work
- request-triggered work that should run later

That is why this topic covers both scheduling and queues.

## 2. The problem with doing everything inside the request
If registration sends the email inside the request:
- the user waits longer
- a slow email provider slows the API
- an email provider outage can break registration
- load spikes create many simultaneous external calls

The better pattern is:
1. save the user
2. add a background job
3. return the HTTP response immediately

## 3. The problem with time-based work
Some tasks are not triggered by any HTTP request:
- daily digests
- midnight cleanup
- overdue reminders

These need something that wakes up on a schedule and runs automatically.

## 4. When to use what
| Situation | Tool | Why |
| --- | --- | --- |
| Run code at a fixed time | Cron / `@nestjs/schedule` | time-driven, no user trigger |
| Offload slow work from a request | BullMQ queue | background processing with retries |
| Send email after a user action | BullMQ queue | decouples the side effect from the request |
| Bulk scheduled processing | cron + queue | cron enqueues, workers process |

## 5. What cron is in NestJS
A cron job is a method that runs automatically on a time schedule.

NestJS provides `@nestjs/schedule`, which supports:
- `@Cron()` for clock-based schedules
- `@Interval()` for every N milliseconds after startup
- `@Timeout()` for one-time delayed execution after startup

Important distinction:
- `@Cron()` is based on wall-clock time
- `@Interval()` is relative to app start time
- `@Timeout()` fires once

## 6. Cron expressions
Cron expressions define the schedule.

```text
* * * * * *
| | | | | |
| | | | | day of week
| | | | month
| | | day of month
| | hours
| minutes
seconds
```

Examples:
- `0 0 8 * * *` -> every day at 8:00am
- `0 0 * * * *` -> every hour
- `* * * * * *` -> every second

NestJS also exposes `CronExpression` constants so you do not need to memorize every pattern.

## 7. What BullMQ is
BullMQ is a Redis-backed job queue for Node.js.

It lets one part of the app add a job now and another part process it later.

That gives you:
- background processing
- retries
- delayed jobs
- persisted job state
- decoupling from the HTTP lifecycle

Redis matters because jobs survive application restarts.

## 8. Producer, queue, consumer
The queue model has three main pieces:

### Producer
A NestJS service that calls `queue.add()`.

Its job is to enqueue work and return quickly.

### Queue
The Redis-backed holding area where jobs wait.

### Consumer
A worker that listens to the queue and processes jobs in the background.

Short flow:
```text
HTTP request -> Producer -> Redis queue -> Consumer -> actual work
```

## 9. Job retries and failure handling
Background jobs often call unreliable external services, so retries are essential.

BullMQ supports:
- `attempts`
- `backoff`
- failed-job retention
- lifecycle events like `completed` and `failed`

That is one of the biggest advantages over “just call the service directly in the request.”

## 10. Why cron + queue is often the best production pattern
For bulk scheduled work, cron alone is often not enough.

Example:
- every day at 8am, send digests to 10,000 users

If the cron method sends everything directly:
- one big in-process job
- limited retry visibility
- no per-user failure handling

Better pattern:
1. cron fires at 8am
2. cron enqueues one job per user
3. workers process those jobs independently

This gives:
- parallelism
- retries per user
- better observability
- smaller cron methods

## 11. Production mindset
Important rules:
- always set a `timeZone` for cron jobs
- always configure retries for jobs that call external services
- keep queue names as constants
- avoid hardcoding Redis connection values
- use cron for schedule, queue for heavy or unreliable work

## 12. Concept checkpoints
If you can answer these quickly, the foundation is solid:
- When should you use `@Cron()` instead of BullMQ?
- What is the difference between `@Cron()`, `@Interval()`, and `@Timeout()`?
- Why does BullMQ use Redis?
- What is the difference between a producer and a consumer?
- Why is cron + queue usually better for bulk scheduled work?

If you want the implementation next, use [2. Full Scheduling and Queues Learning Guide](./2_scheduling_queues_learning_guide.md).

# NestJS Scheduling and Queue Runtime Flow
Purpose: This note explains what happens at runtime when cron jobs fire, jobs are queued, workers process them, and retries happen.

## Related Notes
- [1. Scheduling and Queues Core Concepts](./1_scheduling_queues_core_concepts.md)
- [2. Full Scheduling and Queues Learning Guide](./2_scheduling_queues_learning_guide.md)
- [4. Scheduling and Queues Revision Cheatsheet](./4_scheduling_queues_revision_cheatsheet.md)

## TaskFlow setup used in this note
Assume the app has:
- `ScheduleModule.forRoot()`
- a `ScheduledTasksService` with `@Cron()`, `@Interval()`, or `@Timeout()`
- BullMQ configured through `BullModule.forRootAsync()`
- an `email` queue with a producer and consumer

## 1. High-level lifecycle
```text
Startup
  -> scheduler initializes
  -> BullMQ connects to Redis
  -> cron jobs are registered
  -> workers start listening

Request-triggered queue flow
  -> request reaches service
  -> producer adds job
  -> HTTP response returns
  -> consumer processes job later

Scheduled bulk flow
  -> cron fires
  -> cron enqueues jobs
  -> workers process them
```

## 2. Scheduling runtime flow
1. `ScheduleModule.forRoot()` initializes the scheduler.
2. NestJS scans providers for `@Cron()`, `@Interval()`, and `@Timeout()`.
3. The scheduler registers those methods after app bootstrap.
4. When the time or interval matches, the method runs inside the app process.

Important distinctions:
- `@Cron()` runs on a wall-clock schedule
- `@Interval()` runs every N milliseconds after startup
- `@Timeout()` runs once after startup

## 3. Queue runtime flow
1. `BullModule.forRootAsync()` connects BullMQ to Redis.
2. `BullModule.registerQueue({ name: "email" })` registers the queue.
3. A producer calls `queue.add(...)`.
4. BullMQ stores the job in Redis.
5. The HTTP request can return immediately.
6. A consumer listening on the queue picks up the job later.
7. `process()` runs the background work.

This is the key benefit:
- request lifecycle and background work are decoupled

## 4. Welcome email flow
1. User hits `POST /auth/register`.
2. `AuthService.register()` creates the user.
3. `EmailProducer.queueWelcomeEmail()` adds the job to Redis.
4. Registration returns immediately.
5. `EmailConsumer` picks up the job.
6. `EmailService.sendWelcomeEmail()` does the actual work.
7. If the job succeeds, it moves to `completed`.
8. If it fails, BullMQ retries based on `attempts` and `backoff`.

## 5. Cron + queue flow
1. The cron method fires at 8am.
2. It fetches the users who need digests.
3. Instead of sending emails directly, it enqueues one job per user.
4. The cron method finishes quickly.
5. Workers process each queued job independently.

This is better than doing all work directly in the cron method because it gives:
- smaller cron methods
- retry handling per job
- better monitoring
- better parallelism

## 6. Job lifecycle
```text
waiting -> active -> completed
                 -> failed -> retry -> waiting
```

BullMQ also exposes worker events like:
- `active`
- `completed`
- `failed`

These are useful for logging and metrics.

## 7. Common failure points
| Symptom | Likely cause |
| --- | --- |
| cron fires at the wrong time | missing or incorrect `timeZone` |
| registration still feels slow | work is still happening inside the request instead of the queue |
| jobs never process | Redis is down, queue name mismatch, or consumer is not running |
| jobs fail forever | bad payload, broken external service, or retry config missing |
| cron job is heavy and blocks too long | it is doing the work directly instead of enqueueing jobs |

## 8. Debugging checklist
1. Is `ScheduleModule.forRoot()` registered?
2. Is `BullModule.forRootAsync()` connected to the correct Redis instance?
3. Do the producer and consumer use the exact same queue name?
4. Does the cron job set the intended `timeZone`?
5. Are retries configured for external-service jobs?
6. For scheduled bulk work, is cron enqueueing jobs instead of doing all work inline?

Use this note for lifecycle narration and debugging. Use [4. Scheduling and Queues Revision Cheatsheet](./4_scheduling_queues_revision_cheatsheet.md) when you only need the compressed version.

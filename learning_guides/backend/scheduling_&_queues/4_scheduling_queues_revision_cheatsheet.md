# Scheduling and Queues Revision Cheatsheet
Purpose: This is the shortest note in the set. Use it for quick recall, interview prep, and fast implementation review.

## Related Notes
- [1. Scheduling and Queues Core Concepts](./1_scheduling_queues_core_concepts.md)
- [2. Full Scheduling and Queues Learning Guide](./2_scheduling_queues_learning_guide.md)
- [3. NestJS Scheduling and Queue Runtime Flow](./3_nestjs_scheduling_queue_runtime_flow.md)

## Memorize These First
- use cron for time-driven work
- use BullMQ for background work and retries
- producers add jobs
- consumers process jobs
- Redis stores BullMQ jobs
- `@Cron()` is clock-based
- `@Interval()` is startup-relative
- cron + queue is best for scheduled bulk work

## Quick Facts
- `ScheduleModule.forRoot()` initializes Nest scheduling
- `BullModule.forRootAsync()` configures the Redis connection
- `BullModule.registerQueue()` registers a named queue
- `SchedulerRegistry` lets you stop or resume named cron jobs
- `attempts` and `backoff` control retries

## Cron decorator reminders
| Decorator | Use it for |
| --- | --- |
| `@Cron()` | fixed clock-based schedule |
| `@Interval()` | every N milliseconds after startup |
| `@Timeout()` | one-time delayed execution after startup |

## BullMQ role reminders
| Role | Responsibility |
| --- | --- |
| Producer | calls `queue.add()` |
| Queue | stores jobs in Redis |
| Consumer | processes jobs in background |

## Job lifecycle
```text
waiting -> active -> completed
                 -> failed -> retry -> waiting
```

## File map
| File | Purpose |
| --- | --- |
| `app.module.ts` | registers scheduling and BullMQ root config |
| `tasks/scheduled-tasks.service.ts` | cron, interval, timeout methods |
| `tasks/tasks.module.ts` | registers scheduled services |
| `email/email.module.ts` | registers the queue |
| `email/email.producer.ts` | enqueues jobs |
| `email/email.consumer.ts` | processes jobs |
| `email/email.service.ts` | does the actual work |
| `email/dto/welcome-email.job.ts` | job payload type |

## Common mistakes
- missing `timeZone` on cron jobs
- sending slow external work inside the request
- queue-name mismatches between producer and consumer
- missing retries for external-service jobs
- doing bulk scheduled work directly in cron instead of enqueueing

## Interview flash answers
**`@Cron()` vs `@Interval()` vs `@Timeout()`**
- `@Cron()` is clock-based
- `@Interval()` is startup-relative
- `@Timeout()` runs once after startup

**Producer vs Consumer**
- producer enqueues work
- consumer processes work later

**Why Redis for BullMQ?**
- it persists job state and lets workers process jobs outside the request lifecycle

## Last-minute recall
- cron decides when
- queue decides how
- producers enqueue
- consumers process
- retries make background work reliable

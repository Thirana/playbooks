# NestJS Task Scheduling and Queues
Purpose: This is the long-form implementation guide for cron jobs and BullMQ queues in NestJS.

## Related Notes
- [1. Scheduling and Queues Core Concepts](./1_scheduling_queues_core_concepts.md)
- [3. NestJS Scheduling and Queue Runtime Flow](./3_nestjs_scheduling_queue_runtime_flow.md)
- [4. Scheduling and Queues Revision Cheatsheet](./4_scheduling_queues_revision_cheatsheet.md)

## The User Story
TaskFlow needs two new features:

- every morning at 8am, email each user a digest of their open tasks
- after user registration, send a welcome email without slowing the registration request

These map to two different tools:
- daily digest -> cron scheduling
- welcome email -> BullMQ queue

## How To Use This Note
- Read this file for the full implementation walkthrough.
- Use [1. Scheduling and Queues Core Concepts](./1_scheduling_queues_core_concepts.md) for the ideas first.
- Use [3. NestJS Scheduling and Queue Runtime Flow](./3_nestjs_scheduling_queue_runtime_flow.md) for lifecycle and debugging.
- Use [4. Scheduling and Queues Revision Cheatsheet](./4_scheduling_queues_revision_cheatsheet.md) for quick revision.

## Part 1: Task scheduling with `@nestjs/schedule`
### Install
```bash
npm install --save @nestjs/schedule
```

### Register `ScheduleModule`
**`src/app.module.ts`**
```typescript
import { Module } from "@nestjs/common";
import { ScheduleModule } from "@nestjs/schedule";

@Module({
  imports: [ScheduleModule.forRoot()],
})
export class AppModule {}
```

### File structure
```text
src/
  tasks/
    scheduled-tasks.service.ts
    tasks.module.ts
```

### Cron expressions
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

Common examples:
- `0 0 8 * * *` -> every day at 8am
- `0 0 * * * *` -> every hour
- `* * * * * *` -> every second

You can also use `CronExpression` constants.

### Daily digest cron job
**`src/tasks/scheduled-tasks.service.ts`**
```typescript
import { Injectable, Logger } from "@nestjs/common";
import { Cron, CronExpression, Interval, Timeout } from "@nestjs/schedule";
import { UsersService } from "../users/users.service";
import { TasksService } from "./tasks.service";

@Injectable()
export class ScheduledTasksService {
  private readonly logger = new Logger(ScheduledTasksService.name);

  constructor(
    private readonly usersService: UsersService,
    private readonly tasksService: TasksService,
  ) {}

  @Cron(CronExpression.EVERY_DAY_AT_8AM, {
    name: "daily-digest",
    timeZone: "Asia/Colombo",
  })
  async handleDailyDigest() {
    this.logger.log("Running daily digest job");

    const users = await this.usersService.findAllActive();

    for (const user of users) {
      const openTasks = await this.tasksService.findOpenTasksForUser(user.id);

      if (openTasks.length > 0) {
        this.logger.log(
          `Sending digest to ${user.email}: ${openTasks.length} open tasks`,
        );
      }
    }

    this.logger.log("Daily digest job complete");
  }

  @Interval("overdue-check", 5 * 60 * 1000)
  async handleOverdueCheck() {
    this.logger.debug("Checking for overdue tasks...");
  }

  @Timeout(5000)
  handleStartupNotification() {
    this.logger.log("App has been running for 5 seconds — startup complete");
  }
}
```

Key points:
- `@Cron()` is clock-based
- `@Interval()` is startup-relative
- `@Timeout()` runs once
- always set `timeZone` for business-critical cron jobs

### Dynamic cron control with `SchedulerRegistry`
**`src/tasks/scheduled-tasks.service.ts`**
```typescript
import { SchedulerRegistry } from "@nestjs/schedule";

constructor(
  private readonly usersService: UsersService,
  private readonly tasksService: TasksService,
  private readonly schedulerRegistry: SchedulerRegistry,
) {}

pauseDailyDigest() {
  const job = this.schedulerRegistry.getCronJob("daily-digest");
  job.stop();
  this.logger.warn("Daily digest job PAUSED");
}

resumeDailyDigest() {
  const job = this.schedulerRegistry.getCronJob("daily-digest");
  job.start();
  this.logger.log("Daily digest job RESUMED");
}
```

### Register the service
**`src/tasks/tasks.module.ts`**
```typescript
import { Module } from "@nestjs/common";
import { UsersModule } from "../users/users.module";
import { ScheduledTasksService } from "./scheduled-tasks.service";

@Module({
  imports: [UsersModule],
  providers: [ScheduledTasksService],
})
export class TasksModule {}
```

## Part 2: Background queues with BullMQ
### Install
```bash
npm install --save @nestjs/bullmq bullmq
```

Redis must be running, because BullMQ stores jobs there.

### File structure
```text
src/
  email/
    email.module.ts
    email.producer.ts
    email.consumer.ts
    email.service.ts
    dto/
      welcome-email.job.ts
  app.module.ts
```

### Register BullMQ
**`src/app.module.ts`**
```typescript
import { Module } from "@nestjs/common";
import { BullModule } from "@nestjs/bullmq";
import { ConfigModule, ConfigService } from "@nestjs/config";

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    BullModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (configService: ConfigService) => ({
        connection: {
          host: configService.get<string>("REDIS_HOST", "localhost"),
          port: configService.get<number>("REDIS_PORT", 6379),
        },
      }),
    }),
  ],
})
export class AppModule {}
```

### Define the job payload type
**`src/email/dto/welcome-email.job.ts`**
```typescript
export interface WelcomeEmailJobData {
  userId: number;
  email: string;
  name: string;
}
```

### Register the queue
**`src/email/email.module.ts`**
```typescript
import { Module } from "@nestjs/common";
import { BullModule } from "@nestjs/bullmq";
import { EmailConsumer } from "./email.consumer";
import { EmailProducer } from "./email.producer";
import { EmailService } from "./email.service";

export const EMAIL_QUEUE = "email";

@Module({
  imports: [
    BullModule.registerQueue({
      name: EMAIL_QUEUE,
    }),
  ],
  providers: [EmailProducer, EmailConsumer, EmailService],
  exports: [EmailProducer],
})
export class EmailModule {}
```

### Producer: add jobs to the queue
**`src/email/email.producer.ts`**
```typescript
import { Injectable } from "@nestjs/common";
import { InjectQueue } from "@nestjs/bullmq";
import { Queue } from "bullmq";
import { WelcomeEmailJobData } from "./dto/welcome-email.job";
import { EMAIL_QUEUE } from "./email.module";

@Injectable()
export class EmailProducer {
  constructor(
    @InjectQueue(EMAIL_QUEUE) private readonly emailQueue: Queue,
  ) {}

  async queueWelcomeEmail(data: WelcomeEmailJobData): Promise<void> {
    await this.emailQueue.add("send-welcome-email", data, {
      attempts: 3,
      backoff: {
        type: "exponential",
        delay: 2000,
      },
      removeOnComplete: true,
      removeOnFail: false,
    });
  }

  async queueReminderEmail(data: WelcomeEmailJobData): Promise<void> {
    await this.emailQueue.add("send-reminder", data, {
      delay: 60 * 60 * 1000,
    });
  }
}
```

### Consumer: process jobs
**`src/email/email.consumer.ts`**
```typescript
import { Logger } from "@nestjs/common";
import { OnWorkerEvent, Processor, WorkerHost } from "@nestjs/bullmq";
import { Job } from "bullmq";
import { WelcomeEmailJobData } from "./dto/welcome-email.job";
import { EmailService } from "./email.service";
import { EMAIL_QUEUE } from "./email.module";

@Processor(EMAIL_QUEUE)
export class EmailConsumer extends WorkerHost {
  private readonly logger = new Logger(EmailConsumer.name);

  constructor(private readonly emailService: EmailService) {
    super();
  }

  async process(job: Job): Promise<any> {
    this.logger.log(`Processing job: ${job.name} | id: ${job.id}`);

    switch (job.name) {
      case "send-welcome-email":
        return this.handleWelcomeEmail(job as Job<WelcomeEmailJobData>);
      case "send-reminder":
        return this.handleReminderEmail(job as Job<WelcomeEmailJobData>);
      default:
        this.logger.warn(`Unknown job name: ${job.name}`);
    }
  }

  private async handleWelcomeEmail(job: Job<WelcomeEmailJobData>) {
    const { email, name } = job.data;
    await job.updateProgress(10);
    await this.emailService.sendWelcomeEmail(email, name);
    await job.updateProgress(100);
    this.logger.log(`Welcome email sent to ${email}`);
  }

  private async handleReminderEmail(job: Job<WelcomeEmailJobData>) {
    const { email } = job.data;
    await this.emailService.sendReminderEmail(email);
    this.logger.log(`Reminder email sent to ${email}`);
  }

  @OnWorkerEvent("completed")
  onCompleted(job: Job) {
    this.logger.log(`Job completed: ${job.name} | id: ${job.id}`);
  }

  @OnWorkerEvent("failed")
  onFailed(job: Job, error: Error) {
    this.logger.error(
      `Job failed: ${job.name} | id: ${job.id} | attempt: ${job.attemptsMade}`,
      error.stack,
    );
  }

  @OnWorkerEvent("active")
  onActive(job: Job) {
    this.logger.debug(`Job started: ${job.name} | id: ${job.id}`);
  }
}
```

### The actual work service
**`src/email/email.service.ts`**
```typescript
import { Injectable } from "@nestjs/common";

@Injectable()
export class EmailService {
  async sendWelcomeEmail(email: string, name: string): Promise<void> {
    await new Promise((resolve) => setTimeout(resolve, 1500));
    console.log(`[EmailService] Welcome email sent to ${email} (${name})`);
  }

  async sendReminderEmail(email: string): Promise<void> {
    await new Promise((resolve) => setTimeout(resolve, 500));
    console.log(`[EmailService] Reminder email sent to ${email}`);
  }
}
```

### Use the producer from `AuthService`
**`src/auth/auth.service.ts`**
```typescript
import { Injectable } from "@nestjs/common";
import { JwtService } from "@nestjs/jwt";
import { EmailProducer } from "../email/email.producer";
import { UsersService } from "../users/users.service";

@Injectable()
export class AuthService {
  constructor(
    private readonly usersService: UsersService,
    private readonly jwtService: JwtService,
    private readonly emailProducer: EmailProducer,
  ) {}

  async register(email: string, password: string) {
    const user = await this.usersService.create(email, password);

    await this.emailProducer.queueWelcomeEmail({
      userId: user.id,
      email: user.email,
      name: user.email,
    });

    const { password: _pw, ...result } = user;
    return result;
  }
}
```

### Job lifecycle
```text
queue.add() called
       |
       v
   [ waiting ]
       |
       v
   [ active ]
       |
   ----+----
   |       |
   v       v
[completed] [failed]
                |
                v
       retry back to [ waiting ] if attempts remain
```

## Part 3: Combine cron and queue
For scheduled bulk work, the best pattern is often:
- cron decides when
- the queue handles how

**`src/tasks/scheduled-tasks.service.ts`**
```typescript
import { Injectable, Logger } from "@nestjs/common";
import { Cron, CronExpression } from "@nestjs/schedule";
import { EmailProducer } from "../email/email.producer";
import { UsersService } from "../users/users.service";

@Injectable()
export class ScheduledTasksService {
  private readonly logger = new Logger(ScheduledTasksService.name);

  constructor(
    private readonly usersService: UsersService,
    private readonly emailProducer: EmailProducer,
  ) {}

  @Cron(CronExpression.EVERY_DAY_AT_8AM, {
    name: "daily-digest",
    timeZone: "Asia/Colombo",
  })
  async handleDailyDigest() {
    this.logger.log("Enqueueing daily digest jobs...");
    const users = await this.usersService.findAllActive();

    for (const user of users) {
      await this.emailProducer.queueWelcomeEmail({
        userId: user.id,
        email: user.email,
        name: user.email,
      });
    }

    this.logger.log(`Enqueued ${users.length} digest jobs`);
  }
}
```

Why this pattern is stronger:
- cron stays fast
- workers process jobs independently
- retries happen per user
- failures are visible per job

## Part 4: Production reminders
- always set `timeZone` in cron jobs
- use queue-name constants, not magic strings
- configure retries for external-service jobs
- keep `removeOnComplete: true` in production to reduce Redis memory use
- keep failed jobs when you need debugging visibility
- put Redis config in environment-based config management
- use cron + queue for scheduled bulk work

## Quick File Map
| File | Purpose |
| --- | --- |
| `app.module.ts` | registers `ScheduleModule` and BullMQ root config |
| `tasks/scheduled-tasks.service.ts` | cron, interval, timeout methods |
| `tasks/tasks.module.ts` | registers the scheduled service |
| `email/email.module.ts` | registers the BullMQ queue |
| `email/email.producer.ts` | adds jobs to the queue |
| `email/email.consumer.ts` | processes jobs in the background |
| `email/email.service.ts` | actual email sending logic |
| `email/dto/welcome-email.job.ts` | job payload type |

## Final Revision Anchors
- use cron for time-driven work
- use BullMQ for background work and retries
- producers add jobs, consumers process them
- `@Cron()` is clock-based, `@Interval()` is startup-relative
- cron + queue is the production pattern for scheduled bulk work

For the runtime story, go to [3. NestJS Scheduling and Queue Runtime Flow](./3_nestjs_scheduling_queue_runtime_flow.md). For quick recall, go to [4. Scheduling and Queues Revision Cheatsheet](./4_scheduling_queues_revision_cheatsheet.md).

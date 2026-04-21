# NestJS Logging with Winston

Purpose: This is the long-form implementation guide for production-oriented logging in NestJS with Winston and `nest-winston`.

## Related Notes

- [1. Logging Core Concepts](./1_logging_core_concepts.md)
- [3. NestJS Logging Runtime Flow](./3_nestjs_logging_runtime_flow.md)
- [4. Logging Revision Cheatsheet](./4_logging_revision_cheatsheet.md)

---

## The Developer Requirement

TaskFlow's API is live in production. A customer reports that their tasks are not saving. The server is running, but the logs are not useful. The only output is the default NestJS startup logging, with no structured request or error context.

The new requirements are:

- every incoming HTTP request must be logged
- errors must include stack traces
- local logs must stay readable
- production logs must be JSON
- every request must carry a `requestId`
- every log line must include the service name

---

## How To Use This Note

- Read this file when you want the full implementation walkthrough.
- Use [1. Logging Core Concepts](./1_logging_core_concepts.md) when you want the mental model first.
- Use [3. NestJS Logging Runtime Flow](./3_nestjs_logging_runtime_flow.md) when you want to understand bootstrap and request order.
- Use [4. Logging Revision Cheatsheet](./4_logging_revision_cheatsheet.md) for quick revision and interview prep.

---

## Part 1: Core Mental Model

### Why not rely only on NestJS's built-in logger

NestJS's built-in logger is useful, but it is not ideal for the TaskFlow production requirements.

The main gaps are:

- weaker structured metadata support
- less flexible formatting
- less natural JSON-first production output
- no built-in pattern for rich request correlation fields like `requestId`

Winston solves those issues with configurable formats, levels, and transports.

### What Winston brings

Winston gives you:

- configurable log levels
- format pipelines
- structured metadata
- environment-specific output styles
- reusable logger construction through a factory function

### Why metadata objects matter

Prefer:

```typescript
logger.log("info", "Task created", {
  event: "task.created",
  taskId: task.id,
  requestId,
});
```

over embedding details directly in the message string. That keeps the message stable and the metadata queryable.

If you want the concept-only version of these ideas, see [1. Logging Core Concepts](./1_logging_core_concepts.md).

---

## Part 2: Project Setup

### Install dependencies

```bash
npm install --save winston nest-winston
```

### File structure

```text
src/
  logger/
    logger.config.ts
    logger.module.ts
    http-logger.middleware.ts
  app.module.ts
  main.ts
```

Each file has a clear role:

- `logger.config.ts` -> constructs the Winston configuration
- `logger.module.ts` -> registers Winston with NestJS
- `http-logger.middleware.ts` -> logs every request
- `main.ts` -> replaces the NestJS logger during bootstrap

---

## Part 3: The Winston Config Factory

The config factory should be reusable and easy to reason about. It decides:

- log level
- output style
- service name

**`src/logger/logger.config.ts`**

```typescript
import { format, transports, LoggerOptions } from "winston";

const { colorize, combine, errors, json, printf, timestamp } = format;

export function buildWinstonConfig(
  level: string,
  outputFormat: "pretty" | "json",
  serviceName: string,
): LoggerOptions {
  const jsonFormat = combine(timestamp(), errors({ stack: true }), json());

  const prettyFormat = combine(
    timestamp({ format: "HH:mm:ss" }),
    errors({ stack: true }),
    printf(({ timestamp, level, message, stack, ...meta }) => {
      const fields = [
        meta.event,
        meta.requestId,
        meta.method,
        meta.path,
        meta.statusCode != null ? String(meta.statusCode) : undefined,
        meta.durationMs != null ? `${String(meta.durationMs)}ms` : undefined,
      ]
        .filter(Boolean)
        .join(" ");

      const base = `${timestamp} [${level}] ${message}${fields ? " " + fields : ""}`;
      return stack ? `${base}\n${stack}` : base;
    }),
    colorize({ all: true }),
  );

  return {
    level,
    defaultMeta: { service: serviceName },
    format: outputFormat === "json" ? jsonFormat : prettyFormat,
    transports: [new transports.Console()],
  };
}
```

Why this structure works:

- the caller controls verbosity with `LOG_LEVEL`
- the caller controls output style with `NODE_ENV`
- `defaultMeta` guarantees the service name is always present
- `errors({ stack: true })` preserves stack traces

---

## Part 4: The Logger Module

The logger module creates the Winston instance and exposes it to the rest of the NestJS app.

**`src/logger/logger.module.ts`**

```typescript
import { Global, Module } from "@nestjs/common";
import { WinstonModule } from "nest-winston";
import { buildWinstonConfig } from "./logger.config";

@Global()
@Module({
  imports: [
    WinstonModule.forRoot(
      buildWinstonConfig(
        process.env.LOG_LEVEL || "debug",
        process.env.NODE_ENV === "production" ? "json" : "pretty",
        "taskflow-api",
      ),
    ),
  ],
})
export class LoggerModule {}
```

Why these env variables matter:

- `LOG_LEVEL` controls how noisy the logs are
- `NODE_ENV` switches between human-readable output and JSON

The `@Global()` decorator means the logger can be used throughout the app without repeatedly importing the module.

---

## Part 5: Wire Winston Into NestJS

There are two kinds of logs you care about:

- NestJS bootstrap logs
- your application's own logs

To unify them, replace the default logger in `main.ts`.

**`src/main.ts`**

```typescript
import { NestFactory } from "@nestjs/core";
import { WINSTON_MODULE_NEST_PROVIDER } from "nest-winston";
import { AppModule } from "./app.module";

async function bootstrap() {
  const app = await NestFactory.create(AppModule, {
    bufferLogs: true,
  });

  app.useLogger(app.get(WINSTON_MODULE_NEST_PROVIDER));

  const port = process.env.PORT || 3000;
  await app.listen(port);
}

bootstrap();
```

Why `bufferLogs: true` matters:

- early NestJS bootstrap logs are buffered
- once Winston is attached, those buffered logs flush through Winston
- you avoid mixed output from two different logging systems

**`src/app.module.ts`**

```typescript
import { Module } from "@nestjs/common";
import { ConfigModule } from "@nestjs/config";
import { LoggerModule } from "./logger/logger.module";

@Module({
  imports: [ConfigModule.forRoot({ isGlobal: true }), LoggerModule],
})
export class AppModule {}
```

---

## Part 6: Inject and Use the Logger in Services

Service-level logs provide the business context that request logs alone cannot provide.

**`src/tasks/tasks.service.ts`**

```typescript
import { Inject, Injectable, NotFoundException } from "@nestjs/common";
import { WINSTON_MODULE_NEST_PROVIDER } from "nest-winston";
import { Logger } from "winston";

@Injectable()
export class TasksService {
  constructor(
    @Inject(WINSTON_MODULE_NEST_PROVIDER)
    private readonly logger: Logger,
  ) {}

  async findOne(id: string, requestId?: string) {
    this.logger.log("info", "Fetching task", {
      event: "task.fetch",
      taskId: id,
      requestId,
    });

    const task = await this.findTaskById(id);

    if (!task) {
      this.logger.log("warn", "Task not found", {
        event: "task.not_found",
        taskId: id,
        requestId,
      });
      throw new NotFoundException(`Task ${id} not found`);
    }

    return task;
  }

  async createTask(data: any, requestId?: string) {
    try {
      const task = await this.saveTask(data);
      this.logger.log("info", "Task created", {
        event: "task.created",
        taskId: task.id,
        requestId,
      });
      return task;
    } catch (error) {
      this.logger.log("error", "Failed to create task", {
        event: "task.create_failed",
        error,
        requestId,
      });
      throw error;
    }
  }

  private async findTaskById(id: string) {
    return null;
  }

  private async saveTask(data: any) {
    return { id: "1", ...data };
  }
}
```

Important rule:

- use a stable message
- pass detailed fields as metadata

That keeps logs queryable and consistent.

---

## Part 7: HTTP Request Logging Middleware

Request logging belongs in middleware because it wraps the request/response lifecycle and can measure total duration.

**`src/logger/http-logger.middleware.ts`**

```typescript
import { randomUUID } from "crypto";
import { Inject, Injectable, NestMiddleware } from "@nestjs/common";
import { NextFunction, Request, Response } from "express";
import { WINSTON_MODULE_NEST_PROVIDER } from "nest-winston";
import { Logger } from "winston";

@Injectable()
export class HttpLoggerMiddleware implements NestMiddleware {
  constructor(
    @Inject(WINSTON_MODULE_NEST_PROVIDER)
    private readonly logger: Logger,
  ) {}

  use(req: Request, res: Response, next: NextFunction) {
    const { method, originalUrl } = req;
    const startTime = Date.now();

    const requestId = (req as any).requestId || randomUUID();
    (req as any).requestId = requestId;

    res.on("finish", () => {
      const durationMs = Date.now() - startTime;
      const { statusCode } = res;

      const level =
        statusCode >= 500 ? "error" : statusCode >= 400 ? "warn" : "info";

      this.logger.log(level, "HTTP request", {
        event: "http.request",
        method,
        path: originalUrl,
        statusCode,
        durationMs,
        requestId,
      });
    });

    next();
  }
}
```

Why this works well:

- every request gets a `requestId`
- final status code is known on `finish`
- latency is measured consistently
- log level reflects outcome severity

Register it globally:

**`src/app.module.ts`**

```typescript
import { MiddlewareConsumer, Module, NestModule } from "@nestjs/common";
import { LoggerModule } from "./logger/logger.module";
import { HttpLoggerMiddleware } from "./logger/http-logger.middleware";

@Module({
  imports: [LoggerModule],
})
export class AppModule implements NestModule {
  configure(consumer: MiddlewareConsumer) {
    consumer.apply(HttpLoggerMiddleware).forRoutes("*");
  }
}
```

---

## Part 8: What the Output Looks Like

### Development output

```text
10:23:44 [info] Starting Nest application...
10:23:44 [info] Server listening on port 3000
10:23:46 [info] HTTP request http.request abc-123-xyz GET /tasks 200 34ms
10:23:47 [info] Fetching task task.fetch abc-123-xyz
10:23:48 [warn] Task not found task.not_found abc-123-xyz
10:23:49 [error] Failed to create task task.create_failed abc-123-xyz
Error: connect ECONNREFUSED 127.0.0.1:5432
    at TCPConnectWrap.afterConnect (node:net:1300:16)
```

### Production JSON output

```json
{
  "level": "info",
  "message": "HTTP request",
  "event": "http.request",
  "method": "GET",
  "path": "/tasks",
  "statusCode": 200,
  "durationMs": 34,
  "requestId": "abc-123-xyz",
  "service": "taskflow-api",
  "timestamp": "2025-04-20T10:23:46.000Z"
}
```

This is the key tradeoff:

- pretty logs optimize for humans
- JSON logs optimize for machines and aggregators

---

## Part 9: Production Notes

### Use sensible log levels

A common rule is:

- development -> `debug`
- production -> `info`
- high-noise or high-cost scenarios -> `warn` or `error`

### Keep sensitive data out of logs

Never log:

- passwords
- tokens
- secrets
- raw request bodies without sanitization

### Keep metadata consistent

Prefer a stable field set such as:

- `event`
- `requestId`
- `method`
- `path`
- `statusCode`
- `durationMs`

Consistency makes dashboards and searches much easier.

### Use the `service` field everywhere

This is especially important when multiple apps send logs into the same platform.

---

## Quick File Map

| File | Purpose |
| --- | --- |
| `logger/logger.config.ts` | Builds the Winston config and output format |
| `logger/logger.module.ts` | Registers Winston inside NestJS |
| `logger/http-logger.middleware.ts` | Logs every request with request metadata |
| `app.module.ts` | Imports logger setup and applies middleware |
| `main.ts` | Replaces NestJS's default logger with Winston |

---

## Final Revision Anchors

If you only remember a few things, remember these:

- use structured metadata, not message-string interpolation
- attach Winston through `nest-winston`
- use `bufferLogs: true` before `app.useLogger()`
- attach a `requestId` to every request
- use pretty logs locally and JSON logs in production

For the lifecycle story, go to [3. NestJS Logging Runtime Flow](./3_nestjs_logging_runtime_flow.md). For quick recall, go to [4. Logging Revision Cheatsheet](./4_logging_revision_cheatsheet.md).

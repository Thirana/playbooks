# Logging Revision Cheatsheet: NestJS + Winston

Purpose: This is the shortest note in the set. Use it for quick recall, interview prep, and fast implementation review.

## Related Notes

- [1. Logging Core Concepts](./1_logging_core_concepts.md)
- [2. Full Logging Learning Guide](./2_logging_learning_guide.md)
- [3. NestJS Logging Runtime Flow](./3_nestjs_logging_runtime_flow.md)

---

## Memorize These First

- use Winston for production-friendly logging
- use `nest-winston` to integrate Winston with NestJS
- use `bufferLogs: true` before `app.useLogger()`
- pretty logs are for local development
- JSON logs are for production aggregators
- keep details in metadata objects, not message strings
- attach `requestId` to every request
- include `service` in every log line

---

## Winston Quick Facts

- `level` decides severity
- `format` transforms log entries
- `transport` decides where logs go
- `defaultMeta` adds fields automatically to every log
- `errors({ stack: true })` preserves stack traces

---

## Environment Rules

- `LOG_LEVEL` controls verbosity
- `NODE_ENV=production` usually means JSON logs
- local development usually uses a readable pretty format

Common production default:

- `info`

Common local default:

- `debug`

---

## Metadata Fields To Keep Consistent

Typical fields:

- `event`
- `requestId`
- `method`
- `path`
- `statusCode`
- `durationMs`
- `service`

Good pattern:

```typescript
logger.log("info", "Task created", {
  event: "task.created",
  taskId: task.id,
  requestId,
});
```

---

## Runtime Flow In One Glance

### Bootstrap

```text
NestFactory.create({ bufferLogs: true })
  -> Winston created
  -> app.useLogger()
  -> bootstrap logs flow through Winston
```

### Request

```text
middleware assigns requestId
  -> service logs business events
  -> response finishes
  -> middleware logs method/path/status/duration
```

---

## Main API Surface

| Item | Job |
| --- | --- |
| `buildWinstonConfig()` | Builds Winston configuration |
| `WinstonModule.forRoot()` | Registers Winston in NestJS |
| `WINSTON_MODULE_NEST_PROVIDER` | Injection token for the logger |
| `app.useLogger()` | Replaces NestJS built-in logger |
| `errors({ stack: true })` | Preserves error stack traces |

---

## File Responsibility Map

| File | Main responsibility |
| --- | --- |
| `logger.config.ts` | Logger config factory |
| `logger.module.ts` | Winston registration |
| `http-logger.middleware.ts` | Request logging and `requestId` |
| `app.module.ts` | Imports logger setup and applies middleware |
| `main.ts` | Swaps NestJS logger to Winston |

---

## Common Mistakes

- forgetting `bufferLogs: true`
- forgetting `app.useLogger()`
- missing `requestId` propagation
- logging details inside the message string
- losing stack traces by not using `errors({ stack: true })`
- using `debug` level in noisy production environments
- logging passwords, tokens, or unsafe request bodies

---

## Interview Prompts and Fast Answers

**Why use Winston instead of the built-in Nest logger?**

- for richer formatting, structured JSON, metadata fields, and better production flexibility

**Why use middleware for request logging?**

- because it wraps the full request lifecycle and can log final status and duration on `finish`

**What does `bufferLogs: true` do?**

- it buffers early NestJS logs until Winston is attached

**Why use `errors({ stack: true })`?**

- to preserve stack traces in structured logs

**Why use metadata objects instead of string interpolation?**

- because metadata stays queryable and consistent

---

## Last-Minute Recall

If you are revising in 30 seconds, remember this:

- Winston replaces the default logger
- bootstrap logs and app logs should use the same logger
- middleware gives you `requestId`, status, and duration
- JSON is for machines, pretty logs are for humans

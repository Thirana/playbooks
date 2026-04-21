# NestJS Logging Runtime Flow

Purpose: This note explains how logging behaves at runtime during NestJS bootstrap and during request handling.

## Related Notes

- [1. Logging Core Concepts](./1_logging_core_concepts.md)
- [2. Full Logging Learning Guide](./2_logging_learning_guide.md)
- [4. Logging Revision Cheatsheet](./4_logging_revision_cheatsheet.md)

---

## TaskFlow setup used in this note

Assume the app has:

- Winston configured through `nest-winston`
- a reusable `buildWinstonConfig()` factory
- `bufferLogs: true` in `NestFactory.create()`
- `HttpLoggerMiddleware` attached globally
- service-level logs that include `requestId`

---

## 1. The high-level lifecycle

For this logging setup, there are two important flows:

- bootstrap logging flow
- per-request logging flow

Simplified picture:

```text
Application bootstrap
  -> Nest starts
  -> Winston logger created
  -> app.useLogger() replaces default logger

Request handling
  -> middleware assigns requestId
  -> request completes
  -> middleware logs request summary
  -> services emit business logs
  -> errors include stack traces
```

---

## 2. Bootstrap logging flow

Bootstrap logging happens while the app is still starting up.

### Runtime sequence

1. `NestFactory.create(AppModule, { bufferLogs: true })` begins application creation.
2. NestJS may emit internal startup logs during bootstrapping.
3. Because `bufferLogs: true` is enabled, those logs are buffered instead of printed through the default logger immediately.
4. `LoggerModule` creates the Winston instance through `WinstonModule.forRoot(...)`.
5. `main.ts` retrieves `WINSTON_MODULE_NEST_PROVIDER` from the DI container.
6. `app.useLogger(...)` replaces NestJS's built-in logger with Winston.
7. Buffered bootstrap logs are now flushed through Winston instead of the default logger.

Why this matters:

- startup logs and application logs use the same logger
- output format stays consistent
- you avoid mixed logger output

---

## 3. Config-to-output flow

The logger configuration determines what the output looks like.

### Runtime sequence

1. `LoggerModule` reads `LOG_LEVEL`.
2. `LoggerModule` reads `NODE_ENV`.
3. `buildWinstonConfig()` picks the log level.
4. It selects `pretty` or `json` format.
5. It injects `service: "taskflow-api"` into `defaultMeta`.
6. Winston writes to the console transport using the chosen format.

Short rule:

- `NODE_ENV=production` -> JSON logs
- otherwise -> pretty logs

And:

- `LOG_LEVEL` decides how much gets emitted

---

## 4. Per-request logging flow

The request lifecycle starts in middleware.

### Runtime sequence

1. A request enters the app.
2. `HttpLoggerMiddleware` runs before the route handler.
3. The middleware records `startTime`.
4. The middleware creates or reuses a `requestId`.
5. The `requestId` is attached to `req`.
6. The middleware registers a `res.on("finish")` callback.
7. The request moves forward to controllers and services.

At this point:

- the request is not logged yet
- the middleware is waiting for the final response outcome

---

## 5. Service-level logging flow

During request handling, services log business events.

Example sequence:

1. `TasksService.findOne()` starts.
2. The service logs `"Fetching task"` with:
   `event`, `taskId`, and `requestId`
3. Business logic runs.
4. If the task is missing, the service logs a warning.
5. If task creation fails, the service logs an error with the error object attached.

Why this matters:

- request logs tell you what entered and exited
- service logs tell you what happened inside

Together they give you the full story.

---

## 6. Response completion flow

Once the response is finished, the middleware logs the request summary.

### Runtime sequence

1. Express emits the `finish` event on the response.
2. The middleware calculates `durationMs`.
3. The final `statusCode` is now known.
4. The middleware picks a level:
   `error` for 5xx, `warn` for 4xx, `info` otherwise.
5. The middleware emits the `"HTTP request"` log with:
   `event`, `method`, `path`, `statusCode`, `durationMs`, and `requestId`.

This is why `res.on("finish")` is useful:

- it captures the final response state
- it works even when exceptions are transformed into HTTP responses

---

## 7. Error stack flow

Errors are only truly useful if the stack trace is preserved.

### Runtime sequence

1. A service catches or surfaces an error.
2. The logger receives the `error` object in metadata.
3. Winston's `errors({ stack: true })` format extracts the stack.
4. The output includes stack information in either:
   pretty format or JSON format.

Without that format, the log may lose the most useful debugging detail.

---

## 8. End-to-end runtime story

This is the compact interview narration:

1. The app starts with `bufferLogs: true`.
2. Winston is created through `nest-winston`.
3. `app.useLogger()` replaces the default NestJS logger.
4. A request enters and middleware assigns a `requestId`.
5. Services emit structured logs using the same `requestId`.
6. If an error occurs, the stack trace is preserved by `errors({ stack: true })`.
7. When the response finishes, middleware logs method, path, status, duration, and `requestId`.
8. In development, the output is pretty and readable. In production, the same fields appear as structured JSON.

---

## 9. Common failure points

| Symptom | Likely cause |
| --- | --- |
| Early startup logs use a different format | `bufferLogs: true` was missing or `app.useLogger()` happened too late |
| `requestId` is missing from service logs | it was not attached to the request or not passed down to services |
| Error logs have no stack trace | `errors({ stack: true })` is missing or the error object was flattened incorrectly |
| Logs are too noisy in production | `LOG_LEVEL` is too low, often `debug` |
| Production logs are not JSON | `NODE_ENV` does not resolve to `production` or format selection is wrong |

---

## 10. Debugging checklist

When logging is behaving incorrectly, check in this order:

1. Does `main.ts` use `bufferLogs: true` and `app.useLogger()`?
2. Does `LoggerModule` actually register Winston through `WinstonModule.forRoot()`?
3. Is the chosen format tied correctly to `NODE_ENV`?
4. Is `LOG_LEVEL` set to the intended verbosity?
5. Does middleware assign and preserve `requestId`?
6. Are services logging metadata objects instead of stuffing details into strings?
7. Is `errors({ stack: true })` present in the format pipeline?

Use this note for lifecycle narration and debugging. Use [4. Logging Revision Cheatsheet](./4_logging_revision_cheatsheet.md) when you only need the compressed version.

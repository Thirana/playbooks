# NestJS Logging Core Concepts

Purpose: This note explains the mental model behind production logging in NestJS before you get into the full Winston setup.

## Related Notes

- [2. Full Logging Learning Guide](./2_logging_learning_guide.md)
- [3. NestJS Logging Runtime Flow](./3_nestjs_logging_runtime_flow.md)
- [4. Logging Revision Cheatsheet](./4_logging_revision_cheatsheet.md)

---

## 1. Why production logging matters

Logging is not just for debugging during development. In production, logs are one of the main ways to answer questions like:

- what request failed
- where the failure happened
- how long the request took
- whether the failure is isolated or widespread
- which service produced the error

If the application is running but observability is poor, incidents become much harder to diagnose.

---

## 2. Why NestJS's built-in logger is often not enough

NestJS ships with a built-in logger, and it is fine for small apps or early development. But for the TaskFlow use case, it falls short in a few important ways:

- structured metadata is limited
- production-ready JSON output is not the main design goal
- custom formatting becomes awkward
- request correlation fields like `requestId` are not first-class
- multi-service filtering with consistent metadata is harder

That is why many NestJS projects switch to Winston or Pino for production logging.

---

## 3. What Winston gives you

Winston is a configurable logging library built around a few core ideas.

### Level

A log level defines severity:

- `error`
- `warn`
- `info`
- `http`
- `debug`
- `verbose`

Only logs at or above the configured level are emitted.

### Format

A format transforms log entries before output.

Examples:

- add timestamps
- serialize as JSON
- colorize terminal output
- print stack traces
- render a custom pretty line

### Transport

A transport is where logs go.

Examples:

- console
- file
- HTTP endpoint
- vendor-specific integrations

### `defaultMeta`

`defaultMeta` is metadata automatically attached to every log line.

Example:

```typescript
defaultMeta: { service: "taskflow-api" }
```

That keeps repeated fields consistent without manually passing them every time.

---

## 4. What `nest-winston` does

`nest-winston` is the adapter that connects Winston to NestJS.

It gives you:

- a Nest-compatible logger provider
- a way to replace Nest's built-in logger with Winston
- DI-friendly access to the logger inside services and modules

Short version:

- Winston does the logging
- `nest-winston` makes Winston fit naturally into NestJS

---

## 5. Structured metadata vs message-string logging

A major production logging rule is:

- keep the human-readable message simple
- put searchable details into metadata fields

Better:

```typescript
logger.log("info", "Task created", {
  event: "task.created",
  taskId: task.id,
  requestId,
});
```

Worse:

```typescript
logger.log("info", `Task ${task.id} created for request ${requestId}`);
```

Why metadata objects are better:

- fields stay queryable in JSON logs
- dashboards and aggregators can filter on them
- messages stay cleaner and more consistent

---

## 6. Pretty vs JSON output

Production logging usually needs two output styles.

### Pretty format

Best for local development.

It is:

- colorized
- easy to scan in the terminal
- optimized for humans

### JSON format

Best for production and log aggregation.

It is:

- machine-readable
- structured
- easy to index and search
- better for CloudWatch, Datadog, ELK, and similar systems

Common rule:

- `NODE_ENV=production` -> JSON
- local development -> pretty format

---

## 7. Why `requestId` and `service` matter

Two metadata fields are especially important.

### `requestId`

`requestId` ties multiple log lines back to the same HTTP request.

That lets you trace:

- request received
- service call started
- warning or failure happened
- response sent

### `service`

`service` identifies which service emitted the log.

This matters when:

- multiple services write to the same logging system
- the same event name exists in multiple services
- you need clean filtering by system boundary

---

## 8. Why `errors({ stack: true })` matters

JavaScript `Error` objects do not serialize cleanly by default. One important field, `stack`, is non-enumerable.

Without special handling, you may log an error and lose the useful stack trace.

Winston's `errors({ stack: true })` format fixes that by extracting the stack into the log entry.

That makes error logs useful in both:

- pretty terminal output
- JSON production output

---

## 9. Bootstrap logging vs request logging

NestJS logging happens in two different phases.

### Bootstrap logging

These are the logs printed while the app starts:

- creating the app
- loading modules
- mapping routes
- startup success or failure

### Request logging

These are the logs emitted while handling actual traffic:

- incoming HTTP request
- service-level operations
- warnings
- exceptions
- response completion

Production setups should handle both through the same logging system for consistency.

---

## 10. Log levels in practice

Use levels by intent, not by habit.

- `error` -> something failed and needs attention
- `warn` -> unexpected but still recoverable behavior
- `info` -> normal operational events
- `http` -> request-level traffic events, if your team uses it
- `debug` -> detailed diagnostics for development
- `verbose` -> extra-noisy diagnostics, rarely used

Practical rule:

- development often uses `debug`
- production usually uses `info` or `warn`

That is where `LOG_LEVEL` becomes useful.

---

## 11. Production mindset

A good production logger should:

- emit structured data
- preserve stack traces
- include request correlation data
- avoid sensitive data leakage
- support environment-based format changes

Important reminder:

- never log passwords, tokens, or raw request bodies without sanitizing them

---

## 12. Concept checkpoints

If you can answer these quickly, the core ideas are solid:

- Why is structured metadata better than stuffing details into the message string?
- Why is JSON preferred in production?
- What problem does `requestId` solve?
- What does `nest-winston` adapt for NestJS?
- Why does `errors({ stack: true })` matter?

If you want the bootstrap and request lifecycle next, use [3. NestJS Logging Runtime Flow](./3_nestjs_logging_runtime_flow.md).

# NestJS Production Bootstrap — Guide

This document explains what the bootstrap playbook builds and why each decision
was made. Read this before reading the playbook. It is not a step-by-step
instruction — it is the reasoning behind the steps.

---

## What It Builds

The playbook produces a minimal but fully production-shaped NestJS API. It
contains no business logic or application features. What it does contain is
every structural concern a real production service needs from day one: structured
logging, request tracing, consistent error handling, environment validation,
database connectivity, health endpoints, and a test baseline.

Think of it as the skeleton every service in your organization starts from,
not a demo you throw away.

---

## Why Each Decision Was Made

### Deriving names from the directory

The package name, database name, and logger service name are all derived from
the directory the project lives in. When you see a log line saying
`service: "billing-api"`, you immediately know which repo and database it came
from. Naming things manually leads to drift — the package is called one thing,
the database another. That becomes a real operational headache across many
services.

---

### Strict TypeScript from the start

TypeScript's strict mode is turned on from the beginning, meaning the compiler
catches more mistakes before the code ever runs. The common objection is that it
slows down early development. In practice, the opposite is true over time —
strict code is safer to change, easier to review, and produces fewer production
bugs caused by unexpected `null` or `undefined` values slipping through.

Starting strict is much easier than adding it to an existing codebase.

---

### ESLint and Prettier as separate tools

ESLint checks code quality. Prettier handles formatting. They do not overlap.

A common alternative is to run Prettier inside ESLint so formatting violations
appear as lint errors. This sounds convenient but it creates noise: code quality
findings and formatting findings are mixed together in the same output, lint runs
get slower, and it becomes unclear what `--fix` is actually changing.

Keeping them separate means `npm run lint` tells you about code problems and
`npm run format:check` tells you about formatting. Each tool has one job.

---

### Fail-fast environment validation

If a required environment variable is missing or wrong, the application throws
an error immediately on startup rather than starting and failing later in
unexpected ways.

Without this, a service might start successfully but then fail on the first
database call because `DATABASE_URL` was never set. That kind of failure is
harder to diagnose and might not surface until real traffic hits. A clear error
at startup is much easier to act on.

The `LOG_FORMAT` defaulting to `pretty` in development and `json` in production
is an example of the same thinking: sensible behavior without manual
configuration, but with clear overrides when needed.

---

### One logging pipeline that only changes its presentation

Every environment uses the same logger. In development it outputs colorized,
readable lines. In production it outputs structured JSON. The underlying log
data is identical — only the way it looks changes.

A common alternative is to use `console.log` locally and a structured logger in
production. The problem is your app then behaves differently in development than
it does in production. Bugs in how things are logged only appear where you cannot
easily debug them.

One pipeline also means developers see the same fields locally that show up in
production monitoring. Nothing is hidden.

---

### Request ID on every request

Every request gets a unique ID attached to it. That ID flows through every log
line and appears in every error response.

When something goes wrong in production, the first question is: which request
caused this? Without a request ID you are guessing. With one, you can find every
related log line instantly. If a caller provides their own `x-request-id` header,
that value is preserved so the ID can be traced across multiple services.

---

### Consistent error responses

Every error — validation failures, not found, server crashes — returns the same
JSON shape: status code, message, a machine-readable error code, the request ID,
and a timestamp.

Without this, different errors return different shapes and client developers
cannot rely on a predictable structure. The machine-readable error code is
particularly useful: it lets a client handle specific errors programmatically
without parsing human-readable messages, and lets you change the message text
later without breaking anything.

---

### Strict request validation

Every incoming request is validated against a defined shape. Unexpected fields
are rejected and a validation failure always returns the consistent error shape
described above.

This keeps the API contract strict and surfaces client mistakes early rather
than letting malformed data pass through to the service layer.

---

### Prisma with migrations only

Schema changes must go through migration files. There is no automatic
synchronization where the database adjusts itself to match the current code.

Auto-sync is convenient in development but dangerous in production. A deployment
could silently alter a production database — dropping a column, changing a
constraint — without any review. Migration files are explicit, versioned, and
reviewable. Every schema change is a deliberate decision with a record of what
changed and when.

---

### Two health endpoints, not one

The playbook creates a liveness endpoint and a readiness endpoint separately.

Liveness answers: _is the process alive?_ It should always return OK as long as
the process is running, regardless of whether the database is up.

Readiness answers: _should this instance receive traffic right now?_ It checks
the database with a real query. If the database is unreachable, readiness fails
and the load balancer stops sending traffic to that instance without restarting
it.

Using a static success response for readiness defeats the purpose entirely. If
the database is down, a real check stops traffic from reaching instances that
cannot serve requests. A fake one just hides the problem.

---

### URI versioning from the beginning

All endpoints are under `/v1/...` from the first commit.

Adding versioning to an existing deployed API is a breaking change for anyone
already using it. Starting with it in place means adding `v2` later costs
nothing. Skipping it to save time early almost always costs more time later.

---

### The test strategy

Three kinds of tests are included:

- **End-to-end smoke tests** — verify that the whole stack is wired up and
  working together correctly.
- **Request ID tests** — verify that the request ID flows correctly through
  successful responses and error responses alike.
- **Bootstrap failure test** — verifies that a misconfigured app exits with a
  clear error rather than starting up in a broken state. This test runs the app
  in a separate process, which is the only reliable way to test startup failure
  behavior.

---

### `AGENTS.md` in the repository

A short file at the root of the repository describes the project's conventions
to any developer or coding agent working in it later. It lists what patterns
exist, what commands to run before finishing a task, and what to preserve.

Without it, someone working in the repo months later may not know why things
are set up the way they are, and may change them without realising the
consequences.

---

## What It Leaves Out

The playbook does not include authentication, rate limiting, CI workflow files,
git hooks, or business modules. These are all things many projects need, but
they are project-specific decisions that a bootstrap template should not make
for you.

A starting point that includes too much becomes something you spend time undoing
rather than building on.

---

## The Short Version

Every decision in this playbook comes down to three things:

- **Fail loudly and early** — environment validation, strict TypeScript,
  migration-only database changes.
- **Separate concerns cleanly** — ESLint for quality, Prettier for formatting,
  one logger for all environments, two health endpoints for two different signals.
- **Make the implicit explicit** — request IDs in every log line, consistent
  error shapes, versioning from day one.

The result is a starting point where the structural decisions are already made,
so the team can focus on building the actual product.

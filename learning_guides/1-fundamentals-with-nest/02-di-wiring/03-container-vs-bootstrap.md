# Container vs Bootstrap: What `app.module.ts` and `main.ts` Are Each Responsible For

## Where we start: you registered the logger, but Nest ignores it

You want your whole app to log through Pino instead of Nest's default console logger. So you do the obvious thing — register it in a module:

```ts
@Module({
  imports: [LoggerModule.forRoot(pinoHttpOptions)],
})
export class AppModule {}
```

You can confirm it worked: inject `PinoLogger` into a service and it's there, fully wired. And yet — Nest's own startup messages still print in the default format, and every existing `new Logger('SomeContext')` call across your services still goes to the old console logger. The Pino logger *exists*, but most of the app isn't using it.

The confusing part: you registered it correctly. Why isn't one registration enough?

The pains this raises:

- **A provider can exist without being "in charge."** Registering Pino in the module made it injectable — it didn't make Nest's core adopt it.
- **`new Logger(ctx)` call sites are untouched.** They don't go through DI at all, so registering a provider can't reach them.
- **Nest's own framework messages are untouched.** Those aren't a provider in your graph — they're the framework core's own logging.

Root problem: **there are two separate acts here — "make this thing exist in the container" and "tell the running app to use it" — and they happen in two different places.** Knowing which place does which is the whole point of this note.

## The two things a Nest app actually is

Forget logging for a second. Look at what `main.ts` does:

```ts
async function bootstrap() {
  const app = await NestFactory.create(AppModule); // 1. build the container
  app.useLogger(app.get(Logger));                  // 2. configure the built app
  await app.listen(process.env.PORT ?? 8080);      // 3. start accepting traffic
}
bootstrap();
```

`NestFactory.create(AppModule)` is the dividing line. It reads the entire module graph starting at `AppModule`, resolves every provider (building each one's dependencies first, recursively — the same graph resolution from the DI note), and hands back a single object: `app`.

That one line splits your app into two worlds:

- **Before it:** nothing exists yet. `AppModule` and everything it imports is just a *declaration* — a description of what should be built. No instance has been created.
- **After it:** the container is fully built. Everything from here on is **imperative method calls on the finished `app` object** — `app.useLogger(...)`, `app.useGlobalPipes(...)`, `app.enableCors(...)`, `app.listen(...)`.

So the two worlds are the **container** (what your modules declare) and the **bootstrap** (the code in `main.ts` that builds the container, then configures the assembled app).

> **Mental model:** a Module is a *declaration* — "these things exist and here's how they connect." `main.ts` is *imperative setup* that runs once, after the container exists, on the one `app` object that came out of it.

## Why the two worlds aren't interchangeable

| | Modules (`AppModule`, etc.) | `main.ts` (bootstrap) |
|---|---|---|
| What it is | A **declaration**: "these providers / controllers / middleware exist and can be injected" | **Imperative setup** run once, on the already-built `app` object |
| When it runs | During `NestFactory.create(...)`, while the graph is being resolved | After the graph exists, before / around `app.listen()` |
| Can it be injected elsewhere? | Yes — that's the entire point | No — there's nothing to inject into; it's the outermost layer |
| Analogy | The company org chart: who exists, who reports to whom | The building manager, after everyone's hired, flipping switches: "reception, route all calls to the new phone system" |

The last row is the crux. Anything inside the container can be injected. `main.ts` can't be injected into anything — it's the outermost layer, holding the finished app in a variable, with nothing above it to hand it to.

## Some settings can only live in `main.ts`

Most app behavior *can* be declared in a module — routes, services, middleware, guards, interceptors all have first-class module support. But a few settings are properties of the `app` instance itself, not of the dependency graph, and Nest deliberately only exposes them as bootstrap methods: `app.useLogger()`, `app.setGlobalPrefix()`, `app.listen()`.

There's no `@Module({ logger: ... })` option, and that's not an oversight. "Which logger does Nest's own core use for its internal messages" isn't a graph question — it's a "how does this app instance behave" question, so it belongs to the app object.

> **One line:** if a setting is about *what exists and how it connects*, it's a module job; if it's about *how the assembled app instance behaves*, it's a `main.ts` job.

## Back to the logger: now the two registrations make sense

Here's the fixed wiring:

```ts
// app.module.ts — a Module declaration
@Module({
  imports: [LoggerModule.forRoot(pinoHttpOptions)],
})
export class AppModule {}
```

```ts
// main.ts — imperative setup on the built app
const app = await NestFactory.create(AppModule, { bufferLogs: true });
app.useLogger(app.get(Logger));
```

These two lines look like they're both "setting up the logger," but map cleanly onto the two worlds above.

**Job 1 — the module makes Pino exist, and wires HTTP auto-logging.** `LoggerModule.forRoot(pinoHttpOptions)` behaves like any other `SomeModule.forRoot(options)` (think `TypeOrmModule.forRoot()`). It does two graph-shaped things: it registers `nestjs-pino`'s `Logger` and `PinoLogger` as providers (so you *could* now inject `PinoLogger` anywhere), and it registers `pino-http` as middleware on every route (which auto-logs each request/response). What it does *not* touch: Nest's own internal logger, or the ~30 existing `new Logger(ctx)` call sites — those are plain constructor calls that bypass DI, so no provider registration could ever reach them.

**Job 2 — `main.ts` points Nest's core at that instance.** `app.get(Logger)` reaches into the container built in Job 1 and pulls out the Pino-backed instance; `app.useLogger(...)` then tells Nest's core to use it for its own messages and every `new Logger(ctx)` call site. This is the bridge between the two worlds: **`app.get()` is how bootstrap code reaches into the finished container to grab something the modules built** — the one legitimate seam between declared graph and imperative setup.

**Why you can't collapse them:** drop the module registration and `app.get(Logger)` throws (nothing put that provider in the graph) and you lose the `pino-http` middleware; drop the `main.ts` call and the provider exists but Nest's core keeps using its default logger for everything that doesn't explicitly inject it. Each step does something the other structurally cannot — one declares, one switches — so both are required.

## A detail that proves the timeline: `bufferLogs`

`bufferLogs: true` exists precisely because of the ordering between the two worlds:

```ts
const app = await NestFactory.create(AppModule, { bufferLogs: true });
app.useLogger(app.get(Logger));
```

While the container is still being built, things are already logging — but `app.useLogger()` hasn't run yet, so those early logs would go to the default logger in the wrong format. `bufferLogs` holds them in memory until `useLogger` runs, then flushes them all through the logger you chose.

> **Mental model:** `bufferLogs` is the seam between the two worlds made visible — logs produced while the container is still building, held until bootstrap flips the switch.

## Two shapes of access to the same logger: `Logger` vs `PinoLogger`

Worth being explicit about, since it's easy to conflate with the two-registration split. `nestjs-pino` gives you two injectable classes answering different questions:

- **`Logger`** — the one handed to `app.useLogger()`. It implements Nest's generic `LoggerService` interface (`.log()`, `.error()`, etc.), so it can drop in as Nest's own logger and keep `new Logger(ctx)` call sites compiling unchanged.
- **`PinoLogger`** — meant for constructor injection inside a service. Because it's resolved through DI per request, it can automatically read the current request's child logger out of `AsyncLocalStorage` and attach the request ID — something a bare `new Logger(ctx)` can't, since it never goes through DI.

Both are backed by the same underlying Pino instance and config — two *shapes of access* (one global swap, one per-service injection), not two logging systems.

## A separate axis: "base" vs "HTTP" config

Different question from container-vs-bootstrap — this is about *config layering*, not *where things get registered* — but it uses the same logger, so it's worth pinning down. It's not two loggers; it's one shared base config and one HTTP-specific extension.

`pino-base-options.ts` answers only: **regardless of where a log call comes from, how should Pino format it?** — log level, GCP `severity`/`message` remapping, prod-vs-dev pretty-printing. Nothing about requests or middleware; it'd suit a CLI script that never touches HTTP.

`pino-http-options.ts` spreads in the base and adds only HTTP-cycle concerns: header redaction, `req`/`res` serializers, request ID generation, the Cloud Run trace header. This is the object passed into `LoggerModule.forRoot(...)`.

```
basePinoOptions()   ->   format, level, severity mapping, prod/dev branching
   |                        |
   |                        v
   |                 pino-http-options.ts  ->  LoggerModule.forRoot()  ->  pino-http middleware
   v
libs/logger.ts (standalone Pino, for code outside Nest's DI —
   bootstrap error handlers, rabbitmq.ts)
```

One set of formatting rules (base), two consumers of it: a bare Pino instance for non-DI code, and the HTTP-middleware config for DI code. So "which logger do I reach for" collapses to: *am I inside Nest's DI container right now or not.* A third consumer later (say a message-queue logger) should import `basePinoOptions` too, rather than redefining severity/prod logic a third time.

## The one-paragraph version, for when this comes up again

**A Module declares what exists in the DI container; `main.ts` runs after that container is built and can only configure the assembled `app` object.** `LoggerModule.forRoot()` makes a Pino-backed `Logger` provider exist and wires `pino-http` middleware onto every route; `app.useLogger()` can *only* run afterward and redirects Nest's own core logging — plus every pre-existing `new Logger(ctx)` — to use it. `app.get()` is the seam: bootstrap reaching into the finished container. Neither step can do the other's job, so both are required. Separately, `pino-base-options.ts` (format/level/severity, consumer-agnostic) and `pino-http-options.ts` (base plus request/response serializers, redaction, trace headers) aren't competing loggers — the HTTP one builds on the base, and the standalone Pino in `libs/logger.ts` is the base's other consumer.

---

## The bridge to what's next

This split explains more than logging. Any "global" setting follows the same fork: `app.useGlobalGuards(new X())` in bootstrap (hand-built, no DI) versus an `APP_GUARD` provider in a module (container-built, full DI) — the exact tension in the binding-scope note. Same two worlds, same trade-off: declare it in the container to get DI, or set it imperatively on the app when it's a property of the instance itself.
# Interceptors, RxJS & Validation (Lesson 3b)

> Long-form walkthrough: why interceptors need Observables, the minimum RxJS to read one, the operators mapped to real features, validation in depth, and wiring cross-cutting concerns across HTTP *and* RabbitMQ. Builds on `03a-pipeline-map.md`. Distilled version: `03-request-pipeline.md`.

---

## Why interceptors need a different shape than guards and pipes

Look at the stages from Lesson 3a. A guard *runs and returns a yes/no*. A pipe *takes an input and returns a cleaned input*. Both are "receive something, return something" — one-shot functions.

An interceptor is different in kind: it wraps the handler on **both sides**. It wants to do something *before* the handler runs, let the handler run, then do something *with the result after*. Timing is the clearest example — to measure how long a handler took, you must record a start time going in, and read the elapsed time coming out, with the handler's execution in between.

So an interceptor needs a way to express: "run my before-code, then hand off to the handler, then when the handler's result eventually arrives, run my after-code on it." The handler's result *eventually arrives* — it's asynchronous. That phrase — "do something when a value arrives later, and let me transform it on the way" — is exactly what an **Observable** is built to represent. That's why RxJS shows up here. It isn't decoration; it's the natural tool for "wrap an async result."

## The minimum RxJS to read an interceptor

You don't need RxJS broadly — you need four ideas.

- **An Observable is a stream of values that arrive over time.** For interceptors the stream is simple: the handler produces its return value (usually a single value), and that value flows through the stream. Think "a promise you can attach transformations to."
- **`next.handle()` returns that stream.** Inside an interceptor, calling it means "let the rest of the pipeline (any inner interceptors, then the handler) run, and give me back an Observable of its result." Nothing after the handler happens until this stream emits.
- **`.pipe(...)` attaches transformations** to the stream — a sequence of *operators*, each taking the stream and returning a new one. This is where your "after" logic lives.
- **Operators are the verbs.** Four cover almost everything: `tap` (side effect, don't change the value), `map` (reshape the value), `catchError` (react to an error in the stream), `timeout` (fail the stream if it takes too long).

The canonical interceptor — timing + logging — with every piece labeled:

```ts
import { CallHandler, ExecutionContext, Injectable, NestInterceptor } from '@nestjs/common';
import { Observable, tap } from 'rxjs';

@Injectable()
export class LoggingInterceptor implements NestInterceptor {
  intercept(ctx: ExecutionContext, next: CallHandler): Observable<any> {
    const start = Date.now();                    // ── BEFORE: runs on the way in
    const handler = ctx.getHandler().name;

    return next.handle().pipe(                    // ── run the handler, get its result-stream
      tap(() => {                                 // ── AFTER: runs when the result arrives
        console.log(`${handler} took ${Date.now() - start}ms`);
      }),
    );
  }
}
```

Read the flow: everything above `return` is the before-phase. `next.handle()` triggers the handler. `.pipe(tap(...))` says "when the result comes back, run this side effect." The value passes through `tap` unchanged — `tap` is for effects (logging, metrics), never for altering the response.

## The operators, each tied to a real cross-cutting job

**`tap` → logging & metrics.** Side effects that observe without changing: the timing interceptor above, emitting a metric, recording the outcome.

**`map` → response shaping.** Wrap every handler's result in a standard envelope, so all endpoints return a consistent structure:

```ts
return next.handle().pipe(
  map((data) => ({ success: true, data })),   // { success: true, data: <handler's return> }
);
```

Written once as a global interceptor, every endpoint's response is enveloped — no handler has to think about it.

**`timeout` → bounding the handler.** Fail the request if the handler takes too long:

```ts
import { timeout, catchError, throwError, TimeoutError } from 'rxjs';
import { RequestTimeoutException } from '@nestjs/common';

return next.handle().pipe(
  timeout(5000),                                       // fail the stream after 5s
  catchError((err) =>
    err instanceof TimeoutError
      ? throwError(() => new RequestTimeoutException()) // becomes a clean 408
      : throwError(() => err),
  ),
);
```

The senior nuance — the same lesson as "`Promise.race` doesn't stop the work": this `timeout` bounds *how long the pipeline waits for the handler*, but it does **not** cancel the handler's in-flight work — the DB query or the downstream call keeps running unless *it* was given an `AbortSignal`. The two mechanisms are complementary: the interceptor `timeout` protects the *caller* (a bounded response); `AbortSignal.timeout` on the outbound call protects your *downstream resources*. A robust path uses both.

**`catchError` → error mapping in the stream.** You *can* map errors here, but exception filters already own error-to-response. The clean division: **filters are the global error-to-response policy** (default for almost everything); an interceptor's `catchError` is for error handling *specific to that wrapping concern* — e.g. the timeout mapping above, or a retry. Don't duplicate the filter's job in every interceptor.

> **Mental model:** an interceptor is `before → next.handle() → .pipe(operators)`. The before-code is plain synchronous setup; the operators are your after-logic on the result stream. `tap` observes, `map` reshapes, `timeout` bounds, `catchError` reacts.

**Multiple interceptors nest like an onion.** Register A then B and the order is: A-before → B-before → handler → B-after → A-after. The first-registered wraps outermost. This matters when order is significant (a context-setup interceptor must wrap a logging one so the logger can see the context).

## Pipes and validation, in depth

Lesson 3a placed pipes ("clean the handler's inputs"); here's the real machinery, because this is where untrusted input meets your app. The pattern is **DTO + decorators + `ValidationPipe`**.

A DTO ("data transfer object") is a class describing the expected shape of input, annotated with `class-validator` decorators that declare the rules:

```ts
import { IsEmail, IsString, IsOptional, Length } from 'class-validator';

export class CompleteOrderDto {
  @IsString() @Length(1, 64)
  orderId: string;

  @IsEmail()
  email: string;

  @IsOptional() @IsString()
  referralCode?: string;
}
```

Then one global pipe enforces every DTO across the whole app:

```ts
app.useGlobalPipes(new ValidationPipe({
  whitelist: true,              // strip properties not declared in the DTO
  forbidNonWhitelisted: true,   // …or reject outright if extras are present
  transform: true,              // turn the plain body into a real DTO instance,
                                //   and coerce types (e.g. "42" → 42) where declared
}));
```

Three settings, three real protections:

- **`whitelist`** removes any field the DTO didn't declare — so a client can't sneak `isAdmin: true` into a body and have it flow through to your logic. Silent stripping.
- **`forbidNonWhitelisted`** upgrades that from "strip silently" to "reject loudly" (400) when unexpected fields appear — usually what you want, so bad callers get told.
- **`transform`** makes the handler actually receive a typed `CompleteOrderDto` instance (not a plain object), and performs the string→number/boolean coercion that HTTP (where everything arrives as a string) otherwise forces you to do by hand.

Why this belongs at the *pipe* stage ties back to the ordering logic: validation is fail-fast on input — reject a malformed body *before* the handler runs any business logic or touches the database. And by the time the handler executes, its argument is guaranteed valid and typed, so the handler contains zero validation code. Untrusted input becomes trusted, typed input at exactly one boundary.

(You can also write a **custom pipe** for one-off transforms — e.g. a `ParseObjectIdPipe` that validates a route param is a well-formed ID and throws a clean 400 — but DTO + `ValidationPipe` handles the overwhelming majority.)

## The synthesis: cross-cutting features across both transports

Now assemble the pieces, and resolve the caveat from Lesson 3a: **middleware is HTTP-only, so it can't set up context for RabbitMQ message handlers.** The fix is to move that setup into an **interceptor**, which runs for *both* transports via `ExecutionContext`.

A context interceptor that establishes the ALS store for HTTP requests *and* RabbitMQ messages — one component, both surfaces:

```ts
@Injectable()
export class ContextInterceptor implements NestInterceptor {
  intercept(ctx: ExecutionContext, next: CallHandler): Observable<any> {
    // pull a correlation id from whichever transport this is
    let requestId: string;
    if (ctx.getType() === 'http') {
      requestId = ctx.switchToHttp().getRequest().headers['x-request-id'] ?? crypto.randomUUID();
    } else {
      // RabbitMQ message: read it from the message headers/properties
      const rmq = ctx.switchToRpc().getContext();
      requestId = rmq.getMessage()?.properties?.headers?.['x-request-id'] ?? crypto.randomUUID();
    }

    // establish the ALS store for the whole handler execution
    return new Observable((subscriber) => {
      als.run({ requestId }, () => {
        next.handle().subscribe(subscriber);   // run the handler inside the store
      });
    });
  }
}
```

Because it's written against `ExecutionContext`, the same interceptor gives every log line a correlation ID whether the work started as an HTTP call or a RabbitMQ message. This is the machinery the observability topic builds on — the correlation ID set here is what a logging interceptor (and every downstream service call) attaches and propagates.

The last piece is **how you bind these globally *and* keep them injectable.** A global interceptor registered with `app.useGlobalInterceptors(new LoggingInterceptor())` can't inject dependencies (you built it with `new`). To get a global component that participates in DI — so it can inject a logger, config, etc. — register it as a provider with a special token:

```ts
@Module({
  providers: [
    { provide: APP_INTERCEPTOR, useClass: ContextInterceptor },  // global + injectable
    { provide: APP_INTERCEPTOR, useClass: LoggingInterceptor },
    { provide: APP_GUARD,       useClass: RolesGuard },
    { provide: APP_PIPE,        useClass: ValidationPipe },
    { provide: APP_FILTER,      useClass: AllExceptionsFilter },
  ],
})
export class AppModule {}
```

These four tokens — `APP_INTERCEPTOR`, `APP_GUARD`, `APP_PIPE`, `APP_FILTER` — are the DI-aware way to apply a component to every request while still letting the container inject *its* dependencies. This is where DI and the pipeline meet.

## Decision frame

| Concern | Construct | Key detail |
|---------|-----------|------------|
| Yes/no access gate | Guard | boolean/throw; reads route metadata |
| Validate/transform input | Pipe (`ValidationPipe` + DTO) | `whitelist` + `forbidNonWhitelisted` + `transform` |
| Wrap the call (timing, logging, envelope, timeout, context) | Interceptor | `before → next.handle() → .pipe()`; nests onion-style |
| Error → response (global policy) | Exception filter | default owner of errors |
| Error handling specific to a wrapper | Interceptor `catchError` | only for that concern (e.g. timeout mapping) |
| Per-request context for **both** HTTP & RabbitMQ | Interceptor (not middleware) | middleware is HTTP-only; use `ExecutionContext` |
| Make a global component injectable | `APP_*` provider token | vs `app.useGlobal*()` which can't inject |

> **Rules of thumb:**
> 1. Yes/no → guard; wrap/transform → interceptor.
> 2. Validate at the pipe boundary so handlers get typed, trusted input and stay pure.
> 3. Errors are the filter's job by default; use interceptor `catchError` only when it's part of that interceptor's specific purpose.
> 4. For anything that must work across HTTP *and* RabbitMQ, use interceptors over middleware.
> 5. Bind global cross-cutting components via `APP_*` tokens to keep them DI-injectable.

---

## The build, in order

**why interceptors need Observables** (wrap both sides of an async result) → **minimum RxJS** (stream, `handle()`, `.pipe()`, four operators) → **operators as features** (log, envelope, timeout, error-map) → **validation in depth** (DTO + `ValidationPipe` at the fail-fast boundary) → **synthesis** (context for both transports via interceptor, global-but-injectable via `APP_*`). Reaches back into async (timeouts), DI (providers + ALS), and the error note (filters).
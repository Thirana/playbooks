# NestJS Request Pipeline & Cross-Cutting Concerns (Reference Note)

> Which stage owns which concern, and how to wire them. Built bottom-up — each section assumes the one above. Long-form lessons: `03a-pipeline-map.md`, `03b-interceptors-validation.md`.
>
> **The build:** cross-cutting concerns → the ordered stages → why that order → `ExecutionContext` → interceptors + RxJS → validation → wiring (both transports, `APP_*`).

---

## 1. Core mental models

- **Cross-cutting concern** = behavior that wraps *many* handlers (auth, validation, logging, error→response). Pull it out of the handler into a stage; the handler stays pure business logic.
- **The pipeline is nested wrappers** around your handler. Middleware outermost → guards → interceptors(pre) → pipes → handler → interceptors(post) → filters.
- **Info accumulates down the pipeline; rejections get cheaper the earlier they are.** That's *why* the order is what it is.
- **`ExecutionContext` = "the current invocation, transport-agnostic."** Write components against it → they work for HTTP *and* RabbitMQ.
- **An interceptor is `before → next.handle() → .pipe(operators)`** — the only stage that wraps *both* sides, which is why it needs an Observable.
- **Middleware is HTTP-only.** Anything that must also run for RabbitMQ = interceptor.

---

## 2. The stages

```
Request
  → Middleware          raw HTTP setup            (req, res, next) — HTTP ONLY
  → Guards              may this proceed?         boolean / throw
  → Interceptors (pre)  wrap: timing, context
  → Pipes               validate/transform inputs
  → ROUTE HANDLER       pure business logic
  → Interceptors (post) observe/reshape result
  → Exception filters   error → response          (only if something threw)
Response
```

| Stage | One job | Sees |
|-------|---------|------|
| Middleware | transport-level setup | raw `req`/`res`, no route awareness |
| Guard | yes/no access gate | route metadata via `getHandler()` |
| Interceptor | wrap the call (both sides) | context + result stream |
| Pipe | validate/transform the handler's args | the argument |
| Filter | turn a throw into a response | the exception |

> **Placement rule:** put a concern at the earliest stage that has enough information to handle it.

```
unauthorized?   → GUARD    (before any validation or DB work)
malformed body? → PIPE     (before the handler runs)
business rule?  → HANDLER  (the expensive part, reached last)
```

---

## 3. `ExecutionContext`

```ts
ctx.getHandler(); ctx.getClass();           // what's running → read metadata/decorators
ctx.getType();                              // 'http' | 'rpc' | 'ws'
ctx.switchToHttp().getRequest();            // HTTP
ctx.switchToRpc().getData() / .getContext();// RabbitMQ / RPC
ctx.switchToWs().getClient();               // WebSocket
```

```ts
@Injectable()
export class RolesGuard implements CanActivate {
  canActivate(ctx: ExecutionContext): boolean {
    const required = this.reflector.get('roles', ctx.getHandler());
    const user = ctx.switchToHttp().getRequest().user;
    return required ? required.includes(user?.role) : true;
  }
}
```

---

## 4. Interceptors: the shape

```ts
@Injectable()
export class LoggingInterceptor implements NestInterceptor {
  intercept(ctx: ExecutionContext, next: CallHandler): Observable<any> {
    const start = Date.now();                       // BEFORE
    return next.handle().pipe(                      // run handler → result stream
      tap(() => console.log(`${ctx.getHandler().name} took ${Date.now() - start}ms`)), // AFTER
    );
  }
}
```

**Onion order:** register A then B → A-before → B-before → handler → B-after → A-after. First-registered wraps outermost (context interceptor must wrap the logger).

### The four operators = the four jobs

| Operator | Job | Snippet |
|----------|-----|---------|
| `tap` | logging/metrics (value unchanged) | `tap(() => log(...))` |
| `map` | response envelope | `map((data) => ({ success: true, data }))` |
| `timeout` | bound the handler | `timeout(5000)` |
| `catchError` | react to stream errors | see below |

```ts
return next.handle().pipe(
  timeout(5000),
  catchError((err) =>
    err instanceof TimeoutError
      ? throwError(() => new RequestTimeoutException())   // clean 408
      : throwError(() => err),
  ),
);
```

> **Interceptor `timeout` ≠ cancellation.** It bounds how long *the pipeline waits*; the handler's in-flight DB/HTTP work keeps running unless it got an `AbortSignal`. Use both: `timeout` protects the caller, `AbortSignal.timeout` protects downstream resources.

> **Errors: filters own the global policy.** Use interceptor `catchError` only when the error handling *is* that interceptor's purpose (timeout mapping, retry) — don't duplicate the filter in every interceptor.

---

## 5. Validation (DTO + ValidationPipe)

```ts
export class CompleteOrderDto {
  @IsString() @Length(1, 64) orderId: string;
  @IsEmail() email: string;
  @IsOptional() @IsString() referralCode?: string;
}
```

```ts
app.useGlobalPipes(new ValidationPipe({
  whitelist: true,            // strip undeclared props (blocks isAdmin:true smuggling)
  forbidNonWhitelisted: true, // …or 400 loudly instead of stripping silently
  transform: true,            // real DTO instance + type coercion ("42" → 42)
}));
```

Handler then receives guaranteed-valid, typed input and contains **zero** validation code.

---

## 6. Context across BOTH transports (the MO case)

Middleware can't do this (HTTP-only) → use an interceptor:

```ts
@Injectable()
export class ContextInterceptor implements NestInterceptor {
  intercept(ctx: ExecutionContext, next: CallHandler): Observable<any> {
    const requestId =
      ctx.getType() === 'http'
        ? ctx.switchToHttp().getRequest().headers['x-request-id'] ?? crypto.randomUUID()
        : ctx.switchToRpc().getContext().getMessage()?.properties?.headers?.['x-request-id']
          ?? crypto.randomUUID();

    return new Observable((subscriber) => {
      als.run({ requestId }, () => { next.handle().subscribe(subscriber); });
    });
  }
}
```

---

## 7. Binding globally *and* keeping DI

```ts
// ❌ global but NOT injectable — you built it with `new`
app.useGlobalInterceptors(new LoggingInterceptor());

// ✅ global AND injectable
@Module({
  providers: [
    { provide: APP_INTERCEPTOR, useClass: ContextInterceptor },  // registered first = outermost
    { provide: APP_INTERCEPTOR, useClass: LoggingInterceptor },
    { provide: APP_GUARD,       useClass: RolesGuard },
    { provide: APP_PIPE,        useClass: ValidationPipe },
    { provide: APP_FILTER,      useClass: AllExceptionsFilter },
  ],
})
export class AppModule {}
```

---

## 8. Decision frame

| I want to… | Use |
|------------|-----|
| Yes/no access gate | **Guard** |
| Validate/transform input | **Pipe** (`ValidationPipe` + DTO) |
| Wrap the call — timing, logging, envelope, timeout, context | **Interceptor** |
| Error → response (global policy) | **Exception filter** |
| Error handling specific to one wrapper | Interceptor `catchError` |
| Per-request context for HTTP **and** RabbitMQ | **Interceptor** (middleware is HTTP-only) |
| Global component that injects deps | `APP_*` provider token |

> **Rules:** yes/no → guard, wrap/transform → interceptor · validate at the pipe boundary so handlers stay pure · errors are the filter's job by default · cross-transport → interceptor, not middleware · bind globals via `APP_*` to keep DI.

---

## Connects to

- **error-handling note** — filters are the last pipeline stage; the global error→response policy.
- **async note** — interceptor `timeout` vs `AbortSignal` cancellation (bound the wait ≠ stop the work).
- **Topic 2 (DI & scopes)** — `APP_*` tokens make globals injectable; ALS store set up here, read by singletons.
- **Topic 4 (observability)** — `ContextInterceptor`'s correlation ID is what every log line and downstream call carries.
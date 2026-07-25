# NestJS DI, Modules & Scopes (Reference Note)

> How the app is wired and how instance lifetimes work. Built bottom-up — each section assumes the one above. Long-form lessons: `01-di-wiring.md`, `02-nestjs-di-scopes.md`, `03-container-vs-bootstrap.md`.
>
> **The build:** the problem DI solves → IoC → container → providers & tokens → modules (visibility) → dynamic modules → container vs bootstrap (`main.ts`) → scopes → the singleton+interleaving leak → REQUEST bubbling → ALS.

---

## 1. Core mental models

- **A class should *use* its dependencies, never *assemble* them.** IoC moves assembly out of the class into a central authority.
- **The container resolves a graph:** you declare edges (constructor params), it builds everything in order and hands you a finished object — once, at boot, for singletons.
- **A provider = *token → recipe*.** Token = lookup key; recipe = how to build it.
- **Modules are the encapsulation boundary:** `providers` = what I own, `exports` = what I share, `imports` = whose sharing I consume.
- **Default provider = one shared singleton for the app's life.** Great for stateless; unsafe for per-request state (see §8).
- **A Module *declares* what exists; `main.ts` *configures* the built app.** `NestFactory.create()` is the dividing line — before it, only declarations; after it, imperative calls on the finished `app`.
- **`await` interleaves requests** → a singleton field can hold the wrong request's data. Isolation needs scopes or ALS.

---

## 2. The pain DI removes

```ts
// ❌ class builds its own deps → tight coupling, untestable, duplicated wiring
class OrdersService {
  private rewardClient = new RewardHttpClient('https://reward.internal', 2000);
}

// ✅ declare deps in the constructor; the container supplies them
@Injectable()
export class OrdersService {
  constructor(
    private readonly rewardClient: RewardClient, // by token (type)
    private readonly repo: OrderRepository,
  ) {}
}
```

Payoff: a test swaps `{ provide: RewardClient, useClass: FakeRewardClient }` and the service is unchanged.

---

## 3. Providers & tokens

```ts
@Module({
  providers: [
    OrdersService,                                                   // class provider (token = class)
    { provide: 'REWARD_CONFIG', useValue: { url, timeoutMs: 2000 } },// useValue — config / test fakes
    { provide: RewardClient, useClass: HttpRewardClient },           // useClass — swappable impl
    {                                                               // useFactory — computed, with deps
      provide: 'RABBIT_CONNECTION',
      useFactory: (c: ConfigService) => connectToRabbit(c.get('RABBIT_URL')),
      inject: [ConfigService],
    },
  ],
})
export class OrdersModule {}
```

| Recipe | For |
|--------|-----|
| class provider | the common case — construct this class |
| `useValue` | config objects, constants, test doubles |
| `useClass` | swap which implementation a token resolves to |
| `useFactory` (+ `inject`) | computed/async deps, non-class resources (connections) |
| `useExisting` | alias one token to another |

> **Why string/symbol tokens exist:** interfaces are erased at runtime, and non-class things (config, a live connection) have no class to key on. Inject those explicitly:

```ts
constructor(@Inject('REWARD_CONFIG') private cfg: RewardConfig) {}
```

---

## 4. Modules: visibility

```ts
@Module({ providers: [NotificationService], exports: [NotificationService] })
export class NotificationModule {}

@Module({ imports: [NotificationModule], providers: [OrdersService] })
export class OrdersModule {}   // OrdersService can now inject NotificationService
```

- Provider is **private to its module** unless `exports`-ed.
- A module uses another's provider only by `imports`-ing it.
- Controllers go in `controllers`, not `providers`; they're consumers, not injectables.
- `@Global()` = exported everywhere without import. Usually a mistake (hides real deps); reserve for config/logger.

---

## 5. Dynamic modules (configure at import time)

```ts
@Module({})
export class RabbitModule {
  static forRoot(options: { url: string }): DynamicModule {
    return {
      module: RabbitModule,
      providers: [
        { provide: 'RABBIT_OPTIONS', useValue: options },
        { provide: 'RABBIT_CONNECTION',
          useFactory: (o) => connectToRabbit(o.url), inject: ['RABBIT_OPTIONS'] },
      ],
      exports: ['RABBIT_CONNECTION'],
    };
  }
}

@Module({ imports: [RabbitModule.forRoot({ url: 'amqp://...' })] })
export class AppModule {}
```

```ts
// forRootAsync — options come from another provider (config)
RabbitModule.forRootAsync({
  useFactory: (c: ConfigService) => ({ url: c.get('RABBIT_URL') }),
  inject: [ConfigService],
});
```

> `forRoot`/`forRootAsync` = "let the importer configure me." The async form is how you build connections/clients from validated config, not hardcoded strings (Topic 5).

---

## 6. Container vs bootstrap (modules declare · `main.ts` configures)

`NestFactory.create(AppModule)` is the dividing line. **Before it:** modules are just declarations — nothing is built. **After it:** everything is imperative method calls on the one finished `app` object.

```ts
async function bootstrap() {
  const app = await NestFactory.create(AppModule, { bufferLogs: true }); // 1. build the container
  app.useLogger(app.get(Logger));                                        // 2. configure the built app
  app.setGlobalPrefix('api');
  await app.listen(process.env.PORT ?? 8080);                            // 3. accept traffic
}
```

| | Modules (`AppModule`, …) | `main.ts` (bootstrap) |
|---|---|---|
| What it is | **Declaration** — providers/controllers exist & connect | **Imperative setup** on the already-built `app` |
| When | during `NestFactory.create()`, as the graph resolves | after the graph exists, around `app.listen()` |
| Injectable? | yes — the whole point | no — outermost layer, nothing to inject it into |

- **Rule of thumb:** *what exists / how it connects* → module job. *how the assembled app instance behaves* → `main.ts` job (`useLogger`, `setGlobalPrefix`, `listen` — no `@Module` option for these).
- **`app.get(Token)` is the seam:** bootstrap reaching into the finished container to grab something the modules built.
- **Two registrations, two jobs (logger example):** `LoggerModule.forRoot(opts)` makes the Pino-backed `Logger` provider *exist* and wires `pino-http` middleware; `app.useLogger(app.get(Logger))` then redirects Nest's *core* logging and every `new Logger(ctx)` call site to it. Neither can do the other's job — drop the module and `app.get()` throws; drop the `main.ts` call and core keeps the default logger.
- **`bufferLogs: true`** holds logs produced while the container is still building until `useLogger` flips the switch, then flushes them through the chosen logger.
- **Same fork for any global:** `APP_GUARD` provider in a module (container-built, full DI) vs `app.useGlobalGuards(new X())` in bootstrap (hand-built, no DI).

---

## 7. Scopes: the three lifetimes

```ts
@Injectable()                            // DEFAULT  — singleton (built once)
@Injectable({ scope: Scope.REQUEST })    // one instance per request
@Injectable({ scope: Scope.TRANSIENT })  // one instance per injecting consumer
```

---

## 8. The leak that forces scopes

```ts
// ❌ singleton field + request interleaving = cross-request data leak
@Injectable()
class RequestContext { private userId: string; setUser(id){this.userId=id} getUser(){return this.userId} }
```

```
A.setUser('alice') → await (A parks) → B.setUser('bob') → A resumes getUser() = 'bob'  ❌
```

> **Never store per-request state in a singleton field.** Keep singletons stateless.

---

## 9. REQUEST scope: what it buys, what it costs

```ts
@Injectable({ scope: Scope.REQUEST })
export class CurrentUser {
  constructor(@Inject(REQUEST) private req: Request) {}   // CONTEXT instead of REQUEST for RabbitMQ msgs
}
```

> **REQUEST scope is contagious.** Anything that injects a request-scoped provider *also* becomes request-scoped — it bubbles up the whole chain:

```
CurrentUser (REQUEST) → OrdersService (now REQUEST) → OrdersController (now REQUEST)
```

**Cost:** every provider on that chain is re-instantiated **per request** (latency + GC pressure on hot paths), vs a singleton built once. One request-scoped leaf can turn a whole controller tree request-scoped. (Multi-tenant escape hatch: *durable providers*.)

---

## 10. AsyncLocalStorage — per-request context without the cost

The usual need (a correlation ID readable everywhere) is better solved with ALS: per-request data while **every service stays a singleton**.

```ts
export const als = new AsyncLocalStorage<{ requestId: string; userId?: string }>();

// establish the store at the request edge
export function contextMiddleware(req, res, next) {
  als.run({ requestId: req.headers['x-request-id'] ?? crypto.randomUUID() }, () => next());
}

// singleton — no scope change — still reads the right request's data
@Injectable()
export class AuditLogger {
  log(msg: string) {
    const s = als.getStore();
    console.log(JSON.stringify({ msg, requestId: s?.requestId }));
  }
}
```

> **ALS = thread-local for async flows.** Safe under interleaving because Node tracks each continuation's async context — A resumes into A's store, never B's. This is the correlation-ID machinery for Topic 4. (`nestjs-cls` wraps it with nicer ergonomics.)

---

## 11. Decision frame

| Need | Use | Why |
|------|-----|-----|
| Stateless service (client, repo, most things) | **DEFAULT** singleton | cheapest, built once |
| Ambient per-request context (correlation ID, user, tenant) read by many | **AsyncLocalStorage** | per-request data, all singletons, no bubbling |
| Provider that genuinely needs the injected request/message object | **REQUEST** scope | the one legit case; accept the cost |
| Each consumer needs its own private instance | **TRANSIENT** | isolation between injectors |

> **Rules:** default to singleton & stateless · never keep per-request state in a singleton field · prefer ALS over REQUEST for ambient context · use REQUEST only when you need the request object, and know it bubbles.

---

## Connects to

- **async note** — request interleaving (`await` = yield point) is *why* the singleton leak happens and why ALS is safe.
- **Topic 3 (request pipeline)** — guards/interceptors/pipes run per-request; where `contextMiddleware` and ALS setup live. The container-vs-bootstrap fork (§6) is exactly the `APP_GUARD` provider vs `app.useGlobalGuards()` tension.
- **Topic 4 (observability)** — ALS carries the correlation ID into every log line and across service calls.
- **Topic 5 (config)** — `forRootAsync` + `useFactory` build clients/connections from validated config.
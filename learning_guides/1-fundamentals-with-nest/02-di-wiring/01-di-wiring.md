# NestJS DI — Wiring the App (Lesson 2a)

> Long-form walkthrough: how the whole app gets assembled — the problem DI solves, the container, providers & tokens, modules as boundaries, and dynamic modules for runtime config. Built bottom-up; the distilled version is `02-nestjs-di-scopes.md`.

---

## Where we start: objects need other objects

Every non-trivial class depends on other classes to do its job. An `OrdersService` doesn't work alone — it needs a database repository, an HTTP client to reach the reward service, maybe a logger. The question that *all* of dependency injection answers is simply: **where do those dependencies come from?**

The naive answer is "the class makes its own":

```ts
// ❌ Each class constructs what it needs.
class OrdersService {
  private rewardClient = new RewardHttpClient('https://reward.internal', 2000);
  private repo = new OrderRepository(new DbConnection(process.env.DB_URL));
  private logger = new Logger();

  async complete(order: Order) { /* uses the three above */ }
}
```

This looks fine until you feel the four pains it causes:

- **Tight coupling.** `OrdersService` is welded to the *concrete* `RewardHttpClient` and its exact constructor arguments. It knows how to *build* a reward client, which has nothing to do with its real job.
- **Untestable.** In a unit test you can't swap the real client for a fake — it's hard-wired with `new`. Every test would make real HTTP calls.
- **Duplicated wiring.** If ten services need a reward client, the URL and timeout are pasted in ten places.
- **No single source of truth.** No one place owns "how is a reward client built."

The root problem: the class is doing *two* jobs — its real work, and the assembly of its dependencies. Those should be separated.

## Inversion of control: declare what you need, don't build it

Flip the direction of responsibility. Instead of a class *reaching out* to construct dependencies, it *declares* them and waits for someone to hand them over. This flip is **Inversion of Control** — the class gives up control over *where its dependencies come from*.

In NestJS that declaration is just the constructor:

```ts
@Injectable()
export class OrdersService {
  constructor(
    private readonly rewardClient: RewardHttpClient,
    private readonly repo: OrderRepository,
    private readonly logger: Logger,
  ) {}

  async complete(order: Order) { /* uses this.rewardClient, this.repo, this.logger */ }
}
```

`OrdersService` no longer knows *how* to build anything. It only says "give me these three things." `@Injectable()` marks it as participating in that system.

> **Mental model:** a class should *use* its dependencies, never *assemble* them. IoC moves assembly out of the class and into a central authority — the DI container.

## The container: a registry, a factory, and a cache

The DI container is less magical than it looks — three plain ideas combined:

- A **registry**: a map from a *token* (an identifier — for now, "the class") to a *recipe* for building it.
- A **factory**: when something asks for a token, it reads the recipe, recursively builds that thing's *own* dependencies first, then constructs it.
- A **cache**: once built, it keeps the instance and reuses it (why most things are singletons).

At boot, NestJS reads `OrdersService`'s constructor, sees it needs `RewardHttpClient`, `OrderRepository`, `Logger`, builds those (and *their* dependencies, all the way down), then constructs `OrdersService`. This recursive walk is **resolving the dependency graph**; it happens once at startup for singletons.

How does it know the constructor needs a `RewardHttpClient`? TypeScript, with decorator metadata enabled, emits the constructor's parameter *types* at compile time. NestJS reads that metadata and uses each type as the lookup key — so plain constructor typing is enough.

> **One line:** the container resolves a graph — you declare edges (constructor params), it figures out build order and hands you a fully-assembled object.

## Providers and tokens: what can be injected, and how it's identified

A **provider** is anything the container knows how to supply, expressed as **recipe + token**. The token is the key; the recipe is how to build it. The default recipe is "construct this class," the default token is the class reference. But you can register custom recipes:

```ts
@Module({
  providers: [
    // 1. Standard: token = the class, recipe = "new it up (with its deps)"
    OrdersService,

    // 2. useValue — token maps to an already-made value (config, or fakes in tests)
    { provide: 'REWARD_CONFIG', useValue: { url: 'https://reward.internal', timeoutMs: 2000 } },

    // 3. useClass — token maps to a class, but you can swap which one
    { provide: RewardClient, useClass: HttpRewardClient },

    // 4. useFactory — token built by a function that can itself have dependencies
    {
      provide: 'RABBIT_CONNECTION',
      useFactory: (config: ConfigService) => connectToRabbit(config.get('RABBIT_URL')),
      inject: [ConfigService], // the factory's own deps, resolved and passed in
    },
  ],
})
export class OrdersModule {}
```

Why **tokens** aren't always classes — two things plain class-typing can't express:

- **Interfaces don't exist at runtime.** TS interfaces are erased at compile time, so you can't use an interface as a lookup key by type. Give it a string/symbol token and inject by that token.
- **Non-class things need a home too.** A config object, a live RabbitMQ connection, a feature flag — none is a class you can `new`. A token + `useValue`/`useFactory` lets the container manage them.

When the token is a string/symbol, type metadata can't identify it — point at it explicitly with `@Inject`:

```ts
@Injectable()
export class RewardHttpClient {
  constructor(
    @Inject('REWARD_CONFIG') private readonly cfg: { url: string; timeoutMs: number },
    @Inject('RABBIT_CONNECTION') private readonly rabbit: RabbitConnection,
  ) {}
}
```

> **Mental model:** a provider = *token → recipe*. Class providers are the common case; custom providers (`useValue` / `useClass` / `useFactory` / `useExisting`) exist for config, interfaces, swappable implementations, and non-class resources.

The senior payoff of this indirection is **testability and swappability**: because `OrdersService` asks for the `RewardClient` *token*, a test registers `{ provide: RewardClient, useClass: FakeRewardClient }` and the real service is none the wiser. The coupling from the start is gone.

## Modules: the visibility boundary for the graph

If every provider could see every other provider, a large app becomes one tangled graph. **Modules** carve that graph into encapsulated pieces with **controlled visibility**. Two rules cover almost everything:

- A provider is **private to its own module** by default.
- To share a provider, the owning module must **`export`** it; to *use* someone else's export, a module must **`import`** that module.

```ts
// notification.module.ts — owns and shares NotificationService
@Module({
  providers: [NotificationService],
  exports: [NotificationService],
})
export class NotificationModule {}

// orders.module.ts — consumes it by importing the module
@Module({
  imports: [NotificationModule],
  controllers: [OrdersController],
  providers: [OrdersService],
})
export class OrdersModule {}
```

`OrdersService` can inject `NotificationService` *only* because `OrdersModule` imported `NotificationModule` and it exported the service. An unexported internal `RetryPolicy` would stay invisible to outsiders. That boundary is the point.

> **Mental model:** modules are the *encapsulation system* for the DI graph. `providers` = what I own, `exports` = what I share, `imports` = whose sharing I consume. Controllers are consumers Nest instantiates — they live in `controllers`, not `providers`, and can't be injected into other things.

Escape hatch: `@Global()` makes a module's exports available everywhere without importing. Usually a mistake — it hides real dependencies and reintroduces the "everything sees everything" soup. Reserve it for truly cross-cutting singletons (config, logger), and even then prefer explicit imports where practical.

## Dynamic modules: configuring a module at import time

With a static `@Module()`, the provider list is baked into the class definition at compile time. The decorator runs once, the providers are fixed, and every importer gets the *exact same* module. There's no way to say "give me `RabbitModule`, but configured *this* way" when you import it — the import is just `imports: [RabbitModule]`, with nowhere to pass options. If two parts of your app need the same module wired differently, you'd end up copy-pasting the whole module just to change one `useValue`.

That's the itch. A module often can't be fully defined until runtime because it needs config the code doesn't know yet (a broker URL, DB credentials, which queue to publish to). You want the *importer* to supply that config at the point of import.

A **dynamic module** scratches the itch: instead of exporting a fixed `@Module`, it exposes a static method that *returns* a module definition built from passed-in options. The `@Module({})` decorator on the class is left empty — the real providers are assembled by the method, per call.

```ts
@Module({})
export class RabbitModule {
  static forRoot(options: { url: string }): DynamicModule {
    return {
      module: RabbitModule,
      providers: [
        { provide: 'RABBIT_OPTIONS', useValue: options },
        {
          provide: 'RABBIT_CONNECTION',
          useFactory: (opts: { url: string }) => connectToRabbit(opts.url),
          inject: ['RABBIT_OPTIONS'],
        },
      ],
      exports: ['RABBIT_CONNECTION'],
    };
  }
}

@Module({ imports: [RabbitModule.forRoot({ url: 'amqp://...' })] })
export class AppModule {}
```

The payoff is that the *same* `RabbitModule` class can now be imported into different feature modules, each configured its own way — no copy-paste, no duplicated class.

**Example 1 — two feature modules, two different brokers.** `OrdersModule` talks to the orders broker; `PaymentsModule` talks to a separate, hardened payments broker. Both call `forRoot` with different options and get their own `RABBIT_CONNECTION`:

```ts
// orders.module.ts
@Module({
  imports: [RabbitModule.forRoot({ url: 'amqp://orders-broker:5672' })],
  providers: [OrdersService],
})
export class OrdersModule {}

// payments.module.ts
@Module({
  imports: [RabbitModule.forRoot({ url: 'amqp://payments-broker:5672' })],
  providers: [PaymentsService],
})
export class PaymentsModule {}
```

Each import produces a distinct module definition with its own `RABBIT_OPTIONS`/`RABBIT_CONNECTION` providers — `OrdersService` and `PaymentsService` inject connections pointed at *different* brokers, from one shared module class.

**Example 2 — real vs. fake, same module, different recipe.** A dynamic module doesn't have to vary just a `useValue`; it can swap the whole *recipe* behind a token. Give `RabbitModule` a second static method that returns an in-memory stub for tests, exporting the same `RABBIT_CONNECTION` token so nothing downstream changes:

```ts
@Module({})
export class RabbitModule {
  static forRoot(options: { url: string }): DynamicModule {
    return {
      module: RabbitModule,
      providers: [
        { provide: 'RABBIT_OPTIONS', useValue: options },
        {
          provide: 'RABBIT_CONNECTION',
          useFactory: (opts: { url: string }) => connectToRabbit(opts.url),
          inject: ['RABBIT_OPTIONS'],
        },
      ],
      exports: ['RABBIT_CONNECTION'],
    };
  }

  // Same token, a totally different build — no live broker.
  static forTest(): DynamicModule {
    return {
      module: RabbitModule,
      providers: [{ provide: 'RABBIT_CONNECTION', useValue: new InMemoryRabbit() }],
      exports: ['RABBIT_CONNECTION'],
    };
  }
}

// production wiring
@Module({ imports: [RabbitModule.forRoot({ url: 'amqp://orders-broker:5672' })] })
export class AppModule {}

// test wiring — OrdersService is none the wiser
@Module({ imports: [RabbitModule.forTest()], providers: [OrdersService] })
export class OrdersTestModule {}
```

Because both methods export the *same* `'RABBIT_CONNECTION'` token, consumers inject it identically — the module decides at import time whether that resolves to a live connection or an in-memory fake. This is the testability/swappability payoff from earlier, now at the *module* granularity.

`forRoot(...)` is a convention (`ConfigModule.forRoot()`, `TypeOrmModule.forRoot()`).

## `forRootAsync`: when the config itself must be injected

The `forRoot` examples above work if you have the value in hand when you write the `@Module()` decorator — a literal URL string, an env var read inline. But real apps usually need the config to come from `ConfigService` (validated env, secrets, per-environment values) — which itself needs to be *injected*, which means it isn't available at plain-argument time. `RabbitModule.forRoot({ url: ??? })` runs while the decorator is being evaluated, long before the DI container has built anything. `ConfigService` only exists at **DI-resolution time**. So there's simply no way to reach into it from a plain method argument.

The fix is to hand the module a *recipe* for the options instead of the options themselves — a `useFactory` that lists its own `inject` dependencies. The module registers that factory internally, so it runs later, during resolution, once `ConfigService` has been built:

```ts
@Module({})
export class RabbitModule {
  static forRootAsync(options: {
    useFactory: (...args: any[]) => { url: string } | Promise<{ url: string }>;
    inject?: any[];
  }): DynamicModule {
    return {
      module: RabbitModule,
      providers: [
        // The importer's factory becomes the RABBIT_OPTIONS provider —
        // resolved with its own injected deps, not at decorator time.
        {
          provide: 'RABBIT_OPTIONS',
          useFactory: options.useFactory,
          inject: options.inject ?? [],
        },
        {
          provide: 'RABBIT_CONNECTION',
          useFactory: (opts: { url: string }) => connectToRabbit(opts.url),
          inject: ['RABBIT_OPTIONS'],
        },
      ],
      exports: ['RABBIT_CONNECTION'],
    };
  }
}
```

Now the importer passes a factory that pulls the URL from validated config — no hardcoded string anywhere:

```ts
@Module({
  imports: [
    ConfigModule, // exports ConfigService
    RabbitModule.forRootAsync({
      useFactory: (config: ConfigService) => ({ url: config.get('RABBIT_URL') }),
      inject: [ConfigService], // resolved and passed into the factory, in order
    }),
  ],
})
export class AppModule {}
```

The ordering that makes this work: at boot the container builds `ConfigService` first (it's a dependency), then calls your `useFactory` with it to produce `RABBIT_OPTIONS`, then runs the `RABBIT_CONNECTION` factory with those options. The `inject` array is what tells the container *what to build first and in what order to pass it*.

This is how you wire a RabbitMQ connection and HTTP clients from validated config instead of hardcoded strings — the discipline covered in Topic 5.

> **Mental model:** `forRoot` / `forRootAsync` = "let the importer configure me." `forRoot` takes the options directly (you have them in hand); `forRootAsync` takes a `useFactory` + `inject` so the options can be *computed from other providers* like `ConfigService`, which only exist at DI-resolution time — not when the decorator runs.

---

## The bridge to scopes

At bootstrap, NestJS resolves the whole graph once and builds instances — and by default each provider is a **single shared instance** for the entire app lifetime. That's fine for stateless services, but it has a sharp edge the moment you want to hold *per-request* state: under request interleaving (every `await` is a yield point), a shared instance's field can be overwritten by another request. That edge is what injection **scopes** address — see `02b-nestjs-di-scopes-deep.md`.

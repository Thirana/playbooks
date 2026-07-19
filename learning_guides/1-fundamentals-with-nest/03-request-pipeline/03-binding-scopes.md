# Binding Scope & the `APP_*` Tokens

> This "scope" is a different axis from injection scope. **Injection scope** (DEFAULT / REQUEST / TRANSIENT) is *how many instances exist*. **Binding scope** (method / controller / global) is *how many routes one component covers*. A single component has both.

---

## Where we start: a guard bound to one route

You've written an `AuthGuard`. The first place you need it is a single sensitive route — say, `DELETE /orders/:id`. You bind it right there on the handler:

```ts
@Controller('orders')
export class OrdersController {
  @Delete(':id')
  @UseGuards(AuthGuard)
  remove(@Param('id') id: string) { /* ... */ }
}
```

`@UseGuards(AuthGuard)` on the method means: run this guard for *this one handler only*. This is **method-level binding** — the narrowest reach a pipeline component can have. The same decorator style works for the other stages too (`@UseInterceptors`, `@UsePipes`, `@UseFilters`).

This is fine for one route. The itch starts when you realize *every* route in `OrdersController` needs the same guard, and you don't want to paste `@UseGuards(AuthGuard)` onto all eight handlers.

## Widening the reach: controller-level binding

Move the exact same decorator up to the class:

```ts
@Controller('orders')
@UseGuards(AuthGuard) // now applies to every handler in this controller
export class OrdersController { /* ... */ }
```

Nothing new to learn — same decorator, higher placement. Now the guard covers all routes in the controller. This is the second concept: **binding scope is about breadth — how many routes one component instance is responsible for.** Method-level covers one handler; controller-level covers one controller's handlers.

> **Mental model:** the decorator is the same at every level. *Where you put it* — method, class — decides how many routes it guards. Nothing about the guard's own code changes.

The next itch: you have twenty controllers, and `AuthGuard` (or a logging interceptor, or an error filter) should apply to *the entire app*. You don't want it on twenty classes either.

## Going global: the naive way, and the pain

Nest gives you an imperative way to bind app-wide, in `main.ts`:

```ts
// main.ts
const app = await NestFactory.create(AppModule);
app.useGlobalGuards(new AuthGuard()); // applies to every route in the app
```

This *works* for a guard with no dependencies. But look closely at `new AuthGuard()` — **you** are constructing it, by hand, outside Nest's container. That's the whole pain, and it bites the moment `AuthGuard` needs anything:

```ts
@Injectable()
export class AuthGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,   // to read @Roles() metadata
    private readonly config: ConfigService,  // to read the JWT secret
    private readonly auth: AuthService,       // to verify the token
  ) {}
  /* ... */
}
```

Now `new AuthGuard()` is broken — it needs three injected dependencies, and you're building it with `new`, so you'd have to construct `Reflector`, `ConfigService`, and `AuthService` (and *their* dependencies) yourself and pass them in. That's exactly the manual-wiring hell DI was supposed to delete. The pains:

- **No DI.** A hand-`new`ed component can't inject anything — it's outside the container entirely.
- **Duplicated wiring.** You'd rebuild dependency trees by hand that Nest already knows how to build.
- **Can't be scoped.** A single hand-constructed instance can't be request-scoped — it's one object, made once, forever.

Root problem: **`app.useGlobalGuards(new X())` gives you global reach but at the cost of leaving DI behind.** You want global reach *and* full DI.

## The fix: the `APP_GUARD` token

Nest's answer is to register the global component as a **provider**, using a special token, instead of `new`-ing it in `main.ts`:

```ts
// app.module.ts
import { APP_GUARD } from '@nestjs/core';

@Module({
  providers: [
    AuthService,
    { provide: APP_GUARD, useClass: AuthGuard },
  ],
})
export class AppModule {}
```

This is the same `token -> recipe` provider idea from the DI note. `APP_GUARD` is the token; `useClass: AuthGuard` is the recipe. Because Nest now builds the guard **through the container**, `AuthGuard` gets full constructor injection — `Reflector`, `ConfigService`, `AuthService` all resolved normally. And it's still global: `APP_GUARD` tells Nest "apply this to every route."

You get both properties that were in tension before: **global reach and full DI.**

> **Mental model:** `app.useGlobalGuards(new X())` = global, but *you* build it (no DI). `{ provide: APP_GUARD, useClass: X }` = global, but *Nest* builds it (full DI). Same reach, opposite construction. Prefer the token form whenever the component has dependencies — which is almost always.

## Three properties that fall out of DI registration

Because `APP_GUARD` goes through the container, three useful things follow that the `main.ts` form can't give you:

- **It can be request-scoped.** `{ provide: APP_GUARD, useClass: AuthGuard, scope: Scope.REQUEST }` gives you a fresh guard per request — impossible with a single hand-`new`ed instance. (Same scope-contagion caveat from the scopes note applies: a request-scoped global guard re-scopes a lot.)
- **It applies app-wide even when registered in a feature module.** This surprises people: an `APP_GUARD` provider declared inside, say, `AuthModule` still guards the *whole app*, not just `AuthModule`'s routes. The `APP_*` tokens are special — Nest lifts them to global regardless of which module declares them. So put them where their dependencies naturally live.
- **You can register several of the same token.** Normally two providers with the same token means the last wins. But Nest treats `APP_GUARD` (and the others) as multi-bindings — register three `APP_GUARD` providers and all three run. Handy for stacking, say, an auth guard and a rate-limit guard globally.

## Global-by-default, opt out per route

Once a guard is global it runs on *every* route — including the login route, which can't require a valid token to log you in. So you need the inverse of `@UseGuards`: a way to say "skip the global guard *here*." Nest has no "un-use" decorator. Instead you set custom **metadata** on the route, and the global guard reads that metadata and decides to skip its own logic.

This flips the default. Instead of adding a guard where you want protection, the guard is everywhere and you *mark the exceptions*. For auth that's the safe direction — forget to annotate a route and it stays **protected**, not exposed.

**1. Define the opt-out marker (a metadata decorator):**

```ts
// public.decorator.ts
import { SetMetadata } from '@nestjs/common';

export const IS_PUBLIC_KEY = 'isPublic';
export const Public = () => SetMetadata(IS_PUBLIC_KEY, true);
```

**2. The global guard reads that marker and skips when present:**

```ts
// auth.guard.ts
import { CanActivate, ExecutionContext, Injectable } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { IS_PUBLIC_KEY } from './public.decorator';

@Injectable()
export class AuthGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  canActivate(context: ExecutionContext): boolean {
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      context.getHandler(), // method-level marker
      context.getClass(),   // controller-level marker
    ]);

    if (isPublic) {
      return true; // opt-out hit — skip auth, let the request through
    }

    // ...normal auth logic runs for everything else
    return this.validateToken(context);
  }
}
```

**3. Register it globally (as above), then opt a route out:**

```ts
@Controller('auth')
export class AuthController {
  @Public() // this one route skips the global guard's logic
  @Post('login')
  login() { /* ... */ }
}
```

Three points that make this work:

- **The guard always runs — it just returns early.** Nothing removes the guard from the route. The global guard executes on every request; the `@Public()` routes simply hit the `return true` branch before doing real work. Opt-out is a *decision inside the component*, not a change to what's bound.
- **`getAllAndOverride` checks both levels, method wins.** `getAllAndOverride(key, [handler, class])` reads the marker off the method *and* the controller, with the method taking precedence if both set it. That's what lets you mark a whole controller `@Public()` and flip one route back, or the reverse. Plain `reflector.get(key, handler)` only checks one level.
- **Same recipe for interceptors and filters.** A global logging interceptor can read a `@NoLog()` marker and pass through untouched; a global transform interceptor can check `@SkipTransform()`. Global binding + metadata marker + `Reflector` check, unchanged.

Pipes are the odd one out here. This metadata-skip idiom belongs to guards and interceptors because they get `ExecutionContext` (with `getHandler`/`getClass` for reflection). A global `ValidationPipe` doesn't opt out per-route this way — you control it per-DTO/per-property with `class-validator` decorators instead, since a pipe operates on the argument value, not the route.

> **Mental model:** "global + opt-out" inverts the default from *add protection where needed* to *protect everything, mark exceptions*. The opt-out isn't an un-bind — it's a marker the always-running component reads and honors. Keep the marker (`@Public()`) obvious in review, since it's the thing that turns protection off.

## The same story for the other three stages

Nothing above is guard-specific. Each pipeline stage has its own `APP_*` token, and the exact same three-level binding (method / controller / global) plus the same DI payoff:

| Stage | Method / controller decorator | Global via DI token |
|---|---|---|
| Guard | `@UseGuards(X)` | `APP_GUARD` |
| Interceptor | `@UseInterceptors(X)` | `APP_INTERCEPTOR` |
| Pipe | `@UsePipes(X)` | `APP_PIPE` |
| Exception filter | `@UseFilters(X)` | `APP_FILTER` |

All four tokens come from `@nestjs/core`, all four give the registered component full DI, and all four have imperative `main.ts` equivalents (`useGlobalInterceptors`, `useGlobalPipes`, `useGlobalFilters`) that share the same "no DI, hand-constructed" limitation. The most common real use of `APP_PIPE` is registering a `ValidationPipe` app-wide so every DTO is validated without decorating each route.

## Ordering when a request hits several levels

A request can pass through a global, a controller, and a method binding of the same stage. The incoming order is **global -> controller -> method** — broadest first, narrowest last. For guards and pipes that's the whole story.

Interceptors are the exception, because they wrap *both sides* of the handler (the pre/post split from the pipeline table). On the way **out**, they run in reverse — **method -> controller -> global** — like nested function calls: the outermost (global) interceptor starts first, so it finishes last. If a global interceptor wraps the response in `{ data, meta }` and a controller one adds a timing header, the header goes on first, then the whole thing gets wrapped — the outer layer closes last.

> **One line:** incoming is broad-to-narrow (global first); an interceptor's outgoing half is narrow-to-broad (global last).

## Where middleware sits apart

Middleware is the one stage that *doesn't* use this decorator/`APP_*` system at all — it predates the Nest context and binds the Express/Fastify way. You register it either functionally with `app.use(...)` in `main.ts`, or as a class in a module's `configure(consumer)` method with `consumer.apply(X).forRoutes(...)`. There's no `APP_MIDDLEWARE` token. The parallel does hold, though: functional middleware via `app.use()` can't inject dependencies (same hand-constructed pain), while class middleware registered through `configure()` goes through DI and can. If a global thing needs the request handler's metadata or DI, that's usually your signal it should be a guard or interceptor, not middleware.

> **Mental model:** two independent axes. *Injection scope* (DEFAULT / REQUEST / TRANSIENT) = how many instances exist. *Binding scope* (method / controller / global) = how many routes one component covers. A single component has both — e.g. a request-scoped (`Scope.REQUEST`) guard bound globally (`APP_GUARD`).

---

## The bridge to the rest of the pipeline

You now have both halves: *what* each stage does and in what order (the pipeline table), and *how* to bind each one at the right breadth with the right DI (this note). The remaining piece of the cross-cutting arc is the components themselves — writing a real guard that reads `@Roles()` metadata off `ExecutionContext` via `Reflector`, an interceptor that times and reshapes responses, and a filter that maps domain errors to HTTP status codes — where all the pieces so far get used together.
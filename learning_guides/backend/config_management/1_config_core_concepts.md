# NestJS Config Core Concepts

Purpose: This note explains the mental model behind config management in NestJS before you get into the full implementation.

## Related Notes

- [2. Full Config Learning Guide](./2_config_learning_guide.md)
- [3. NestJS Config Bootstrap Flow](./3_nestjs_config_bootstrap_flow.md)
- [4. Config Revision Cheatsheet](./4_config_revision_cheatsheet.md)

---

## 1. Why direct `process.env` access becomes a problem

Node.js exposes environment variables through `process.env`, but using it directly across the codebase creates several issues:

- there is no central validation
- every value comes in as a string
- defaults get repeated everywhere
- related settings are not grouped
- failures happen far away from the real cause

Example:

```typescript
const port = process.env.PORT;
```

That looks simple, but `port` is actually a string, it may be missing, and nothing enforces that it is a valid number.

---

## 2. What `@nestjs/config` gives you

`@nestjs/config` is NestJS's official configuration module. It helps you:

- load env files
- validate required values at startup
- organize config into namespaces
- inject config through Nest's DI system
- access config in a typed, structured way

Its main building blocks are:

- `ConfigModule`
- `ConfigService`
- config factories created with `registerAs()`
- validation, often with Joi

---

## 3. The fail-fast idea

Fail fast means:

- if a required config value is missing or invalid, crash during application startup
- do not allow the app to continue in a broken state

Why this is better:

- the error points to the actual config problem
- startup fails before database or auth modules break later
- new developers get immediate feedback instead of deep runtime errors

Typical example:

- `DATABASE_HOST` is missing
- Joi validation rejects startup
- the process stops immediately with a clear message

---

## 4. Raw env loading vs structured config

These two steps are related but not the same.

### Raw env loading

This is where `.env` files are read and merged into `process.env`.

Common example:

```typescript
ConfigModule.forRoot({
  envFilePath: [".env.local", ".env"],
});
```

### Structured config

This is where you transform raw env variables into grouped application config.

Common example:

```typescript
export default registerAs("app", () => ({
  nodeEnv: process.env.NODE_ENV || "development",
  port: parseInt(process.env.PORT ?? "3000", 10),
}));
```

Short version:

- `envFilePath` loads raw values
- `load` + `registerAs()` organizes them into application-friendly objects

---

## 5. Why namespaces matter

Config namespaces group related settings together.

Examples:

- `app.port`
- `database.host`
- `auth.jwtSecret`

That gives you:

- better structure
- easier discovery
- fewer naming collisions
- more readable config access throughout the app

Without namespaces, everything stays flat and harder to reason about.

---

## 6. Why type conversion belongs in the factory

Environment variables are strings by default, so conversion must happen somewhere.

Good place:

- inside the config factory

Bad place:

- scattered across controllers and services

Example:

```typescript
export default registerAs("database", () => ({
  port: parseInt(process.env.DATABASE_PORT ?? "5432", 10),
}));
```

This keeps the rest of the app from repeatedly converting the same values.

---

## 7. `forRoot()` vs `forFeature()`

### `ConfigModule.forRoot()`

Use this once at the application root.

It typically:

- loads env files
- registers validation
- loads config factories
- makes `ConfigService` available to the app

### `ConfigModule.forFeature()`

Use this when a feature module wants to register or consume only a specific config slice.

This is more useful in larger apps or monorepos where not every module should care about the full config graph.

Fast rule:

- root app setup -> `forRoot()`
- feature-specific config slice -> `forFeature()`

---

## 8. `ConfigService` access patterns

`ConfigService` is the main read interface.

Common methods:

- `get()` -> read a value, possibly undefined
- `getOrThrow()` -> read a value and fail immediately if it is missing

Examples:

```typescript
const port = configService.get<number>("app.port");
const secret = configService.getOrThrow<string>("auth.jwtSecret");
```

When to prefer `getOrThrow()`:

- the value is required
- the module cannot function without it
- you want a clear failure instead of carrying `undefined` forward

---

## 9. Typing config more strongly

There are two common improvements beyond plain `get<string>()`.

### `ConfigService<AppConfig>`

You can provide the overall config shape as a generic:

```typescript
constructor(private readonly configService: ConfigService<AppConfig>) {}
```

This helps TypeScript understand your config layout.

### `ConfigType<typeof appConfig>`

When using a factory created with `registerAs()`, NestJS can infer the returned type:

```typescript
import appConfig from "./app.config";
import { ConfigType } from "@nestjs/config";

type AppConfig = ConfigType<typeof appConfig>;
```

This is useful when you want strong typing tied directly to the factory instead of maintaining a separate duplicated interface.

---

## 10. What happens in `main.ts`

`main.ts` is outside normal constructor injection, so it cannot receive `ConfigService` the same way a provider does.

Instead:

- create the app
- retrieve `ConfigService` from the DI container
- read the values you need

Example:

```typescript
const app = await NestFactory.create(AppModule);
const configService = app.get(ConfigService);
const port = configService.getOrThrow<number>("app.port");
```

---

## 11. Production mindset

Good config management is not just about convenience. It is also about safety.

Important reminders:

- commit `.env.example`, not `.env`
- use secret managers in production when possible
- consider `ignoreEnvFile: true` in deployed environments where the platform injects env vars directly
- never log the raw config object if it contains secrets

---

## 12. Concept checkpoints

If you can answer these quickly, the core ideas are solid:

- Why is direct `process.env` usage not enough in a larger NestJS app?
- What is the difference between loading env files and loading config factories?
- Why should validation happen during startup?
- When would you use `getOrThrow()` instead of `get()`?
- What problem do namespaces like `database.host` solve?

If you want the runtime startup story next, use [3. NestJS Config Bootstrap Flow](./3_nestjs_config_bootstrap_flow.md).

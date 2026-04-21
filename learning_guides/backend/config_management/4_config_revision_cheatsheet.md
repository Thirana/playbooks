# Config Revision Cheatsheet: NestJS

Purpose: This is the shortest note in the set. Use it for quick recall, interview prep, and fast implementation review.

## Related Notes

- [1. Config Core Concepts](./1_config_core_concepts.md)
- [2. Full Config Learning Guide](./2_config_learning_guide.md)
- [3. NestJS Config Bootstrap Flow](./3_nestjs_config_bootstrap_flow.md)

---

## Memorize These First

- `process.env` is raw and unstructured
- `ConfigModule.forRoot()` sets up app-wide config
- Joi validation makes config fail fast
- `registerAs()` groups config into namespaces
- `ConfigService` reads config through DI
- `getOrThrow()` is safer for required values
- `.env.example` should be committed
- `.env` should not be committed

---

## Quick Facts

- all env values start as strings
- `envFilePath` controls which env files are loaded
- `load` registers config factories
- `validationSchema` enforces required values at startup
- `validationOptions.abortEarly: false` reports all validation errors together
- `ignoreEnvFile: true` is often useful in production when the platform injects env vars directly

---

## Namespace Examples

Typical keys:

- `app.port`
- `app.nodeEnv`
- `database.host`
- `database.port`
- `auth.jwtSecret`
- `auth.jwtExpiresIn`

Typical factory:

```typescript
export default registerAs("app", () => ({
  nodeEnv: process.env.NODE_ENV || "development",
  port: parseInt(process.env.PORT ?? "3000", 10),
}));
```

---

## Startup Flow In One Glance

```text
ConfigModule.forRoot()
  -> load env files
  -> validate env
  -> run config factories
  -> register namespaces
  -> inject ConfigService
  -> app reads config and starts
```

---

## Main API Surface

| Item | Job |
| --- | --- |
| `ConfigModule.forRoot()` | Root config setup |
| `ConfigModule.forFeature()` | Feature-specific config registration |
| `ConfigService.get()` | Read config value, may be undefined |
| `ConfigService.getOrThrow()` | Read required config value or fail immediately |
| `registerAs()` | Create a named config namespace |
| `ConfigType<typeof factory>` | Infer a factory's returned config type |

---

## File Responsibility Map

| File | Main responsibility |
| --- | --- |
| `.env` | Local development values |
| `.env.example` | Template of required env keys |
| `config.validation.ts` | Joi validation schema |
| `app.config.ts` | App namespace |
| `database.config.ts` | Database namespace |
| `auth.config.ts` | Auth namespace |
| `app.module.ts` | Root config registration |
| `main.ts` | Reads startup config from DI container |

---

## Common Mistakes

- accessing `process.env` directly throughout services
- forgetting that env values are strings
- not validating required keys at startup
- using the wrong namespace key with `ConfigService`
- duplicating type conversion in multiple places
- committing `.env`
- logging config objects that contain secrets

---

## Interview Prompts and Fast Answers

**Why not just use `process.env` directly?**

- because it gives you raw strings, no central validation, and poor structure

**What is the difference between `envFilePath` and `load`?**

- `envFilePath` loads raw env variables
- `load` converts them into structured namespaced config

**Why use Joi here?**

- to fail fast during startup if config is missing or invalid

**When should I use `getOrThrow()`?**

- when the caller cannot function without that config value

**What is `forFeature()` for?**

- partial or feature-specific config registration in larger apps

---

## Last-Minute Recall

If you are revising in 30 seconds, remember this:

- load env
- validate env
- convert and group config
- inject `ConfigService`
- fail early when required config is missing

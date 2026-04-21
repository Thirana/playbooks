# NestJS Config Bootstrap Flow

Purpose: This note explains what happens at runtime when a NestJS application loads configuration during startup.

## Related Notes

- [1. Config Core Concepts](./1_config_core_concepts.md)
- [2. Full Config Learning Guide](./2_config_learning_guide.md)
- [4. Config Revision Cheatsheet](./4_config_revision_cheatsheet.md)

---

## TaskFlow setup used in this note

Assume the app has:

- `app` config namespace
- `database` config namespace
- `auth` config namespace
- Joi validation for env variables
- `JwtModule.registerAsync()` reading from `ConfigService`

---

## 1. The high-level startup chain

For a typical NestJS app using `@nestjs/config`, the simplified startup flow is:

```text
Application start
  -> ConfigModule.forRoot()
  -> env files loaded into process.env
  -> validation runs
  -> config factories execute
  -> modules consume ConfigService
  -> main.ts reads startup config
  -> app listens
```

If configuration is invalid, the app should fail before later modules try to run.

---

## 2. Env file loading flow

When the application starts, `ConfigModule.forRoot()` loads env values first.

Example:

```typescript
ConfigModule.forRoot({
  envFilePath: [".env.local", ".env"],
});
```

Runtime effect:

1. NestJS begins bootstrapping the root module.
2. `ConfigModule.forRoot()` runs early in the import chain.
3. The configured env files are read.
4. Their values are merged into `process.env`.
5. Later config logic reads from `process.env`.

Important detail:

- env-file order matters
- the first matching file wins when duplicate keys exist

That means `.env.local` can override `.env` if it appears first in the array.

---

## 3. Validation flow

After raw env values are loaded, validation runs.

Example:

```typescript
ConfigModule.forRoot({
  validationSchema: configValidationSchema,
  validationOptions: {
    abortEarly: false,
  },
});
```

Runtime effect:

1. Joi checks every configured variable.
2. Missing required values are rejected.
3. Invalid values are rejected.
4. If there are problems, startup stops immediately.

Why `abortEarly: false` helps:

- it reports all validation errors at once
- you do not have to restart repeatedly to discover missing keys one by one

Example failure:

- `DATABASE_HOST` missing
- `JWT_SECRET` too short
- startup fails before the app listens on any port

---

## 4. Config factory flow

Once raw env values exist and validation has passed, config factories can safely run.

Example:

```typescript
load: [appConfig, databaseConfig, authConfig]
```

Each factory:

- reads from `process.env`
- converts raw strings into app-friendly values
- registers a namespaced config object

Example namespace results:

- `app.port`
- `database.host`
- `auth.jwtSecret`

This is the step that turns raw env data into structured application config.

---

## 5. Module consumption flow

After config is registered, other modules can consume it through `ConfigService`.

Example with `JwtModule.registerAsync()`:

```typescript
JwtModule.registerAsync({
  inject: [ConfigService],
  useFactory: (configService: ConfigService) => ({
    secret: configService.getOrThrow<string>("auth.jwtSecret"),
    signOptions: {
      expiresIn: configService.getOrThrow<string>("auth.jwtExpiresIn"),
    },
  }),
})
```

Runtime story:

1. the module factory requests `ConfigService`
2. Nest injects it from the DI container
3. the factory reads namespaced config values
4. the module is configured with validated settings

If required values are missing here, `getOrThrow()` makes the failure explicit.

---

## 6. `main.ts` bootstrap flow

`main.ts` is different because it does not receive constructor injection.

Typical flow:

1. `NestFactory.create(AppModule)` creates the application
2. `app.get(ConfigService)` retrieves config from the DI container
3. startup-specific values are read, such as the listening port
4. `app.listen(port)` starts the server

Example:

```typescript
const app = await NestFactory.create(AppModule);
const configService = app.get(ConfigService);
const port = configService.getOrThrow<number>("app.port");
await app.listen(port);
```

---

## 7. End-to-end startup story

This is the clean interview narration:

1. The developer runs the NestJS app.
2. `AppModule` loads and `ConfigModule.forRoot()` runs.
3. Env files are read and merged into `process.env`.
4. Joi validation runs and rejects startup if required values are missing or invalid.
5. Config factories execute and register the `app`, `database`, and `auth` namespaces.
6. Modules such as `JwtModule` read config through `ConfigService`.
7. `main.ts` retrieves `ConfigService` from the app container and reads `app.port`.
8. The server starts with validated, structured config instead of scattered raw env access.

---

## 8. Common failure points

| Symptom | Likely cause |
| --- | --- |
| Startup fails before the app listens | Joi validation rejected missing or invalid env values |
| Wrong config value appears in the app | `envFilePath` precedence is not what you expected |
| `undefined` from `ConfigService.get()` | Wrong namespace key or missing config registration |
| Type mismatch later in the app | Conversion was skipped or done inconsistently |
| Deployed app ignores local `.env` assumptions | Production env vars differ or `ignoreEnvFile` behavior is different |

---

## 9. Debugging checklist

When config is failing, check in this order:

1. Did `ConfigModule.forRoot()` actually register the right `envFilePath`, `load`, and validation options?
2. Are the env variable names in `.env`, Joi validation, and config factories all spelled the same way?
3. Is the env-file precedence correct for your environment?
4. Are numeric or boolean values converted in the factory instead of later in the app?
5. Are consuming modules using the correct namespace keys such as `database.host` or `auth.jwtSecret`?
6. If a value is required, should the caller use `getOrThrow()` instead of `get()`?

Use this note for the runtime startup story. Use [4. Config Revision Cheatsheet](./4_config_revision_cheatsheet.md) when you only need the compressed version.

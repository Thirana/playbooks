# NestJS Config Management

Purpose: This is the long-form implementation guide for managing configuration in NestJS with `@nestjs/config`, Joi validation, and config factories.

## Related Notes

- [1. Config Core Concepts](./1_config_core_concepts.md)
- [3. NestJS Config Bootstrap Flow](./3_nestjs_config_bootstrap_flow.md)
- [4. Config Revision Cheatsheet](./4_config_revision_cheatsheet.md)

---

## The Developer Requirement

You have just joined the TaskFlow API team. The codebase has the following problems:

- database credentials are hardcoded in `app.module.ts`
- the JWT secret is committed directly in source code
- the app starts even when required environment variables are missing
- developers get confusing runtime errors instead of clear startup failures

Your job is to fix all of this with a proper, production-grade configuration system.

---

## How To Use This Note

- Read this file when you want the full implementation walkthrough.
- Use [1. Config Core Concepts](./1_config_core_concepts.md) when you want the ideas without the full setup.
- Use [3. NestJS Config Bootstrap Flow](./3_nestjs_config_bootstrap_flow.md) when you want to understand startup order and debugging.
- Use [4. Config Revision Cheatsheet](./4_config_revision_cheatsheet.md) for quick revision and interview prep.

---

## Part 1: Core Mental Model

### Why `process.env` directly is not enough

Direct `process.env` access works in small scripts, but it becomes weak in real NestJS applications:

- missing values are discovered too late
- every value is a string
- type conversion gets repeated everywhere
- related settings are not grouped
- defaults are duplicated across modules

That is why NestJS config management usually combines:

- `ConfigModule`
- Joi validation
- `registerAs()` factories
- `ConfigService`

### What `@nestjs/config` gives you

`@nestjs/config` is the official NestJS config module. It integrates env loading and config access into Nest's dependency injection system.

It gives you:

- env file loading
- startup-time validation
- named config namespaces
- structured config access from services and modules

### The fail-fast principle

Fail fast means:

- if required config is missing or invalid, the app crashes immediately during boot

This is better than letting the app start and fail later when a module tries to use bad config.

If you want the concept-only version of these ideas, see [1. Config Core Concepts](./1_config_core_concepts.md).

---

## Part 2: Project Setup

### Install dependencies

```bash
npm install --save @nestjs/config
npm install --save joi
```

### File structure

```text
src/
  config/
    app.config.ts
    database.config.ts
    auth.config.ts
    config.validation.ts
  app.module.ts
  main.ts
```

Each file has a clear role:

- `app.config.ts` -> app-level config such as port and environment flags
- `database.config.ts` -> database connection settings
- `auth.config.ts` -> auth-related values such as JWT settings
- `config.validation.ts` -> Joi schema for fail-fast validation

---

## Part 3: Environment Files

Create a `.env` file for local development and an `.env.example` file for teammates.

**`.env`**

```text
NODE_ENV=development
PORT=3000

DATABASE_HOST=localhost
DATABASE_PORT=5432
DATABASE_NAME=taskflow_db
DATABASE_USER=postgres
DATABASE_PASSWORD=postgres

JWT_SECRET=your-super-secret-key-change-in-production
JWT_EXPIRES_IN=1d
```

**`.env.example`**

```text
NODE_ENV=
PORT=

DATABASE_HOST=
DATABASE_PORT=
DATABASE_NAME=
DATABASE_USER=
DATABASE_PASSWORD=

JWT_SECRET=
JWT_EXPIRES_IN=
```

Important rule:

- commit `.env.example`
- do not commit `.env`

---

## Part 4: Validation With Joi

Validation is what turns config management from "convenient" into "safe".

**`src/config/config.validation.ts`**

```typescript
import * as Joi from "joi";

export const configValidationSchema = Joi.object({
  NODE_ENV: Joi.string()
    .valid("development", "production", "test")
    .default("development"),

  PORT: Joi.number().default(3000),

  DATABASE_HOST: Joi.string().required(),
  DATABASE_PORT: Joi.number().default(5432),
  DATABASE_NAME: Joi.string().required(),
  DATABASE_USER: Joi.string().required(),
  DATABASE_PASSWORD: Joi.string().required(),

  JWT_SECRET: Joi.string().min(32).required(),
  JWT_EXPIRES_IN: Joi.string().default("1d"),
});
```

What this gives you:

- required values are enforced
- invalid values are caught early
- numeric values can be validated as numbers
- secrets can have minimum strength requirements

Example failure:

```text
Error: Config validation error: "DATABASE_HOST" is required
```

That is fail fast in action.

---

## Part 5: Config Factories With `registerAs()`

Instead of spreading raw env access across the app, create config factories that group related values into namespaces.

### App config

**`src/config/app.config.ts`**

```typescript
import { registerAs } from "@nestjs/config";

export default registerAs("app", () => ({
  nodeEnv: process.env.NODE_ENV || "development",
  port: parseInt(process.env.PORT ?? "3000", 10),
  isDevelopment: process.env.NODE_ENV === "development",
  isProduction: process.env.NODE_ENV === "production",
}));
```

### Database config

**`src/config/database.config.ts`**

```typescript
import { registerAs } from "@nestjs/config";

export default registerAs("database", () => ({
  host: process.env.DATABASE_HOST,
  port: parseInt(process.env.DATABASE_PORT ?? "5432", 10),
  name: process.env.DATABASE_NAME,
  user: process.env.DATABASE_USER,
  password: process.env.DATABASE_PASSWORD,
}));
```

### Auth config

**`src/config/auth.config.ts`**

```typescript
import { registerAs } from "@nestjs/config";

export default registerAs("auth", () => ({
  jwtSecret: process.env.JWT_SECRET,
  jwtExpiresIn: process.env.JWT_EXPIRES_IN || "1d",
}));
```

Why this pattern matters:

- values are grouped by responsibility
- type conversion happens in one place
- config is easier to discover and reuse

Key detail:

- the `.env` file is loaded before these factories run
- so reading `process.env` inside the factory is safe

---

## Part 6: Wire Everything In `AppModule`

**`src/app.module.ts`**

```typescript
import { Module } from "@nestjs/common";
import { ConfigModule } from "@nestjs/config";
import appConfig from "./config/app.config";
import authConfig from "./config/auth.config";
import databaseConfig from "./config/database.config";
import { configValidationSchema } from "./config/config.validation";

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      load: [appConfig, databaseConfig, authConfig],
      validationSchema: configValidationSchema,
      validationOptions: {
        abortEarly: false,
      },
      envFilePath: [".env.local", ".env"],
    }),
  ],
})
export class AppModule {}
```

Important options:

- `isGlobal: true` -> `ConfigService` is available across the app
- `load` -> registers namespaced factories
- `validationSchema` -> runs Joi validation during startup
- `validationOptions.abortEarly: false` -> shows all validation issues at once
- `envFilePath` -> controls env-file precedence

Production note:

- when the deployment platform injects env vars directly, `ignoreEnvFile: true` is often appropriate

---

## Part 7: Use `ConfigService` In Other Modules

### In a module factory

A common use case is configuring another module, such as `JwtModule`.

**`src/auth/auth.module.ts`**

```typescript
import { Module } from "@nestjs/common";
import { JwtModule } from "@nestjs/jwt";
import { ConfigModule, ConfigService } from "@nestjs/config";

@Module({
  imports: [
    JwtModule.registerAsync({
      imports: [ConfigModule],
      inject: [ConfigService],
      useFactory: (configService: ConfigService) => ({
        secret: configService.getOrThrow<string>("auth.jwtSecret"),
        signOptions: {
          expiresIn: configService.getOrThrow<string>("auth.jwtExpiresIn"),
        },
      }),
    }),
  ],
})
export class AuthModule {}
```

Why `getOrThrow()` is useful here:

- JWT config is required
- if it is missing, the module should fail immediately

### In a regular service

**`src/tasks/tasks.service.ts`**

```typescript
import { Injectable } from "@nestjs/common";
import { ConfigService } from "@nestjs/config";

@Injectable()
export class TasksService {
  constructor(private readonly configService: ConfigService) {}

  getEnvironmentInfo() {
    const appConfig = this.configService.get("app");
    const nodeEnv = this.configService.get<string>("app.nodeEnv");
    const dbHost = this.configService.get<string>("database.host");
    const timeout = this.configService.get<number>("app.timeout", 5000);

    return { appConfig, nodeEnv, dbHost, timeout };
  }
}
```

### Stronger typing

You can make config typing stricter with either a generic interface or `ConfigType<typeof factory>`.

Example:

```typescript
import appConfig from "./config/app.config";
import { ConfigType, ConfigService } from "@nestjs/config";

type AppConfig = ConfigType<typeof appConfig>;

function readAppConfig(configService: ConfigService) {
  const port = configService.getOrThrow<number>("app.port");
  return port;
}
```

This is especially useful when you want types tied directly to the config factory instead of maintaining duplicate interfaces manually.

---

## Part 8: Use `ConfigService` In `main.ts`

`main.ts` does not use constructor injection, so it retrieves `ConfigService` from the app after bootstrapping.

**`src/main.ts`**

```typescript
import { NestFactory } from "@nestjs/core";
import { ConfigService } from "@nestjs/config";
import { AppModule } from "./app.module";

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  const configService = app.get(ConfigService);

  const port = configService.getOrThrow<number>("app.port");
  const nodeEnv = configService.getOrThrow<string>("app.nodeEnv");

  await app.listen(port);
  console.log(`Application running on port ${port} in ${nodeEnv} mode`);
}

bootstrap();
```

This is the cleanest way to read startup config such as the port.

---

## Part 9: Environment-Specific Behavior

A common pattern is to expose environment flags from the app namespace instead of scattering `process.env.NODE_ENV` checks throughout the codebase.

```typescript
export default registerAs("app", () => ({
  nodeEnv: process.env.NODE_ENV || "development",
  port: parseInt(process.env.PORT ?? "3000", 10),
  isDevelopment: process.env.NODE_ENV === "development",
  isProduction: process.env.NODE_ENV === "production",
}));
```

Then use it anywhere:

```typescript
const isDev = this.configService.get<boolean>("app.isDevelopment");

if (isDev) {
  // enable verbose diagnostics
}
```

Why this is better:

- the logic stays centralized
- services consume application config instead of raw env variables

---

## Part 10: Production Notes

### `.env` vs platform-provided env vars

In local development, `.env` files are convenient.

In production, many teams prefer:

- cloud provider env vars
- secret managers
- container orchestration secrets

When the platform provides env vars directly, `ignoreEnvFile: true` can prevent accidental reliance on local files.

### Do not log secrets

Avoid logging the full config object because it may include:

- database passwords
- JWT secrets
- API keys

### Keep `.env.example` accurate

A stale `.env.example` is almost as bad as missing documentation. It should list all required keys, even if values are blank.

---

## Quick File Map

| File | Purpose |
| --- | --- |
| `.env` | Local development values, not committed |
| `.env.example` | Template of required variables, committed |
| `config/config.validation.ts` | Joi schema for fail-fast validation |
| `config/app.config.ts` | App namespace values such as port and environment flags |
| `config/database.config.ts` | Database namespace values |
| `config/auth.config.ts` | Auth namespace values |
| `app.module.ts` | Config root registration and validation wiring |
| `main.ts` | Reads config from the DI container during bootstrap |

---

## Final Revision Anchors

If you only remember a few things, remember these:

- validate config during startup, not later
- group config into namespaces with `registerAs()`
- use `ConfigService` instead of raw `process.env` in app code
- prefer `getOrThrow()` for required values
- commit `.env.example`, not `.env`

For the startup order story, go to [3. NestJS Config Bootstrap Flow](./3_nestjs_config_bootstrap_flow.md). For quick recall, go to [4. Config Revision Cheatsheet](./4_config_revision_cheatsheet.md).

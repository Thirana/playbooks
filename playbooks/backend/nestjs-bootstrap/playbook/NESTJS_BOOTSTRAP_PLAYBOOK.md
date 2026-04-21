# NestJS Bootstrap Playbook

Use this file as the only reusable artifact.

Copy it into a brand-new empty directory, then tell a coding agent:

`Read NESTJS_BOOTSTRAP_PLAYBOOK.md and create the full project here.`

The agent must treat this file as the source of truth and generate the project
in the current directory.

---

## Goal

Create a minimal production-style NestJS HTTP API with:

- NestJS + npm
- Prisma + PostgreSQL
- ESLint
- Prettier
- EditorConfig
- TypeScript typecheck script
- Node version pinning
- Fail-fast env validation
- One structured Winston logger with environment-aware rendering
- Request ID propagation with `x-request-id`
- One global validation pipe with custom `exceptionFactory`
- One global exception filter
- One request logging interceptor
- URI versioning
- Swagger
- `GET /v1/health/live`
- `GET /v1/health/ready`
- Repo-local `AGENTS.md`
- Baseline tests and verification commands

Do not create reusable template repos, skill folders, or extra standards docs.
Create only the actual project in this directory.

---

## Non-Negotiables

- Use npm.
- Use Prisma with PostgreSQL.
- Use migration-based schema management. Do not use any auto-sync behavior.
- Use separate tools for quality:
  - ESLint for code-quality rules only
  - Prettier for formatting only
  - `eslint-config-prettier` to disable formatting-rule conflicts
- Do not use `eslint-plugin-prettier`.
- Do not surface formatting issues as ESLint findings.
- Generate `.editorconfig`, `.prettierrc`, `.prettierignore`, and `.nvmrc`.
- Pin Node using this precedence:
  - if the user provides a required Node version or org standard, use that
  - otherwise resolve the latest official Node.js LTS release from `nodejs.org`
    at generation time and pin that major version in `.nvmrc` and
    `package.json.engines`
- Use this dependency version strategy:
  - resolve dynamically at generation time only for Node LTS and the Nest CLI
    scaffolding command
  - do not query `latest` independently for normal runtime dependencies
  - keep Nest runtime packages on one compatible major family
  - treat `prisma` and `@prisma/client` as a paired dependency set
  - rely on `package-lock.json` to freeze exact resolved versions
- Use `bufferLogs: true` in Nest bootstrap.
- Use `WINSTON_MODULE_NEST_PROVIDER` with `app.useLogger(...)`.
- Use one Winston logger pipeline in every environment. Only the renderer changes.
- Render logs as pretty human-readable console output in local development.
- Render logs as structured JSON in production.
- Support `LOG_FORMAT=pretty|json` as an explicit override.
- Use `x-request-id` as the request ID header.
- Use one global `ValidationPipe` with a custom `exceptionFactory`.
- Do not enable global implicit request conversion.
- Register Swagger after `configureApp(...)` and before `app.listen(...)`.
- Exit with code `1` on bootstrap failure.
- All generated TypeScript must be compatible with strict mode (`strictNullChecks`, `noImplicitAny`, typed `catch` clauses using `unknown`).
- Keep the generated project minimal. Do not add business modules.

---

## Exact Scaffold Sequence

Run these steps in order.

### 1. Derive the project name

- Derive the package name from the current directory name.
- Normalize it:
  - convert to lowercase
  - replace spaces, underscores, and dots with hyphens
  - remove any characters that are not alphanumeric or hyphens
  - strip leading hyphens or digits
  - result must be valid as an npm package name and a PostgreSQL database name
- Use that normalized value for:
  - `package.json` `name`
  - the PostgreSQL database name in `.env.example` and `compose.yaml`
  - Winston `defaultMeta.service`

### 1a. Resolve the Node version

Before writing `.nvmrc` or `package.json` `engines`, resolve the Node version in
this order:

1. If the user already provided a Node version or organization standard, use
   that.
2. Otherwise, look up the latest official Node.js LTS release on `nodejs.org`
   and use its major version.

Use only official Node.js sources for this lookup:

- `https://nodejs.org/en/about/previous-releases`
- `https://nodejs.org/en/about/releases`

As of April 20, 2026, the latest official LTS listed there is `v24.15.0`, so
the current default major would be `24`. Do not hardcode this value from the
playbook; resolve it when generating the project unless the user supplied an
explicit version.

After resolving the version:

- write the major version to `.nvmrc`
- set `package.json.engines.node` to `>=<major> < <major+1>`

### 1b. Resolve the Nest CLI version

Before scaffolding the project, resolve the Nest CLI version in this order:

1. If the user or organization already requires a specific Nest CLI version, use
   that.
2. Otherwise, use the latest stable Nest CLI through `npx` at generation time.

Do not require a global Nest CLI install.

### 2. Scaffold NestJS in a temporary folder

The current directory is not truly empty because this playbook file is already
present. Do not scaffold directly into `.`.

Run:

```bash
npx @nestjs/cli@latest new __bootstrap_tmp__ --package-manager npm --strict --skip-git
```

If step `1b` resolved a specific Nest CLI version, replace `@latest` with that
version when running the scaffold command.

Then move the generated project into the current directory while preserving this
playbook file:

```bash
cp -r __bootstrap_tmp__/. ./
rm -rf __bootstrap_tmp__
```

Do not use `rsync` — it is not universally available.

After moving files:

- If the scaffold generated its own `eslint.config.mjs`, `.prettierrc`, or
  `.prettierignore`, **delete them** before writing the project versions
  described in this playbook. Do not merge or append — replace entirely.
- Preserve the scaffold's `tsconfig.json` and `tsconfig.build.json` as-is.
  Do not overwrite them unless there is a concrete compatibility issue.
- Preserve the scaffold's `nest-cli.json`. It must contain at minimum:
  ```json
  {
    "sourceRoot": "src",
    "compilerOptions": {
      "deleteOutDir": true
    }
  }
  ```
- Keep `NESTJS_BOOTSTRAP_PLAYBOOK.md` untouched.
- Do not re-scaffold if `package.json` already exists in the current directory.

### 3. Install the required packages

Install runtime dependencies:

```bash
npm install @nestjs/config @nestjs/swagger nest-winston winston @prisma/client
```

Install dev dependencies:

```bash
npm install -D prisma prettier eslint-config-prettier @eslint/js globals typescript-eslint
```

Keep the Nest scaffold's existing test, lint, and TypeScript dependencies unless
there is a concrete compatibility issue.

Dependency handling rules:

- Do not independently resolve `latest` for each runtime dependency.
- Keep the scaffold-generated Nest package family aligned on one compatible
  major version.
- Install `prisma` and `@prisma/client` as a pair in the same project setup.
- Let `package-lock.json` freeze the exact resolved versions.

If the Nest scaffold includes `eslint-plugin-prettier`, remove it from both
`package.json` and the ESLint config.

> **Note on `swagger-ui-express`:** Do not install `swagger-ui-express` manually.
> `@nestjs/swagger` bundles its own UI. Installing it separately may cause
> version conflicts. If the app fails to serve the Swagger UI after setup,
> install `swagger-ui-express` at that point and record the reason here.

### 3a. Standardize code-quality tooling

Update the generated project so:

- ESLint is responsible only for code quality and TypeScript rules.
- Prettier is responsible only for formatting.
- Formatting issues do not appear as ESLint findings.
- The agent may run `npm run format` and `npm run lint:fix` while generating the project.

### 4. Initialize Prisma

Run:

```bash
npx prisma init
```

Then replace the generated Prisma files with the project-specific versions
described in this playbook.

Do not run `npx prisma@latest init` or otherwise resolve Prisma separately at
execution time. Use the project-local Prisma CLI that was just installed.

### 5. Replace the default scaffold with the target runtime shape

- Replace the default controller, service, and module with the shared bootstrap
  structure described below.
- Remove the default `AppController`, `AppService`, and their spec files from
  the Nest scaffold.
- Keep the project focused on bootstrap and health only.

---

## Target Package Scripts

Ensure `package.json` contains exactly these scripts:

```json
{
  "build": "nest build",
  "db:up": "docker compose up -d",
  "db:down": "docker compose down",
  "db:reset": "docker compose down -v",
  "format": "prettier --write .",
  "format:check": "prettier --check .",
  "start": "nest start",
  "start:dev": "nest start --watch",
  "start:prod": "node dist/main",
  "lint": "eslint \"{src,test}/**/*.ts\"",
  "lint:fix": "eslint \"{src,test}/**/*.ts\" --fix",
  "test": "jest",
  "test:e2e": "jest --config ./test/jest-e2e.json",
  "typecheck": "tsc --noEmit",
  "prisma:generate": "prisma generate",
  "prisma:migrate:dev": "prisma migrate dev",
  "prisma:migrate:deploy": "prisma migrate deploy",
  "prisma:studio": "prisma studio"
}
```

Also set `package.json.engines.node` to the resolved major range.

If the resolved major is `24`, use:

```json
{
  "engines": {
    "node": ">=24 <25"
  }
}
```

---

## Required File Map

Create or replace the project so it contains this minimum structure:

```text
.
├── .env.example
├── .editorconfig
├── .nvmrc
├── .prettierignore
├── .prettierrc
├── AGENTS.md
├── README.md
├── compose.yaml
├── eslint.config.mjs
├── nest-cli.json
├── package.json
├── tsconfig.json
├── tsconfig.build.json
├── prisma/
│   └── schema.prisma
├── src/
│   ├── app.module.ts
│   ├── app.setup.ts
│   ├── main.ts
│   ├── swagger.setup.ts
│   ├── common/
│   │   ├── filters/
│   │   │   └── app-exception.filter.ts
│   │   ├── http/
│   │   │   ├── error-code.util.ts
│   │   │   ├── request-id.constants.ts
│   │   │   └── request.types.ts
│   │   ├── interceptors/
│   │   │   └── request-logging.interceptor.ts
│   │   ├── logging/
│   │   │   └── winston.config.ts
│   │   └── middlewares/
│   │       └── request-id.middleware.ts
│   ├── config/
│   │   ├── app.config.ts
│   │   ├── database.config.ts
│   │   ├── env.validation.ts
│   │   ├── index.ts
│   │   └── logging.config.ts
│   ├── modules/
│   │   └── health/
│   │       ├── controllers/health.controller.ts
│   │       ├── health.module.ts
│   │       └── services/health.service.ts
│   └── prisma/
│       ├── prisma.module.ts
│       └── prisma.service.ts
└── test/
    ├── app.e2e-spec.ts
    ├── bootstrap-failure.e2e-spec.ts
    ├── jest-e2e.json
    ├── jest.setup-env.ts
    ├── request-id.e2e-spec.ts
    └── support/http-response.helpers.ts
```

---

## Required Tooling Files

### `.editorconfig`

```ini
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
indent_style = space
indent_size = 2
trim_trailing_whitespace = true
```

### `.prettierrc`

```json
{
  "semi": true,
  "singleQuote": true,
  "trailingComma": "all"
}
```

### `.prettierignore`

```
dist
coverage
node_modules
prisma/generated
*.lock
```

### `.nvmrc`

Write the resolved Node major version from step `1a`, not a hardcoded value.

If the resolved major is `24`, the file should be:

```
24
```

### `package.json` engines

Set `package.json.engines.node` to match the resolved Node LTS major from step
`1a`.

If the resolved major is `24`, use:

```json
{
  "engines": {
    "node": ">=24 <25"
  }
}
```

### `eslint.config.mjs`

Delete any scaffold-generated `eslint.config.mjs` first, then create:

```js
// @ts-check
import eslint from "@eslint/js";
import tseslint from "typescript-eslint";
import globals from "globals";
import prettier from "eslint-config-prettier";

export default tseslint.config(
  {
    ignores: ["dist/**", "node_modules/**", "prisma/generated/**"],
  },
  eslint.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked,
  {
    languageOptions: {
      globals: { ...globals.node },
      parserOptions: {
        project: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
  },
  prettier,
);
```

Do not add `eslint-plugin-prettier`.

---

## Required Runtime Behavior

### `src/main.ts`

Bootstrap order must be exactly:

1. Create the Nest app with `bufferLogs: true`.
2. Call `configureApp(app)` — applies all global middleware, pipes, interceptors, and filters.
3. Resolve typed app config through Nest config injection: `app.get(appConfig.KEY)`.
4. Call `setupSwagger(app)` — registers Swagger docs.
5. Call `app.listen(port)`.
6. Log the running URL after listening.
7. In the `catch` block: log the error and call `process.exit(1)`.

```ts
// src/main.ts — pseudocode shape (agent must produce real typed code)
async function bootstrap() {
  const app = await NestFactory.create(AppModule, { bufferLogs: true });
  configureApp(app);
  const cfg = app.get(appConfig.KEY);
  setupSwagger(app);
  await app.listen(cfg.port);
  logger.log(`Application running on port ${cfg.port}`);
}

bootstrap().catch((err: unknown) => {
  // use a plain console.error here — the Nest logger may not be available
  console.error("Bootstrap failed", err);
  process.exit(1);
});
```

### `src/app.setup.ts`

Apply all shared runtime behavior in `configureApp(app)` in this exact order:

1. `app.useLogger(app.get(WINSTON_MODULE_NEST_PROVIDER))`
2. `app.enableVersioning({ type: VersioningType.URI })`
3. `app.use(requestIdMiddleware)` — raw Express middleware via `app.use(...)`
4. `app.useGlobalPipes(new ValidationPipe({ ... }))` — with custom `exceptionFactory`
5. `app.useGlobalInterceptors(new RequestLoggingInterceptor(...))`
6. `app.useGlobalFilters(new AppExceptionFilter(...))`
7. `app.enableShutdownHooks()`

Order is mandatory. Deviating from it causes request IDs to be unavailable
in interceptors or filters, and versioning to be applied incorrectly.

The `ValidationPipe` must be configured as:

```ts
new ValidationPipe({
  whitelist: true,
  forbidNonWhitelisted: true,
  transform: true,
  exceptionFactory: (errors) => {
    return new BadRequestException({
      message: errors.flatMap((e) => Object.values(e.constraints ?? {})),
      errorCode: "VALIDATION_ERROR",
    });
  },
});
```

Do not enable `transformOptions.enableImplicitConversion`.

### `src/app.module.ts`

Wire:

- `ConfigModule.forRoot({ isGlobal: true, cache: true, validate: validateEnv, load: [...] })`
- `WinstonModule.forRootAsync(...)` — use the `createLogger` factory pattern from `nest-winston`
- `PrismaModule`
- `HealthModule`

Use typed config factories from `src/config/index.ts`.

### `src/config/env.validation.ts`

Use `class-validator` and `class-transformer` to define a validated env class.

Rules:

- `PORT` — optional, defaults to `3000`, must be a valid port number
- `NODE_ENV` — optional, defaults to `development`, must be one of `development | test | production`
- `LOG_LEVEL` — optional, defaults to `info`, must be one of `error | warn | info | debug | verbose`
- `LOG_FORMAT` — optional, must be one of `pretty | json`. Default is conditional:
  use a `@Transform` decorator to set the default **before** `@IsIn` validates it:
  ```ts
  @Transform(({ value, obj }: { value: unknown; obj: Record<string, unknown> }) =>
    value ?? (obj['NODE_ENV'] === 'production' ? 'json' : 'pretty'),
  )
  @IsIn(['pretty', 'json'])
  LOG_FORMAT: 'pretty' | 'json';
  ```
- `DATABASE_URL` — required, must be a non-empty string

The `validateEnv` function must:

- use `plainToInstance` + `validateSync`
- collect all errors
- throw an `Error` listing every invalid field if there are any errors
- never silently ignore missing or invalid values

### `src/config/app.config.ts`

Expose: `port`, `nodeEnv`.

### `src/config/database.config.ts`

Expose: `url` (from `DATABASE_URL`).

### `src/config/logging.config.ts`

Expose: `level`, `format`.

### `src/config/index.ts`

Re-export all config factories for use in `AppModule` and `main.ts`.

---

## Required Common Utilities

### `src/common/http/request.types.ts`

Export a `RequestWithId` interface extending Express `Request` with a `requestId: string` field:

```ts
import type { Request } from "express";

export interface RequestWithId extends Request {
  requestId: string;
}
```

### `src/common/http/request-id.constants.ts`

Export the header name constant:

```ts
export const REQUEST_ID_HEADER = "x-request-id";
```

### `src/common/http/error-code.util.ts`

Export a `deriveErrorCode` utility that accepts an HTTP status code and an
optional error name string and returns a screaming-snake-case string error code.

Logic:

- If an explicit `errorCode` is already present, return it as-is.
- Otherwise map well-known status codes to a fixed string:
  - `400` → `BAD_REQUEST`
  - `401` → `UNAUTHORIZED`
  - `403` → `FORBIDDEN`
  - `404` → `NOT_FOUND`
  - `409` → `CONFLICT`
  - `422` → `UNPROCESSABLE_ENTITY`
  - `429` → `TOO_MANY_REQUESTS`
  - `503` → `SERVICE_UNAVAILABLE`
- For unmapped status codes, convert the error name (e.g. `InternalServerErrorException`)
  to screaming-snake-case, or fall back to `INTERNAL_ERROR`.

### `src/common/middlewares/request-id.middleware.ts`

- Preserve an incoming `x-request-id` header value if present and non-empty.
- Generate one with `crypto.randomUUID()` if absent.
- Attach it to the request object as `(req as RequestWithId).requestId`.
- Return it in the response header `x-request-id`.
- This is a plain Express middleware function, not a NestJS class middleware,
  so it can be passed directly to `app.use(...)`.

### `src/common/interceptors/request-logging.interceptor.ts`

Log on every completed or errored request:

```ts
{
  event: 'http.request',
  requestId: req.requestId,
  method: req.method,
  path: req.path,
  statusCode: response.statusCode,
  durationMs: Date.now() - startTime,
}
```

Log level selection:

- `>= 500` → `logger.error(...)`
- `>= 400` → `logger.warn(...)`
- all others → `logger.log(...)`

Always log a structured object. Never build a formatted string for the log message.

The interceptor must inject the NestJS logger (via `WINSTON_MODULE_NEST_PROVIDER`)
through the constructor so it is testable.

### `src/common/filters/app-exception.filter.ts`

Catch all exceptions and return a consistent JSON response body:

```json
{
  "statusCode": 400,
  "message": "...",
  "errorCode": "VALIDATION_ERROR",
  "requestId": "uuid",
  "timestamp": "ISO8601"
}
```

Implementation notes:

- Resolve `statusCode` from `HttpException` if applicable; default to `500`.
- Resolve `message` from the exception body or `exception.message`.
- Derive `errorCode` using `deriveErrorCode(...)` from `error-code.util.ts`.
- Extract `requestId` from `(request as RequestWithId).requestId`.
- Log every exception with `logger.error(...)` including the stack trace when available.
- For 5xx errors, log the full stack. For 4xx, log at `warn` level without stack.

---

## Prisma

### `prisma/schema.prisma`

```prisma
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}
```

Do not add business models.

### `src/prisma/prisma.service.ts`

- Extend `PrismaClient`.
- Implement `OnModuleInit`.
- Connect in `onModuleInit()`.
- Do not override `enableShutdownHooks` — `app.enableShutdownHooks()` in
  `app.setup.ts` is sufficient.
- Keep the service focused on Prisma lifecycle only.

### `src/prisma/prisma.module.ts`

- Declare and export `PrismaService`.
- Mark as `@Global()` so `PrismaService` is injectable across the app
  without re-importing `PrismaModule`.

---

## Health Module

### `src/modules/health/services/health.service.ts`

Implement two methods:

**`getLiveness()`**

Returns a static process-up payload:

```json
{ "status": "ok", "uptime": 123.45 }
```

**`getReadiness()`**

- Inject `PrismaService`.
- Execute a real database query: `prisma.$queryRaw\`SELECT 1\``.
- Catch **all** errors (not just Prisma-typed ones — network timeouts and
  connection refusals are plain `Error` instances):
  ```ts
  try {
    await this.prisma.$queryRaw`SELECT 1`;
    return { status: "ok", db: "reachable" };
  } catch (err: unknown) {
    throw new ServiceUnavailableException({
      message: "Database not reachable",
      errorCode: "DATABASE_NOT_READY",
    });
  }
  ```

### `src/modules/health/controllers/health.controller.ts`

Expose:

- `GET /v1/health/live` → calls `getLiveness()`
- `GET /v1/health/ready` → calls `getReadiness()`

Add Swagger decorators:

- `@ApiTags('health')`
- `@ApiOperation(...)` on each endpoint
- `@ApiOkResponse(...)` describing the success shape
- `@ApiServiceUnavailableResponse(...)` on the ready endpoint

### `src/modules/health/health.module.ts`

Import `PrismaModule` (or rely on it being global). Declare controller and service.

---

## Winston Logging

### `src/common/logging/winston.config.ts`

Configure one Winston logger pipeline. The `format` changes; the transport does not.

```ts
// Pseudocode shape — agent must produce real typed code

function buildWinstonConfig(
  level: string,
  format: "pretty" | "json",
  serviceName: string,
) {
  const jsonFormat = combine(timestamp(), errors({ stack: true }), json());

  const prettyFormat = combine(
    timestamp({ format: "HH:mm:ss" }),
    errors({ stack: true }),
    printf(({ timestamp, level, message, stack, ...meta }) => {
      const fields = [
        meta.event,
        meta.requestId,
        meta.method,
        meta.path,
        meta.statusCode != null ? String(meta.statusCode) : undefined,
        meta.durationMs != null ? `${String(meta.durationMs)}ms` : undefined,
      ]
        .filter(Boolean)
        .join(" ");
      const base = `${timestamp} [${level}] ${message}${fields ? " " + fields : ""}`;
      return stack ? `${base}\n${stack}` : base;
    }),
    colorize({ all: true }),
  );

  return {
    level,
    defaultMeta: { service: serviceName },
    format: format === "json" ? jsonFormat : prettyFormat,
    transports: [new transports.Console()],
  };
}
```

Rules:

- Use console transports only.
- Keep application log calls structured in every environment.
- Do not use `console.log` anywhere in application code.
- The service name in `defaultMeta` must be the normalized project name derived
  in Step 1.

---

## Swagger

### `src/swagger.setup.ts`

```ts
// Pseudocode shape
export function setupSwagger(app: INestApplication): void {
  const config = new DocumentBuilder()
    .setTitle("<project-name>")
    .setDescription("API documentation")
    .setVersion("1")
    .addTag("health")
    .build();

  const document = SwaggerModule.createDocument(app, config);
  SwaggerModule.setup("api", app, document);
}
```

- Replace `<project-name>` with the normalized project name.
- Call this in `main.ts` after `configureApp(app)` and before `app.listen(...)`.
- Swagger UI will be available at `/api`.

---

## Required Environment Files

### `.env.example`

```dotenv
PORT=3000
NODE_ENV=development
LOG_LEVEL=info
LOG_FORMAT=pretty
DATABASE_URL="postgresql://postgres:postgres@localhost:5432/<project-name>?schema=public"
```

Replace `<project-name>` with the normalized directory-derived project name.

### `compose.yaml`

```yaml
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: <project-name>
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d <project-name>"]
      interval: 5s
      timeout: 5s
      retries: 5
    volumes:
      - postgres_data:/var/lib/postgresql/data

volumes:
  postgres_data:
```

Replace `<project-name>` with the normalized project name.

---

## Required Tests

### Jest configuration — wiring `jest.setup-env.ts`

In `package.json`, add `setupFiles` to the Jest config block:

```json
{
  "jest": {
    "setupFiles": ["./test/jest.setup-env.ts"]
  }
}
```

In `test/jest-e2e.json`, add the same:

```json
{
  "setupFiles": ["./test/jest.setup-env.ts"]
}
```

This is required. Without it, `validateEnv` will throw on missing `DATABASE_URL`
before any test runs.

### `test/jest.setup-env.ts`

Set test defaults so the app can bootstrap without a real environment:

```ts
process.env["PORT"] = "3001";
process.env["NODE_ENV"] = "test";
process.env["LOG_LEVEL"] = "error";
process.env["LOG_FORMAT"] = "json";
process.env["DATABASE_URL"] =
  "postgresql://postgres:postgres@localhost:5432/test";
```

Use port `3001` for tests to avoid colliding with a running dev server.

### `test/app.e2e-spec.ts`

Verify:

- `GET /v1/health/live` returns `200` with `{ status: 'ok', uptime: <number> }`
- `GET /v1/health/ready` returns `200` with `{ status: 'ok', db: 'reachable' }` (requires live DB)
- A request to an unknown route returns `404` with the standardized error shape:
  `{ statusCode, message, errorCode, requestId, timestamp }`

### `test/request-id.e2e-spec.ts`

Verify:

- A request that includes `x-request-id: test-id-123` receives the same value
  back in the response `x-request-id` header on a successful response.
- A request that includes `x-request-id: test-id-456` receives the same value
  back in the response `x-request-id` header on an error response (e.g. unknown route).
- The error body `requestId` field equals the value sent in the request header.

### `test/bootstrap-failure.e2e-spec.ts`

Testing `process.exit(1)` in-process is unreliable. Use a child process pattern instead:

```ts
import { execSync } from "child_process";

it("exits with code 1 when DATABASE_URL is missing", () => {
  let exitCode: number | null = null;
  let output = "";

  try {
    output = execSync("node -e \"require('./dist/main')\"", {
      env: {
        ...process.env,
        DATABASE_URL: undefined,
        NODE_ENV: "production",
      },
      encoding: "utf8",
      stdio: "pipe",
    });
  } catch (err: unknown) {
    const e = err as { status?: number; stderr?: string; stdout?: string };
    exitCode = e.status ?? null;
    output = (e.stderr ?? "") + (e.stdout ?? "");
  }

  expect(exitCode).toBe(1);
  expect(output).toMatch(/DATABASE_URL/i);
});
```

This test requires a successful `npm run build` beforehand. Document this prerequisite
in the test file with a comment.

### `test/support/http-response.helpers.ts`

Export helper functions used across e2e tests:

```ts
export function expectStandardErrorShape(body: Record<string, unknown>): void {
  expect(body).toHaveProperty("statusCode");
  expect(body).toHaveProperty("message");
  expect(body).toHaveProperty("errorCode");
  expect(body).toHaveProperty("requestId");
  expect(body).toHaveProperty("timestamp");
}
```

### Mocking Prisma in unit tests

Unit tests must not connect to a real database.

Use `jest.mock` or NestJS `overrideProvider` to replace `PrismaService`:

```ts
// In unit test files that involve health.service.ts
const mockPrisma = {
  $queryRaw: jest.fn().mockResolvedValue([{ "?column?": 1 }]),
};

// In TestingModule:
providers: [HealthService, { provide: PrismaService, useValue: mockPrisma }];
```

E2E tests use a live database. Never mock Prisma in e2e specs.

---

## Required README

Keep `README.md` short and operational. Include:

- What the project is (minimal NestJS + Prisma bootstrap, not a full app)
- Local setup steps:
  1. Copy `.env.example` to `.env` and fill in values
  2. `npm run db:up`
  3. `npm run prisma:migrate:dev`
  4. `npm run start:dev`
- Prisma commands: `prisma:generate`, `prisma:migrate:dev`, `prisma:migrate:deploy`, `prisma:studio`
- Docker commands: `db:up`, `db:down`, `db:reset`
- Logging behavior: `LOG_FORMAT=pretty` in development, `LOG_FORMAT=json` in production
- Quality tooling commands:
  - `npm run lint`
  - `npm run lint:fix`
  - `npm run format`
  - `npm run format:check`
  - `npm run typecheck`
- Verification commands (see below)
- Swagger location: `http://localhost:3000/api`

State clearly that this project is production-ready in the sense of baseline runtime
and code-quality discipline, not full release engineering automation.

Do not restate the full bootstrap playbook in the README.

---

## Exact Generated `AGENTS.md`

Create a short repo-local `AGENTS.md`:

```md
# Project Agent Guide

Use the existing bootstrap runtime shape as the default operating model for this repo.

## Local Deltas

- DB adapter: Prisma with PostgreSQL
- Swagger: enabled at `/api`
- Readiness target: PostgreSQL via Prisma (`SELECT 1`)
- Local logging: `LOG_FORMAT=pretty`
- Production logging: `LOG_FORMAT=json`
- Formatting: Prettier
- Linting: ESLint (code quality only, no formatting rules)

## Required Verification Commands

Run in this order before marking any task complete:

1. `npm run format:check`
2. `npm run lint`
3. `npm run typecheck`
4. `npm run build`
5. `npm test -- --runInBand`
6. `npm run test:e2e -- --runInBand`

## Rules

- Preserve the shared bootstrap behavior unless explicitly asked to change it.
- Keep business modules and domain rules out of the shared bootstrap layer.
- Do not introduce auto-sync database behavior.
- Do not enable global implicit request conversion.
- All TypeScript must be strict-mode compatible. Use `unknown` in `catch` clauses.
- Do not use `console.log` in application code — use the injected logger.
- Add project-specific notes below this line when they appear.
```

---

## Verification Commands

After generating all files, run these commands in order and report results:

```bash
npm install
npm run prisma:generate
npm run db:up          # requires Docker
npm run format:check
npm run lint
npm run typecheck
npm run build
npm test -- --runInBand
npm run test:e2e -- --runInBand
```

If Docker is unavailable:

- Skip `db:up`, `test:e2e`, and the readiness test in `app.e2e-spec.ts`.
- Complete and report all other steps.
- Note clearly that database-backed verification could not be completed.

Also verify by code inspection:

- The app uses one Winston pipeline in all environments.
- `LOG_FORMAT=pretty` produces colorized, readable console output.
- `LOG_FORMAT=json` produces structured JSON output.
- Application code always logs structured objects — no hand-built log strings.
- ESLint and Prettier are wired as separate tools with no overlap.
- `ValidationPipe` uses the custom `exceptionFactory` returning `errorCode: 'VALIDATION_ERROR'`.
- `getReadiness()` catches all errors and throws `ServiceUnavailableException`.
- `configureApp(...)` applies middleware and pipes in the specified order.
- `jest.setup-env.ts` is referenced in both `package.json` jest config and `jest-e2e.json`.
- The file map matches the structure above.
- `AGENTS.md` and `README.md` include the required quality commands.

---

## CI Guidance

Recommend, but do not generate by default, a minimal GitHub Actions workflow that runs:

```bash
npm ci
npm run format:check
npm run lint
npm run typecheck
npm run build
npm test -- --runInBand
npm run test:e2e -- --runInBand
```

Do not generate `.github/workflows/*` unless the user explicitly asks.

---

## Anti-Patterns

Do not do any of the following:

- Mix multiple app-wide logger stacks or use `console.log` for runtime behavior
- Fork logging into different app-level codepaths per environment
- Combine ESLint and Prettier into one enforcement path via `eslint-plugin-prettier`
- Surface formatting violations as ESLint errors
- Implement readiness as a static success response (it must query the DB)
- Catch only typed Prisma errors in `getReadiness()` — catch all errors
- Hardcode secrets or commit `.env`
- Enable global implicit request conversion
- Add Prisma auto-sync or any ORM sync shortcut
- Apply `configureApp(...)` steps in a different order than specified
- Install `swagger-ui-express` unless `@nestjs/swagger` fails to serve the UI
- Add Husky, lint-staged, commitlint, VS Code workspace files, or generated CI files by default
- Create extra reusable artifacts such as starter repos, skills, or standards folders
- Use `rsync` for file operations (not universally available)

---

## Completion Criteria

The work is complete only when:

- The project exists in the current directory with the full required file map
- NestJS + Prisma + PostgreSQL are wired and functional
- Only health and bootstrap infrastructure exist — no business modules
- `configureApp(...)` applies all setup steps in the specified order
- `ValidationPipe` uses the custom `exceptionFactory`
- `getReadiness()` catches all errors and throws `ServiceUnavailableException`
- `jest.setup-env.ts` is referenced in both jest configs
- `AGENTS.md` exists with required content
- All required test files exist
- Verification commands were run and results were reported (or blockers clearly noted)
- This playbook file remains intact

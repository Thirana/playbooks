# NestJS Swagger / OpenAPI

### Study Notes — Interview Ready

---

## The Developer Requirement

The TaskFlow API team has grown. A frontend developer joins and asks: "Where is the API documentation? How do I know what endpoints exist, what to send in the request body, and what the response looks like?" A mobile developer joins a week later and asks the same question.

Currently the only documentation is a Postman collection that was created six months ago and has not been updated since. It shows the wrong field names for three endpoints and is missing the entire tasks API.

The requirements are:

- Every API endpoint must be documented automatically — the documentation must always reflect the actual code, never drift from it.
- The Swagger UI must be accessible only in development and staging — never in production.
- Protected endpoints must show a lock icon and allow testers to authenticate from the UI using a JWT.
- Request body schemas, response shapes, and all possible HTTP status codes must be visible per endpoint.
- The raw OpenAPI JSON spec must be exportable so the frontend team can generate a typed API client automatically.

---

## Part 1: Core Concepts

### What is OpenAPI?

The OpenAPI specification (formerly Swagger) is a language-agnostic, machine-readable definition format for describing RESTful APIs. It defines the structure of every endpoint — its path, HTTP method, parameters, request body shape, response shapes, authentication requirements, and possible status codes — all in a single JSON or YAML document.

Tools can consume this document to auto-generate interactive UIs (Swagger UI), typed API clients (for React, Flutter, etc.), mock servers, and test suites.

### What is Swagger UI?

Swagger UI is the browser-based interface that reads an OpenAPI document and renders it as interactive documentation. Developers can browse all endpoints, see the expected request/response shapes, and make live API calls directly from the browser — no Postman needed.

### How `@nestjs/swagger` Works

NestJS provides the `@nestjs/swagger` package which uses TypeScript reflection and decorators to generate an OpenAPI document automatically. It scans your controllers and DTOs at startup, reads `@Body()`, `@Param()`, `@Query()` decorators, and builds the spec from your code.

The key insight is that your code becomes the source of truth for documentation. When you add a new field to a DTO, the swagger doc updates automatically. When you add a new endpoint, it appears in the UI immediately.

### What `@nestjs/swagger` Can Infer Automatically

- Route paths and HTTP methods from `@Get()`, `@Post()`, etc.
- Path parameters from `@Param('id')`
- Query parameters from `@Query()`
- Request body class from `@Body()`
- Response type from the method's return type annotation

### What You Must Add Manually

- Property descriptions, examples, and type hints on DTO fields using `@ApiProperty()`
- Response shapes and status codes using `@ApiResponse()` decorators
- Authentication requirements using `@ApiBearerAuth()`
- Grouping via `@ApiTags()`

---

## Part 2: Project Setup

### Install

```bash
npm install --save @nestjs/swagger
```

### File Structure

```
src/
  main.ts              # SwaggerModule setup lives here
  auth/
    dto/
      register.dto.ts  # @ApiProperty() on every field
      login.dto.ts
  tasks/
    dto/
      create-task.dto.ts
      task-response.dto.ts
  users/
    dto/
      user-response.dto.ts
```

---

## Part 3: Bootstrap — Setting Up Swagger in main.ts

The entire Swagger setup happens in `main.ts` using `DocumentBuilder` and `SwaggerModule`. The key production practice is to only enable it in non-production environments.

**`src/main.ts`**

```typescript
import { NestFactory } from "@nestjs/core";
import { SwaggerModule, DocumentBuilder } from "@nestjs/swagger";
import { ConfigService } from "@nestjs/config";
import { AppModule } from "./app.module";

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  const configService = app.get(ConfigService);
  const nodeEnv = configService.get<string>("NODE_ENV", "development");

  // Only mount Swagger UI in development and staging.
  // In production, the UI is not served — it would expose your full API surface
  // to attackers and consume server resources unnecessarily.
  if (nodeEnv !== "production") {
    // DocumentBuilder constructs the top-level metadata of the OpenAPI document.
    const config = new DocumentBuilder()
      .setTitle("TaskFlow API") // Shown as the page title in Swagger UI
      .setDescription("Task management REST API") // Shown as the description
      .setVersion("1.0") // API version
      .setContact("TaskFlow Team", "", "dev@taskflow.com")

      // addBearerAuth adds a JWT authentication scheme to the document.
      // This is what makes the "Authorize" button appear in the Swagger UI,
      // allowing testers to paste a JWT and test protected endpoints.
      .addBearerAuth(
        {
          type: "http",
          scheme: "bearer",
          bearerFormat: "JWT",
          description: "Enter JWT token from POST /auth/login",
        },
        "access-token", // The name of this security scheme — referenced by @ApiBearerAuth()
      )

      // addServer tells the UI which base URL to send requests to.
      // Useful when the API is deployed at a different URL than where docs are served.
      .addServer("http://localhost:3000", "Local development")
      .addServer("https://api.staging.taskflow.com", "Staging")

      // addTag creates a global tag group — controllers can be grouped under these.
      // Controllers can also auto-create their own tags via @ApiTags().
      .addTag("auth", "Authentication and registration")
      .addTag("tasks", "Task management")
      .addTag("users", "User management")

      .build();

    // SwaggerModule.createDocument() scans the entire app and builds the OpenAPI document.
    // The factory pattern means the document is only generated when first requested —
    // not at startup, which saves boot time.
    const documentFactory = () =>
      SwaggerModule.createDocument(app, config, {
        // operationIdFactory generates the unique ID for each operation in the spec.
        // By default it produces 'TasksController_findAll'.
        // This setting produces just 'findAll' — cleaner for client code generation.
        operationIdFactory: (controllerKey, methodKey) => methodKey,
      });

    // SwaggerModule.setup() mounts the Swagger UI at the specified path.
    // /api-docs → Swagger UI browser interface
    // /api-docs-json → raw OpenAPI JSON (shareable with frontend team)
    // /api-docs-yaml → raw OpenAPI YAML
    SwaggerModule.setup("api-docs", app, documentFactory, {
      jsonDocumentUrl: "api-docs/json", // http://localhost:3000/api-docs/json
      yamlDocumentUrl: "api-docs/yaml", // http://localhost:3000/api-docs/yaml

      swaggerOptions: {
        // persistAuthorization: true means the JWT you enter in "Authorize"
        // is remembered across page refreshes — very convenient for testing.
        persistAuthorization: true,
        // docExpansion: 'none' collapses all endpoints by default — cleaner UI
        // for large APIs with many endpoints.
        docExpansion: "none",
        // filter: true adds a search box to filter endpoints by tag or path.
        filter: true,
      },
    });
  }

  await app.listen(3000);
}
bootstrap();
```

---

## Part 4: Documenting DTOs with @ApiProperty

`@nestjs/swagger` cannot read TypeScript types at runtime without the CLI plugin. You must annotate each DTO property with `@ApiProperty()` to make its type, description, and example appear in the Swagger UI.

### Registration DTO

**`src/auth/dto/register.dto.ts`**

```typescript
import { ApiProperty, ApiPropertyOptional } from "@nestjs/swagger";
import { IsEmail, IsString, MinLength, IsOptional } from "class-validator";

export class RegisterDto {
  // @ApiProperty() tells the Swagger module this field exists and documents it.
  // Without it, the field is invisible in the Swagger UI schema.
  @ApiProperty({
    description: "User email address",
    example: "jane@taskflow.com", // Shows as the example value in the UI
    format: "email",
  })
  @IsEmail()
  email: string;

  @ApiProperty({
    description:
      "Password — min 8 characters, must include uppercase, lowercase, and number",
    example: "SecurePass1",
    minLength: 8,
  })
  @IsString()
  @MinLength(8)
  password: string;

  // @ApiPropertyOptional is shorthand for @ApiProperty({ required: false }).
  // Use it for optional fields to avoid writing required: false every time.
  @ApiPropertyOptional({
    description: "Display name",
    example: "Jane Smith",
  })
  @IsOptional()
  @IsString()
  name?: string;
}
```

### Create Task DTO — Enums, Arrays, Nested Objects

**`src/tasks/dto/create-task.dto.ts`**

```typescript
import { ApiProperty, ApiPropertyOptional } from "@nestjs/swagger";
import {
  IsString,
  IsNotEmpty,
  IsOptional,
  IsEnum,
  IsArray,
  ValidateNested,
} from "class-validator";
import { Type } from "class-transformer";
import { TaskStatus } from "../task.entity";

export class LabelDto {
  @ApiProperty({ example: "bug", description: "Label name" })
  @IsString()
  @IsNotEmpty()
  name: string;
}

export class CreateTaskDto {
  @ApiProperty({
    description: "Task title",
    example: "Fix login bug",
  })
  @IsString()
  @IsNotEmpty()
  title: string;

  @ApiPropertyOptional({
    description: "Detailed task description",
    example: "The login endpoint returns 500 when email is missing",
  })
  @IsOptional()
  @IsString()
  description?: string;

  // For enum fields, pass the enum object to @ApiProperty.
  // Swagger UI will render a dropdown with the allowed values.
  @ApiPropertyOptional({
    description: "Initial task status",
    enum: TaskStatus, // Shows all enum values as options in the UI
    default: TaskStatus.OPEN,
  })
  @IsOptional()
  @IsEnum(TaskStatus)
  status?: TaskStatus;

  // For arrays of primitives, wrap the type in an array: [String]
  @ApiPropertyOptional({
    description: "Tags for filtering",
    type: [String], // Tells Swagger this is an array of strings
    example: ["frontend", "urgent"],
  })
  @IsOptional()
  @IsArray()
  @IsString({ each: true })
  tags?: string[];

  // For arrays of nested objects, use type and isArray together.
  @ApiPropertyOptional({
    description: "Labels to attach to the task",
    type: [LabelDto], // Swagger will render LabelDto's schema inline
  })
  @IsOptional()
  @IsArray()
  @ValidateNested({ each: true })
  @Type(() => LabelDto)
  labels?: LabelDto[];
}
```

### Response DTO — Documenting Outgoing Shape

**`src/users/dto/user-response.dto.ts`**

```typescript
import { ApiProperty } from "@nestjs/swagger";

// A response DTO documents what the API sends back.
// Using this as the 'type' in @ApiOkResponse() makes the response
// schema appear in Swagger UI with all its fields and types.
export class UserResponseDto {
  @ApiProperty({ example: 1 })
  id: number;

  @ApiProperty({ example: "jane@taskflow.com" })
  email: string;

  @ApiProperty({ example: "user", enum: ["user", "admin"] })
  role: string;

  @ApiProperty({ example: "2025-01-15T10:30:00.000Z" })
  createdAt: Date;

  // The password field intentionally has NO @ApiProperty.
  // It will never appear in the documented response schema —
  // a good reminder that it is always excluded by serialization.
}
```

---

## Part 5: Documenting Controllers

### Tagging and Grouping — @ApiTags

`@ApiTags()` groups all routes in a controller under a labelled section in the Swagger UI. Without it, all endpoints appear in a flat "default" group.

### Documenting Responses — @ApiResponse Shorthand Decorators

Every route should declare its possible response status codes. This tells API consumers what to expect and is used by client code generators.

### JWT Authentication — @ApiBearerAuth

`@ApiBearerAuth('access-token')` marks an endpoint as requiring a JWT. In the Swagger UI, a lock icon appears on the endpoint and it uses the token entered in the global "Authorize" dialog.

**`src/tasks/tasks.controller.ts`**

```typescript
import {
  Controller,
  Get,
  Post,
  Patch,
  Delete,
  Body,
  Param,
  Query,
  Request,
  UseGuards,
} from "@nestjs/common";
import {
  ApiTags,
  ApiBearerAuth,
  ApiOperation,
  ApiOkResponse,
  ApiCreatedResponse,
  ApiNoContentResponse,
  ApiUnauthorizedResponse,
  ApiNotFoundResponse,
  ApiBadRequestResponse,
  ApiTooManyRequestsResponse,
  ApiQuery,
  ApiParam,
} from "@nestjs/swagger";
import { JwtAuthGuard } from "../auth/jwt-auth.guard";
import { TasksService } from "./tasks.service";
import { CreateTaskDto } from "./dto/create-task.dto";
import { TaskResponseDto } from "./dto/task-response.dto";
import { TaskStatus } from "./task.entity";

// @ApiTags groups all routes in this controller under "tasks" in the Swagger UI
@ApiTags("tasks")
// @ApiBearerAuth('access-token') marks all routes in this controller as requiring
// the JWT scheme named 'access-token' (defined in DocumentBuilder.addBearerAuth).
// A lock icon appears on each endpoint in the Swagger UI.
@ApiBearerAuth("access-token")
@UseGuards(JwtAuthGuard)
@Controller("tasks")
export class TasksController {
  constructor(private readonly tasksService: TasksService) {}

  // GET /tasks
  @Get()
  // @ApiOperation provides a human-readable summary and description for the endpoint.
  // The summary appears as the endpoint title in the collapsed view.
  @ApiOperation({
    summary: "List all tasks for the authenticated user",
    description:
      "Returns tasks sorted by creation date descending. Supports filtering by status and keyword search.",
  })
  // @ApiQuery documents query string parameters.
  // For params that come from @Query() on a primitive type (not a DTO class),
  // you must document them manually with @ApiQuery.
  @ApiQuery({
    name: "status",
    enum: TaskStatus,
    required: false,
    description: "Filter by task status",
  })
  @ApiQuery({
    name: "search",
    required: false,
    description: "Keyword search on title",
  })
  @ApiQuery({ name: "page", required: false, type: Number, example: 1 })
  @ApiQuery({ name: "limit", required: false, type: Number, example: 20 })
  // @ApiOkResponse documents the successful response shape.
  // type: [TaskResponseDto] means the response is an array of TaskResponseDto.
  @ApiOkResponse({ description: "List of tasks", type: [TaskResponseDto] })
  @ApiUnauthorizedResponse({ description: "Missing or invalid JWT token" })
  async findAll(@Request() req, @Query() query: any) {
    return this.tasksService.findAllForUser(req.user.userId);
  }

  // GET /tasks/:id
  @Get(":id")
  @ApiOperation({ summary: "Get a single task by ID" })
  // @ApiParam documents path parameters.
  @ApiParam({ name: "id", type: Number, description: "Task ID", example: 42 })
  @ApiOkResponse({ description: "The task", type: TaskResponseDto })
  @ApiNotFoundResponse({ description: "Task not found" })
  @ApiUnauthorizedResponse({ description: "Missing or invalid JWT token" })
  async findOne(@Request() req, @Param("id") id: number) {
    return this.tasksService.findOne(id, req.user.userId);
  }

  // POST /tasks
  @Post()
  @ApiOperation({ summary: "Create a new task" })
  // @ApiCreatedResponse is shorthand for @ApiResponse({ status: 201, ... })
  @ApiCreatedResponse({
    description: "Task created successfully",
    type: TaskResponseDto,
  })
  @ApiBadRequestResponse({
    description: "Validation failed — check request body",
  })
  @ApiUnauthorizedResponse({ description: "Missing or invalid JWT token" })
  @ApiTooManyRequestsResponse({ description: "Rate limit exceeded" })
  async create(@Request() req, @Body() dto: CreateTaskDto) {
    return this.tasksService.createTask(
      req.user.userId,
      dto.title,
      dto.description,
      dto.labels?.map((l) => l.name) ?? [],
    );
  }

  // DELETE /tasks/:id
  @Delete(":id")
  @ApiOperation({ summary: "Delete a task" })
  @ApiParam({ name: "id", type: Number, description: "Task ID to delete" })
  // @ApiNoContentResponse documents a 204 response (no body returned).
  @ApiNoContentResponse({ description: "Task deleted successfully" })
  @ApiNotFoundResponse({ description: "Task not found" })
  @ApiUnauthorizedResponse({ description: "Missing or invalid JWT token" })
  async remove(@Request() req, @Param("id") id: number) {
    return this.tasksService.deleteTask(id, req.user.userId);
  }
}
```

### Auth Controller — Documenting Public Endpoints

**`src/auth/auth.controller.ts`**

```typescript
import {
  Controller,
  Post,
  Body,
  UseGuards,
  Request,
  HttpCode,
  HttpStatus,
} from "@nestjs/common";
import {
  ApiTags,
  ApiOperation,
  ApiCreatedResponse,
  ApiOkResponse,
  ApiUnauthorizedResponse,
  ApiBadRequestResponse,
  ApiConflictResponse,
  ApiBody,
} from "@nestjs/swagger";
import { RegisterDto } from "./dto/register.dto";
import { LoginDto } from "./dto/login.dto";

@ApiTags("auth")
@Controller("auth")
export class AuthController {
  @Post("register")
  @ApiOperation({ summary: "Register a new user account" })
  // @ApiBody is used when you want to explicitly reference a DTO as the request body.
  // For @Body() params, SwaggerModule infers this automatically from the parameter type,
  // so @ApiBody is optional here — but useful for adding a description.
  @ApiBody({ type: RegisterDto, description: "User registration data" })
  @ApiCreatedResponse({ description: "User registered successfully" })
  @ApiBadRequestResponse({ description: "Validation failed" })
  @ApiConflictResponse({ description: "Email already in use" })
  async register(@Body() dto: RegisterDto) {
    return this.authService.register(dto.email, dto.password);
  }

  @Post("login")
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: "Login and receive a JWT access token",
    description:
      "Submit email and password. Returns a bearer token to use in the Authorization header.",
  })
  @ApiBody({ type: LoginDto })
  @ApiOkResponse({
    description: "Login successful",
    schema: {
      // For responses that do not map to a DTO class, use schema to define inline
      type: "object",
      properties: {
        access_token: {
          type: "string",
          example: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
        },
      },
    },
  })
  @ApiUnauthorizedResponse({ description: "Invalid email or password" })
  async login(@Request() req) {
    return this.authService.login(req.user);
  }
}
```

---

## Part 6: The CLI Plugin — Eliminating Boilerplate

Manually adding `@ApiProperty()` to every DTO field is repetitive. The `@nestjs/swagger` CLI plugin automates this — it reads TypeScript type information at compile time and infers `@ApiProperty()` metadata automatically.

### Enable the Plugin in nest-cli.json

**`nest-cli.json`**

```json
{
  "collection": "@nestjs/schematics",
  "sourceRoot": "src",
  "compilerOptions": {
    "plugins": [
      {
        "name": "@nestjs/swagger",
        "options": {
          // introspectComments: true reads JSDoc comments from your DTO properties
          // and uses them as the Swagger description automatically.
          "introspectComments": true,

          // classValidatorShim: true syncs class-validator constraints to Swagger.
          // @MinLength(8) on a property also sets minLength: 8 in the OpenAPI schema.
          "classValidatorShim": true,

          // dtoFileNameSuffix limits the plugin to files ending with .dto.ts or .entity.ts
          // to avoid accidentally processing non-DTO files.
          "dtoFileNameSuffix": [".dto.ts", ".entity.ts"]
        }
      }
    ]
  }
}
```

### What You Can Remove After Enabling the Plugin

Before plugin:

```typescript
export class CreateTaskDto {
  @ApiProperty({ description: "Task title", example: "Fix bug" })
  @IsString()
  @IsNotEmpty()
  title: string;
}
```

After plugin (the `@ApiProperty()` is no longer needed for basic types):

```typescript
export class CreateTaskDto {
  /** Task title — the main heading of the task */ // JSDoc becomes the description
  @IsString()
  @IsNotEmpty()
  title: string;
  // @ApiProperty() is inferred automatically from the TypeScript type and JSDoc comment
}
```

**Key Interview Point**: The CLI plugin is a compile-time transformation, not a runtime decorator. It modifies the emitted JavaScript to inject the metadata that `@ApiProperty()` would have added. The source `.ts` file stays clean. You still need `@ApiProperty()` for complex options like `enum`, `type: [String]` (arrays), or custom `example` values that cannot be inferred from the TypeScript type alone.

---

## Part 7: Production Safety — Disabling Swagger in Production

There are two levels of protection to apply in production.

### Level 1 — Conditional Setup in main.ts (already shown in Part 3)

Wrapping the entire `SwaggerModule.setup()` block in a `NODE_ENV !== 'production'` check ensures the UI and JSON endpoints are never mounted in production.

### Level 2 — Disabling JSON and YAML Endpoints Separately

If you want the UI in staging but not the raw JSON (to prevent automated scraping of your API schema):

```typescript
SwaggerModule.setup("api-docs", app, documentFactory, {
  // ui: true — Swagger UI is accessible
  ui: true,
  // raw: false — /api-docs-json and /api-docs-yaml are NOT served
  raw: false,
});
```

Or to serve only the JSON for client generation tools but not the UI:

```typescript
SwaggerModule.setup("api-docs", app, documentFactory, {
  ui: false, // No browser UI
  raw: ["json"], // Only /api-docs-json is served
});
```

---

## Part 8: The Complete Interview Story

### How the Documentation is Generated

1. The app starts. `NestFactory.create(AppModule)` bootstraps the full module graph.
2. `DocumentBuilder` constructs the top-level metadata: title, version, bearer auth scheme.
3. `SwaggerModule.createDocument()` uses TypeScript reflection to scan every controller. For each route, it reads the HTTP method, path, `@Body()`/`@Param()`/`@Query()` types, and all `@Api*()` decorators.
4. It builds the OpenAPI document — a large JSON object conforming to the OpenAPI 3.0 specification.
5. `SwaggerModule.setup('api-docs', app, documentFactory)` mounts the Swagger UI at `/api-docs` and the raw JSON at `/api-docs/json`.

### How a Developer Uses It

1. Developer opens `http://localhost:3000/api-docs`.
2. They click "Authorize" and paste a JWT from `POST /auth/login`.
3. They navigate to `GET /tasks`, click "Try it out", and click "Execute".
4. The request is sent with the Authorization header. The response body and status appear inline.
5. They click the `GET /tasks` schema section and see the full `TaskResponseDto` property list with types, examples, and descriptions.

### How the Frontend Team Uses the JSON

1. Developer navigates to `http://localhost:3000/api-docs/json`.
2. They save the JSON file or point a code generator (like openapi-generator or orval) at the URL.
3. The generator creates a fully typed TypeScript API client with all the DTOs as interfaces.
4. The frontend team imports the client — no manual type definitions needed.

---

## Part 9: Production Checklist & Interview Points

**Best practices:**

- Always guard `SwaggerModule.setup()` behind a `NODE_ENV !== 'production'` check. Exposing the full API surface in production is an information disclosure risk.
- Always call `.addBearerAuth()` in `DocumentBuilder` if your API uses JWT. Without it, the "Authorize" button does not appear and testers cannot authenticate from the UI.
- Always add `@ApiBearerAuth('access-token')` to every controller or route that has `@UseGuards(JwtAuthGuard)`. Without this, the endpoint appears as unlocked in the UI even though it requires authentication.
- Always document at least the success response and the 401/400 responses on every endpoint using `@ApiOkResponse`, `@ApiCreatedResponse`, `@ApiUnauthorizedResponse`, and `@ApiBadRequestResponse`. Incomplete response docs make the UI misleading.
- Use the CLI plugin (`@nestjs/swagger` plugin in `nest-cli.json`) to eliminate boilerplate `@ApiProperty()` decorators. Use `introspectComments: true` to drive descriptions from JSDoc comments.
- Set `persistAuthorization: true` in `swaggerOptions` so the JWT is not lost on page refresh during development.
- Export the OpenAPI JSON spec and commit it to version control. This creates a diff history of API changes and can be used to detect breaking changes in CI.

**Common interview questions:**

Q: What is the difference between OpenAPI and Swagger?

A: Swagger was the original name of both the specification and the tooling. In 2016, the Swagger specification was donated to the OpenAPI Initiative and renamed the OpenAPI Specification. Today, "OpenAPI" refers to the specification format and "Swagger" typically refers to the tooling (Swagger UI, Swagger Editor, Swagger Codegen). In practice, the terms are used interchangeably, and `@nestjs/swagger` implements the OpenAPI 3.0 specification.

Q: How does `@nestjs/swagger` know the type of a DTO property without `@ApiProperty()`?

A: Without the CLI plugin, it does not. TypeScript type information is erased at runtime — the compiled JavaScript has no record that `title: string` was a string. `@ApiProperty()` is a decorator that uses `Reflect.metadata` to store type information that survives compilation. The CLI plugin is a compile-time transformation that automatically injects this metadata by reading the TypeScript AST before compilation. With the plugin, you do not need `@ApiProperty()` for basic types — but you still need it for arrays, enums, and custom options.

Q: How do you document an endpoint that returns an array of objects?

A: Pass `type: [TaskResponseDto]` to the response decorator — `@ApiOkResponse({ type: [TaskResponseDto] })`. The square brackets tell Swagger this is an array. For `@ApiBody()` with an array body, use `@ApiBody({ type: [CreateTaskDto] })` or add `isArray: true` to the `@ApiProperty()` on the body. Without the array notation, Swagger would document the response as a single object instead of an array.

Q: Why should Swagger be disabled in production?

A: Swagger exposes the complete API surface — every endpoint, its parameter names, expected request shapes, and response schemas. This is valuable for developers but also for attackers: it tells them exactly where to probe for vulnerabilities, which endpoints accept file uploads, which ones have admin-only parameters, and the full shape of error responses. Beyond security, serving the Swagger UI in production wastes server resources on every cold load of the UI assets. The JSON spec can still be served internally or exported as a file for client generation without mounting the UI.

---

## Quick Reference: Decorator Cheat Sheet

### Controller / Class Level

| Decorator                           | What it does                                        |
| ----------------------------------- | --------------------------------------------------- |
| `@ApiTags('name')`                  | Groups routes under a named section in Swagger UI   |
| `@ApiBearerAuth('scheme')`          | Marks all routes in the controller as requiring JWT |
| `@ApiHeader({ name, description })` | Documents a custom required request header          |

### Method / Route Level

| Decorator                                 | What it does                                 |
| ----------------------------------------- | -------------------------------------------- |
| `@ApiOperation({ summary, description })` | Adds a title and description to the endpoint |
| `@ApiParam({ name, type, description })`  | Documents a path parameter (`:id`)           |
| `@ApiQuery({ name, type, required })`     | Documents a query string parameter           |
| `@ApiBody({ type })`                      | Explicitly sets the request body schema      |
| `@ApiOkResponse({ type })`                | Documents a 200 response                     |
| `@ApiCreatedResponse({ type })`           | Documents a 201 response                     |
| `@ApiNoContentResponse()`                 | Documents a 204 response                     |
| `@ApiBadRequestResponse()`                | Documents a 400 response                     |
| `@ApiUnauthorizedResponse()`              | Documents a 401 response                     |
| `@ApiForbiddenResponse()`                 | Documents a 403 response                     |
| `@ApiNotFoundResponse()`                  | Documents a 404 response                     |
| `@ApiConflictResponse()`                  | Documents a 409 response                     |
| `@ApiTooManyRequestsResponse()`           | Documents a 429 response                     |

### DTO / Property Level

| Decorator                                | What it does                       |
| ---------------------------------------- | ---------------------------------- |
| `@ApiProperty({ description, example })` | Documents a required DTO property  |
| `@ApiPropertyOptional({ ... })`          | Documents an optional DTO property |

---

## Quick Reference: File Summary

| File                             | Purpose                                                                                            |
| -------------------------------- | -------------------------------------------------------------------------------------------------- |
| `src/main.ts`                    | `DocumentBuilder`, `SwaggerModule.createDocument()`, `SwaggerModule.setup()` — gated by `NODE_ENV` |
| `nest-cli.json`                  | CLI plugin config to auto-infer `@ApiProperty()` from TypeScript types                             |
| `auth/dto/register.dto.ts`       | `@ApiProperty()` on every field with descriptions and examples                                     |
| `tasks/dto/create-task.dto.ts`   | Enum, array, and nested object documentation patterns                                              |
| `users/dto/user-response.dto.ts` | Response DTO with `@ApiProperty()` — no password field documented                                  |
| `tasks/tasks.controller.ts`      | `@ApiTags`, `@ApiBearerAuth`, `@ApiOperation`, full response decorators                            |
| `auth/auth.controller.ts`        | Public endpoint documentation with inline schema for login response                                |

---

_Sources: NestJS Official Documentation — [OpenAPI Introduction](https://docs.nestjs.com/openapi/introduction), [Types and Parameters](https://docs.nestjs.com/openapi/types-and-parameters), [Operations](https://docs.nestjs.com/openapi/operations), and [Security](https://docs.nestjs.com/openapi/security)_

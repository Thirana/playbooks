# NestJS Validation and Serialization
Purpose: This is the long-form implementation guide for request validation and response serialization in a NestJS codebase.

## Related Notes
- [1. Validation and Serialization Core Concepts](./1_validation_serialization_core_concepts.md)
- [3. NestJS Validation and Serialization Runtime Flow](./3_nestjs_validation_serialization_runtime_flow.md)
- [4. Validation and Serialization Revision Cheatsheet](./4_validation_serialization_revision_cheatsheet.md)

## The Developer Requirement
TaskFlow has three issues:
- invalid request bodies are reaching services and failing too late
- extra request fields are slipping through API boundaries
- user responses are leaking fields that should never leave the server

The fix is:
- validate incoming data globally
- define explicit request DTOs
- define explicit response DTOs
- serialize responses before they leave the app

## How To Use This Note
- Read this file for the full implementation walkthrough.
- Use [1. Validation and Serialization Core Concepts](./1_validation_serialization_core_concepts.md) first if you want the mental model.
- Use [3. NestJS Validation and Serialization Runtime Flow](./3_nestjs_validation_serialization_runtime_flow.md) for lifecycle and debugging.
- Use [4. Validation and Serialization Revision Cheatsheet](./4_validation_serialization_revision_cheatsheet.md) for quick revision.

## Part 1: Install the libraries
```bash
npm install --save class-validator class-transformer
npm install --save @nestjs/mapped-types
```

Why:
- `class-validator` powers request validation decorators
- `class-transformer` powers transformation and serialization
- `@nestjs/mapped-types` helps derive update DTOs without repeating decorators

## Part 2: Register `ValidationPipe` globally
The safest default is a global pipe in `main.ts`.

**`src/main.ts`**

```typescript
import { NestFactory } from "@nestjs/core";
import {
  UnprocessableEntityException,
  ValidationPipe,
} from "@nestjs/common";
import { AppModule } from "./app.module";

async function bootstrap() {
  const app = await NestFactory.create(AppModule);

  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,
      forbidNonWhitelisted: true,
      transform: true,
      transformOptions: {
        enableImplicitConversion: true,
      },
      exceptionFactory: (errors) => {
        const result = errors.map((error) => ({
          field: error.property,
          messages: Object.values(error.constraints || {}),
        }));

        return new UnprocessableEntityException({
          statusCode: 422,
          message: "Validation failed",
          errors: result,
        });
      },
    }),
  );

  await app.listen(3000);
}
bootstrap();
```

Why each option matters:
- `whitelist: true` strips undeclared fields
- `forbidNonWhitelisted: true` makes unknown fields fail fast
- `transform: true` converts plain input into DTO instances
- `enableImplicitConversion: true` helps with query and param coercion
- `exceptionFactory` gives a stable error contract

## Part 3: Request DTOs with `class-validator`

### Registration DTO

**`src/auth/dto/register.dto.ts`**

```typescript
import {
  IsEmail,
  IsEnum,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  MinLength,
} from "class-validator";

export enum UserRole {
  USER = "user",
  ADMIN = "admin",
}

export class RegisterDto {
  @IsEmail({}, { message: "Please provide a valid email address" })
  email: string;

  @IsString()
  @MinLength(8, { message: "Password must be at least 8 characters" })
  @MaxLength(64)
  @Matches(/(?=.*[A-Z])(?=.*[a-z])(?=.*\d)/, {
    message:
      "Password must contain at least one uppercase letter, one lowercase letter, and one number",
  })
  password: string;

  @IsOptional()
  @IsString()
  @MaxLength(100)
  name?: string;

  @IsOptional()
  @IsEnum(UserRole)
  role?: UserRole;
}
```

This DTO fixes common issues:
- missing or invalid email is rejected before the service runs
- weak password is rejected early
- unknown fields like `isAdmin` are rejected by the pipe config

### Nested DTO example

**`src/tasks/dto/create-task.dto.ts`**

```typescript
import {
  ArrayMaxSize,
  IsArray,
  IsEnum,
  IsNotEmpty,
  IsOptional,
  IsString,
  ValidateNested,
} from "class-validator";
import { Type } from "class-transformer";
import { TaskStatus } from "../task.entity";

export class LabelDto {
  @IsString()
  @IsNotEmpty()
  name: string;
}

export class CreateTaskDto {
  @IsString()
  @IsNotEmpty()
  title: string;

  @IsOptional()
  @IsString()
  description?: string;

  @IsOptional()
  @IsEnum(TaskStatus)
  status?: TaskStatus;

  @IsOptional()
  @IsArray()
  @IsString({ each: true })
  @ArrayMaxSize(10)
  tags?: string[];

  @IsOptional()
  @IsArray()
  @ValidateNested({ each: true })
  @Type(() => LabelDto)
  labels?: LabelDto[];
}
```

Important rule:
- `@ValidateNested()` tells Nest to validate nested values
- `@Type(() => LabelDto)` tells it what class to instantiate

Without `@Type()`, nested validation is commonly skipped.

### Query DTO example

**`src/tasks/dto/get-tasks.dto.ts`**

```typescript
import {
  IsEnum,
  IsNumber,
  IsOptional,
  IsString,
  Max,
  Min,
} from "class-validator";
import { TaskStatus } from "../task.entity";

export class GetTasksDto {
  @IsOptional()
  @IsEnum(TaskStatus)
  status?: TaskStatus;

  @IsOptional()
  @IsString()
  search?: string;

  @IsOptional()
  @IsNumber()
  @Min(1)
  page?: number;

  @IsOptional()
  @IsNumber()
  @Min(1)
  @Max(100)
  limit?: number;
}
```

Usage:

```typescript
@Get()
findAll(@Query() dto: GetTasksDto) {
  return this.tasksService.findAll(dto);
}
```

Because `transform: true` and `enableImplicitConversion: true` are enabled:
- `page=2` becomes `2`
- enum values are checked
- invalid numeric values are rejected

## Part 4: Custom validators
Use a custom validator when business rules need service-backed checks.

**`src/common/validators/is-unique-email.validator.ts`**

```typescript
import {
  registerDecorator,
  ValidationArguments,
  ValidationOptions,
  ValidatorConstraint,
  ValidatorConstraintInterface,
} from "class-validator";
import { Injectable } from "@nestjs/common";
import { UsersService } from "../../users/users.service";

@ValidatorConstraint({ name: "isUniqueEmail", async: true })
@Injectable()
export class IsUniqueEmailConstraint implements ValidatorConstraintInterface {
  constructor(private readonly usersService: UsersService) {}

  async validate(email: string): Promise<boolean> {
    const user = await this.usersService.findByEmail(email);
    return !user;
  }

  defaultMessage(args: ValidationArguments): string {
    return `Email ${args.value} is already taken`;
  }
}

export function IsUniqueEmail(validationOptions?: ValidationOptions) {
  return function (object: object, propertyName: string) {
    registerDecorator({
      target: object.constructor,
      propertyName,
      options: validationOptions,
      constraints: [],
      validator: IsUniqueEmailConstraint,
    });
  };
}
```

Register it in a module:

```typescript
@Module({
  providers: [IsUniqueEmailConstraint],
})
export class UsersModule {}
```

Use it in the DTO:

```typescript
export class RegisterDto {
  @IsEmail()
  @IsUniqueEmail({ message: "This email is already registered" })
  email: string;
}
```

## Part 5: Serialization with `ClassSerializerInterceptor`
Validation protects input. Serialization protects output.

Register the serializer globally:

**`src/app.module.ts`**

```typescript
import { Module, ClassSerializerInterceptor } from "@nestjs/common";
import { APP_INTERCEPTOR } from "@nestjs/core";

@Module({
  providers: [
    {
      provide: APP_INTERCEPTOR,
      useClass: ClassSerializerInterceptor,
    },
  ],
})
export class AppModule {}
```

What it does:
- intercepts controller return values
- runs class-transformer serialization logic
- applies decorators such as `@Exclude()`, `@Expose()`, and `@Transform()`

Important condition:
- the controller should return a class instance, not a raw plain object

## Part 6: Response DTOs

### User response DTO

**`src/users/dto/user-response.dto.ts`**

```typescript
import { Exclude, Expose, Transform } from "class-transformer";

export class UserResponseDto {
  @Expose()
  id: number;

  @Expose()
  email: string;

  @Expose()
  role: string;

  @Expose()
  createdAt: Date;

  @Exclude()
  password: string;

  @Expose()
  get isActive(): boolean {
    return this.role !== "banned";
  }

  @Expose()
  @Transform(({ value }) => value?.toISOString())
  updatedAt: Date;

  constructor(partial: Partial<UserResponseDto>) {
    Object.assign(this, partial);
  }
}
```

### Nested response DTO

**`src/tasks/dto/task-response.dto.ts`**

```typescript
import { Expose, Type } from "class-transformer";

class LabelResponseDto {
  @Expose()
  id: number;

  @Expose()
  name: string;
}

export class TaskResponseDto {
  @Expose()
  id: number;

  @Expose()
  title: string;

  @Expose()
  description: string;

  @Expose()
  status: string;

  @Expose()
  userId: number;

  @Expose()
  createdAt: Date;

  @Expose()
  @Type(() => LabelResponseDto)
  labels: LabelResponseDto[];

  constructor(partial: Partial<TaskResponseDto>) {
    Object.assign(this, partial);
  }
}
```

### Controller usage

```typescript
import { Controller, Get, Param, SerializeOptions } from "@nestjs/common";

@SerializeOptions({ excludeExtraneousValues: true })
@Controller("users")
export class UsersController {
  constructor(private readonly usersService: UsersService) {}

  @Get(":id")
  async findOne(@Param("id") id: number): Promise<UserResponseDto> {
    const user = await this.usersService.findById(id);
    return new UserResponseDto(user);
  }
}
```

Why `excludeExtraneousValues: true` is valuable:
- only `@Expose()` fields are included
- newly added entity columns do not leak by default
- the API stays explicit and safer

## Part 7: Mapped types for update DTOs
Use mapped types to avoid repeating validation decorators.

**`src/tasks/dto/update-task.dto.ts`**

```typescript
import {
  IntersectionType,
  OmitType,
  PartialType,
  PickType,
} from "@nestjs/mapped-types";
import { CreateTaskDto } from "./create-task.dto";

export class UpdateTaskDto extends PartialType(CreateTaskDto) {}

export class UpdateTaskWithoutLabelsDto extends OmitType(CreateTaskDto, [
  "labels",
] as const) {}

export class TaskTitleDto extends PickType(CreateTaskDto, ["title"] as const) {}

export class CreateTaskWithMetaDto extends IntersectionType(
  CreateTaskDto,
  TaskTitleDto,
) {}
```

Main benefit:
- validators are preserved
- update DTOs stay DRY
- PATCH endpoints get optional fields without losing validation rules

## Part 8: Production reminders
- register `ValidationPipe` globally
- use `whitelist`, `forbidNonWhitelisted`, and `transform` together by default
- keep request DTOs and response DTOs separate
- return response DTO instances, not raw entities
- prefer `excludeExtraneousValues` with `@Expose()` for safer response control
- use `@Type()` any time nested objects need validation or nested serialization
- use mapped types instead of repeating the same DTO fields manually

## Quick Setup Cheat Sheet
```typescript
// main.ts
app.useGlobalPipes(
  new ValidationPipe({
    whitelist: true,
    forbidNonWhitelisted: true,
    transform: true,
    transformOptions: { enableImplicitConversion: true },
  }),
);

// app.module.ts
{
  provide: APP_INTERCEPTOR,
  useClass: ClassSerializerInterceptor,
}

// controller
@SerializeOptions({ excludeExtraneousValues: true })
return new UserResponseDto(user);
```

## Quick File Map
| File | Main responsibility |
| --- | --- |
| `src/main.ts` | global `ValidationPipe` setup |
| `src/app.module.ts` | global `ClassSerializerInterceptor` |
| `auth/dto/register.dto.ts` | request-body validation |
| `tasks/dto/create-task.dto.ts` | nested validation rules |
| `tasks/dto/get-tasks.dto.ts` | query validation and coercion |
| `tasks/dto/update-task.dto.ts` | mapped types for updates |
| `users/dto/user-response.dto.ts` | user response serialization |
| `tasks/dto/task-response.dto.ts` | nested response serialization |
| `common/validators/is-unique-email.validator.ts` | custom async validator |

## Final Revision Anchors
If you are revising quickly, remember this sequence:
1. validate input before controllers
2. transform plain values into DTO instances
3. reject unknown and invalid fields
4. return response DTO instances
5. serialize output with explicit exposed fields

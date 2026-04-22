# Validation and Serialization Revision Cheatsheet
Purpose: This is the shortest note in the set. Use it for quick recall, interview prep, and fast implementation review.

## Related Notes
- [1. Validation and Serialization Core Concepts](./1_validation_serialization_core_concepts.md)
- [2. Full Validation and Serialization Learning Guide](./2_validation_serialization_learning_guide.md)
- [3. NestJS Validation and Serialization Runtime Flow](./3_nestjs_validation_serialization_runtime_flow.md)

## Memorize These First
- validation protects incoming data
- serialization protects outgoing data
- `ValidationPipe` runs before the controller
- `ClassSerializerInterceptor` runs after the controller returns
- `whitelist` strips unknown fields
- `forbidNonWhitelisted` rejects unknown fields
- nested validation needs both `@ValidateNested()` and `@Type()`
- response DTOs should usually be explicit class instances

## Core tools
| Item | Use it for |
| --- | --- |
| `ValidationPipe` | global request validation |
| `class-validator` | request decorators |
| `class-transformer` | transformation and serialization |
| `ClassSerializerInterceptor` | response serialization |
| `@nestjs/mapped-types` | derived DTOs like update DTOs |

## Validation reminders
- `transform: true` converts plain input into DTO instances
- `enableImplicitConversion: true` helps with query and param coercion
- `exceptionFactory` customizes the error payload
- `@IsOptional()` means “skip validation if absent,” not “accept any value”

## Serialization reminders
- `@Exclude()` removes a field
- `@Expose()` includes a field
- `@Transform()` reshapes a value
- `@SerializeOptions({ excludeExtraneousValues: true })` makes output opt-in
- returning a plain object can bypass the intended DTO serialization behavior

## Common decorators
| Decorator | Main job |
| --- | --- |
| `@IsEmail()` | validate email format |
| `@MinLength()` | enforce string length |
| `@IsEnum()` | restrict to enum values |
| `@ValidateNested()` | validate nested object |
| `@Type(() => Class)` | instantiate nested class |
| `@Exclude()` | hide response field |
| `@Expose()` | allow response field |

## Mapped types
- `PartialType(Dto)` -> all fields optional, validators preserved
- `PickType(Dto, [...])` -> only selected fields
- `OmitType(Dto, [...])` -> remove selected fields
- `IntersectionType(A, B)` -> merge DTOs

## Common mistakes
- forgetting to register `ValidationPipe` globally
- enabling `whitelist` but forgetting `forbidNonWhitelisted` when strict contracts are needed
- using `@ValidateNested()` without `@Type()`
- returning raw entities directly from controllers
- forgetting to register custom validators in a module
- manually rewriting update DTOs instead of using mapped types

## Interview flash answers
**`whitelist` vs `forbidNonWhitelisted`**
- `whitelist` strips extra fields
- `forbidNonWhitelisted` rejects the request when extra fields are present

**Why does nested validation need `@Type()`?**
- because nested plain objects must become class instances before validators can run

**Why return response DTO instances instead of plain objects?**
- because serializer decorators are defined on classes, not anonymous objects

**Why use `PartialType()` for updates?**
- because it keeps validators while making fields optional

## Last-minute recall
- validate early
- transform input
- reject unknown fields
- return DTO instances
- serialize output explicitly

# NestJS Validation and Serialization Runtime Flow
Purpose: This note explains what happens at runtime when NestJS validates incoming data, transforms DTOs, and serializes controller responses.

## Related Notes
- [1. Validation and Serialization Core Concepts](./1_validation_serialization_core_concepts.md)
- [2. Full Validation and Serialization Learning Guide](./2_validation_serialization_learning_guide.md)
- [4. Validation and Serialization Revision Cheatsheet](./4_validation_serialization_revision_cheatsheet.md)

## TaskFlow setup used in this note
Assume the app has:
- global `ValidationPipe`
- `whitelist`, `forbidNonWhitelisted`, and `transform` enabled
- custom `exceptionFactory`
- global `ClassSerializerInterceptor`
- response DTOs using `@Expose()` and `@Exclude()`

## 1. High-level lifecycle
```text
Incoming request
  -> guards
  -> pipes validate and transform input
  -> controller receives typed DTO instance
  -> service runs
  -> controller returns response DTO instance
  -> serializer interceptor transforms output
  -> response sent to client
```

## 2. Validation flow for request bodies
Example: `POST /auth/register`.

1. Nest receives the raw JSON body.
2. `ValidationPipe` runs before the controller.
3. `class-transformer` converts the plain object into `RegisterDto`.
4. Unknown fields are handled by `whitelist` and `forbidNonWhitelisted`.
5. `class-validator` evaluates decorators like `@IsEmail()` and `@MinLength()`.
6. If validation fails, `exceptionFactory` builds the error response.
7. If validation passes, the controller receives a safe DTO instance.

Because the pipe runs before the controller:
- invalid input never reaches the service
- error responses are consistent

## 3. Query and param transformation flow
Query strings and route params arrive as strings.

With:
- `transform: true`
- `enableImplicitConversion: true`

the runtime flow becomes:

1. query string value `"2"` arrives
2. DTO metadata says `page` should be a number
3. class-transformer converts it to `2`
4. `@IsNumber()` validates the converted value
5. controller receives a correctly typed DTO

Without transformation, controllers and services would keep dealing with raw strings.

## 4. Nested validation flow
Example: `labels` inside `CreateTaskDto`.

1. incoming body contains nested plain objects
2. `@Type(() => LabelDto)` tells class-transformer which class to instantiate
3. nested values become `LabelDto` instances
4. `@ValidateNested()` triggers validators on each nested item
5. invalid nested structures fail before controller execution

If `@Type()` is missing:
- nested values often stay plain objects
- nested validators may never execute

## 5. Serialization flow
Example: `GET /users/:id`.

1. controller calls the service and gets a full user object
2. controller wraps it with `new UserResponseDto(user)`
3. controller returns the DTO instance
4. `ClassSerializerInterceptor` runs on the way out
5. class-transformer applies `@Expose()`, `@Exclude()`, and `@Transform()`
6. final JSON is built and sent to the client

This is why response DTO instances matter. A plain object does not carry the same class metadata.

## 6. `excludeExtraneousValues` flow
When `@SerializeOptions({ excludeExtraneousValues: true })` is active:

1. response DTO instance reaches the serializer
2. class-transformer checks which fields have `@Expose()`
3. only exposed fields are kept
4. everything else is dropped automatically

This opt-in behavior is safer than remembering to exclude every sensitive field manually.

## 7. Common failure points
| Symptom | Likely cause |
| --- | --- |
| extra request field still reaches service | `ValidationPipe` is not global or whitelist is missing |
| nested DTO validation does not run | `@Type()` is missing |
| query param stays a string | `transform` or implicit conversion is missing |
| password appears in response | raw entity or plain object was returned |
| custom validator cannot inject service | validator was not registered in a module |

## 8. Debugging checklist
1. Is `ValidationPipe` global?
2. Are `whitelist`, `forbidNonWhitelisted`, and `transform` enabled?
3. Are nested DTOs using both `@ValidateNested()` and `@Type()`?
4. Is the controller returning a response DTO instance instead of a raw entity?
5. Is `ClassSerializerInterceptor` registered globally?
6. If using `excludeExtraneousValues`, are expected fields marked with `@Expose()`?

Use this note for lifecycle narration and debugging. Use [4. Validation and Serialization Revision Cheatsheet](./4_validation_serialization_revision_cheatsheet.md) when you only need the compressed version.

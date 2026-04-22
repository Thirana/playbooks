# NestJS Validation and Serialization Core Concepts
Purpose: This note explains the validation and serialization mental model in NestJS before the full implementation walkthrough.

## Related Notes
- [2. Full Validation and Serialization Learning Guide](./2_validation_serialization_learning_guide.md)
- [3. NestJS Validation and Serialization Runtime Flow](./3_nestjs_validation_serialization_runtime_flow.md)
- [4. Validation and Serialization Revision Cheatsheet](./4_validation_serialization_revision_cheatsheet.md)

## 1. Why this topic matters
Validation protects the incoming side of the API.
Serialization protects the outgoing side.

TaskFlow problems:
- client sends invalid request data and the service crashes later
- client sends unexpected fields like `isAdmin: true`
- API returns internal or sensitive fields like `password`

These are different problems, so NestJS uses different mechanisms for them.

## 2. Validation vs serialization
Validation happens on incoming data.

Goal:
- reject bad input early
- enforce request shape
- prevent unexpected fields from reaching services

Serialization happens on outgoing data.

Goal:
- control what fields appear in the response
- reshape response values
- prevent internal fields from leaking

Short rule:
- validation is about request safety
- serialization is about response safety

## 3. The two libraries underneath
NestJS builds this feature area on two external libraries.

### `class-validator`
This validates class properties using decorators like:
- `@IsEmail()`
- `@MinLength()`
- `@IsEnum()`
- `@ValidateNested()`

### `class-transformer`
This transforms plain objects into class instances and class instances into plain objects.

It is responsible for:
- request transformation
- nested type conversion
- response serialization decorators such as `@Expose()` and `@Exclude()`

The common mental model is:
- `class-validator` checks rules
- `class-transformer` creates and reshapes objects

## 4. DTOs are contracts
A DTO is a class that defines the allowed shape of data.

Request DTOs:
- describe incoming body, params, or query values
- carry validation decorators

Response DTOs:
- describe what the API is allowed to return
- carry serialization decorators

Important distinction:
- request DTOs are not the same thing as database entities
- response DTOs are not the same thing as request DTOs

That separation is what keeps contracts explicit.

## 5. Where validation runs
Validation runs in pipes, usually through `ValidationPipe`.

High-level request flow:

```text
request
  -> middleware
  -> guards
  -> interceptors (pre-handler)
  -> pipes
  -> controller
  -> service
```

Because validation happens before the controller:
- invalid input is rejected early
- services receive already-checked data

## 6. Where serialization runs
Serialization runs in interceptors, usually through `ClassSerializerInterceptor`.

High-level response flow:

```text
controller returns value
  -> interceptor transforms response
  -> JSON sent to client
```

Because serialization happens after the controller returns:
- the route can work with full internal data
- the client still receives a safe, filtered shape

## 7. The most important `ValidationPipe` options
These options define most real-world behavior.

### `whitelist: true`
Removes incoming properties that are not defined in the DTO with decorators.

Example:
- client sends `isAdmin: true`
- DTO does not declare it
- the field is stripped out

### `forbidNonWhitelisted: true`
Rejects the request instead of silently stripping unknown fields.

Short difference:
- `whitelist` removes
- `forbidNonWhitelisted` rejects

### `transform: true`
Converts plain incoming objects into DTO class instances.

This matters because:
- decorators are defined on classes
- route params and query strings otherwise remain raw strings

### `enableImplicitConversion: true`
Lets class-transformer infer simple conversions from TypeScript metadata.

Example:
- `page=2` in query string becomes `2` as a number

## 8. Nested validation needs `@Type()`
This is one of the most important gotchas.

`@ValidateNested()` by itself is not enough.

You also need:

```typescript
@Type(() => LabelDto)
```

Reason:
- nested plain objects must be converted into class instances first
- without `@Type()`, nested validators often do not run

## 9. Custom validators can use DI
When built-in decorators are not enough, you can create a custom validator with:
- `@ValidatorConstraint()`
- `registerDecorator()`
- `@Injectable()`

This allows validators such as:
- unique email check
- business-rule validation against a service

The validator must be registered in a Nest module so dependency injection works.

## 10. Serialization decorators and response safety
Common response decorators:

- `@Exclude()` removes a field
- `@Expose()` includes a field
- `@Transform()` reshapes a field value
- `@Type(() => NestedDto)` handles nested response objects

Two common strategies:

### Opt-out
Use `@Exclude()` on sensitive fields.

Risk:
- new fields may accidentally appear unless they are explicitly excluded

### Opt-in
Use `@SerializeOptions({ excludeExtraneousValues: true })` and `@Expose()`.

Benefit:
- only explicitly exposed fields are returned
- safer for production APIs

## 11. Class instance vs plain object
`ClassSerializerInterceptor` works by inspecting class decorators.

If the controller returns a plain object:
- there is no class metadata to inspect
- `@Exclude()` and `@Expose()` do not apply as intended

That is why response DTOs usually use:

```typescript
constructor(partial: Partial<UserResponseDto>) {
  Object.assign(this, partial);
}
```

and the controller returns:

```typescript
return new UserResponseDto(user);
```

## 12. Mapped types keep DTOs DRY
NestJS provides mapped types through `@nestjs/mapped-types`.

Main ones:
- `PartialType()`
- `PickType()`
- `OmitType()`
- `IntersectionType()`

The important advantage is that validators are preserved.

Example:
- `UpdateTaskDto extends PartialType(CreateTaskDto)`
- every field becomes optional
- original validators still apply when the field is present

## 13. Concept checkpoints
If you can explain these clearly, you understand the topic:
- validation happens before the controller, serialization happens after
- `whitelist` and `forbidNonWhitelisted` are not the same thing
- nested validation needs both `@ValidateNested()` and `@Type()`
- response DTOs should usually be separate from entities
- `excludeExtraneousValues` is safer than relying only on `@Exclude()`
- `PartialType()` keeps validators while reducing duplication

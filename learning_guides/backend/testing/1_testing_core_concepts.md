# NestJS Testing Core Concepts
Purpose: This note explains the testing mental model in NestJS before the full unit-test and E2E implementation walkthrough.

## Related Notes
- [2. Full Testing Learning Guide](./2_testing_learning_guide.md)
- [3. NestJS Testing Runtime Flow](./3_nestjs_testing_runtime_flow.md)
- [4. Testing Revision Cheatsheet](./4_testing_revision_cheatsheet.md)

## 1. Why NestJS projects need multiple test types
TaskFlow wants two guarantees before merge:
- service logic works in isolation
- HTTP endpoints work correctly from the outside

Those are different goals, so they need different kinds of tests.

## 2. Unit tests
A unit test verifies one class in isolation.

That means:
- real dependencies are replaced with mocks
- no real database
- no real HTTP server
- no real external services

Unit tests answer:
- "Does this class's logic behave correctly?"

Why they are fast:
- everything runs in memory
- no I/O
- no app bootstrap cost

Typical use cases:
- service business logic
- controller delegation logic
- exception branches
- method-level rules

## 3. E2E tests
An E2E test boots a real NestJS application and makes real HTTP requests against it.

That means:
- routing is real
- pipes are real
- guards can be real or selectively overridden
- controller response shape is real

E2E tests answer:
- "Does this endpoint behave correctly from the outside?"

Why they are slower:
- the NestJS app must bootstrap
- the request passes through much more of the framework pipeline

## 4. The testing pyramid in practice
You usually want:
- many unit tests
- fewer E2E tests

Reason:
- unit tests are cheaper and faster
- E2E tests are broader and more expensive

Good rule:
- unit tests for most business logic
- E2E tests for route behavior and critical flows

## 5. The main tools
### Jest
Jest is the default NestJS testing framework.

It gives you:
- the test runner
- assertions via `expect`
- mocks via `jest.fn()`
- spies via `jest.spyOn()`

### Supertest
Supertest is used for E2E HTTP assertions.

It lets you:
- send requests to the test app
- assert status codes
- assert response bodies

### `@nestjs/testing`
This package provides `Test.createTestingModule()`.

It is the central utility for:
- unit tests
- E2E test app setup

## 6. Arrange, Act, Assert
The AAA pattern is the standard shape of a good test:

1. Arrange
   set up mocks and input data
2. Act
   call the method or endpoint
3. Assert
   verify result and interactions

This keeps tests readable and predictable.

## 7. `describe`, `it`, `beforeEach`, `beforeAll`
### `describe`
Groups related tests.

Typical pattern:
- one outer `describe` per class
- one nested `describe` per method

### `it`
One specific behavior.

Good rule:
- one reason to fail per `it`

### `beforeEach`
Runs before every test.

Use it for:
- rebuilding unit-test modules
- resetting per-test state

### `beforeAll`
Runs once before all tests.

Use it for:
- expensive E2E app setup

### `afterAll`
Use it to clean up:
- close the Nest app
- release resources

## 8. Mocks vs spies
### `jest.fn()`
A standalone mock function that you control fully.

Example:
```typescript
const mockFn = jest.fn();
mockFn.mockResolvedValue({ id: 1 });
```

Use it when:
- you are building a fake dependency object

### `jest.spyOn()`
A spy wraps a method on an existing object.

Example:
```typescript
jest.spyOn(service, "findByEmail").mockResolvedValue(null);
```

Use it when:
- you want to watch or override one method on a real object

## 9. Why DI matters in tests
NestJS applications are dependency-injected. Good tests should respect that structure.

That is why `Test.createTestingModule()` is better than manually calling `new AuthService(...)` in many cases:
- it verifies the DI shape
- it mirrors how the app really builds classes
- it lets you override specific providers cleanly

## 10. Mocking TypeORM repositories
When a service uses `@InjectRepository(Entity)`, the repository token is not just the class name.

Use:
```typescript
getRepositoryToken(Task)
```

That is the actual token that Nest resolves for TypeORM repositories.

## 11. Why E2E tests still use mocks
E2E does not mean "everything must be real."

In most NestJS apps, E2E tests still override some dependencies, such as:
- database services
- external APIs
- auth providers

The goal is:
- real Nest pipeline
- controlled external behavior

That keeps tests fast and deterministic.

## 12. Guards, pipes, and test realism
Two important truths:
- unit tests do not naturally exercise guards or pipes
- E2E tests only reflect production if you configure the app similarly

That is why E2E setup often needs:
```typescript
app.useGlobalPipes(new ValidationPipe(...));
```

And why protected-route tests often use:
- real JWT flow
or
- an overridden guard

## 13. Common test boundaries
Use unit tests for:
- service logic
- controller delegation
- repository interaction logic

Use E2E tests for:
- route validation
- auth-protected endpoint behavior
- full request-response shape
- integration of routing, guards, and controller output

## 14. Concept checkpoints
If you can answer these quickly, the foundation is solid:
- What is the difference between a unit test and an E2E test?
- Why is `Test.createTestingModule()` important in NestJS?
- When should you use `beforeEach` vs `beforeAll`?
- What is the difference between `jest.fn()` and `jest.spyOn()`?
- Why do E2E tests often still mock services?
- Why do TypeORM repositories need `getRepositoryToken(Entity)`?

If you want the implementation next, use [2. Full Testing Learning Guide](./2_testing_learning_guide.md).

# NestJS Testing Runtime Flow
Purpose: This note explains what happens at runtime when NestJS builds unit-test modules, boots E2E apps, injects mocks, and handles real HTTP test requests.

## Related Notes
- [1. Testing Core Concepts](./1_testing_core_concepts.md)
- [2. Full Testing Learning Guide](./2_testing_learning_guide.md)
- [4. Testing Revision Cheatsheet](./4_testing_revision_cheatsheet.md)

## TaskFlow setup used in this note
Assume the app has:
- unit tests for services and controllers
- TypeORM repository mocks
- E2E tests using Supertest
- optional guard overrides
- global `ValidationPipe` in production

## 1. High-level lifecycle
```text
Unit test flow
  -> create testing module
  -> inject real class + mock dependencies
  -> call method directly
  -> assert return values and mock interactions

E2E flow
  -> import full AppModule
  -> override selected providers or guards
  -> create Nest application
  -> apply global pipes
  -> send real HTTP request with Supertest
  -> assert real response
```

## 2. Unit-test runtime flow
1. `Test.createTestingModule()` builds a lightweight DI container.
2. The class under test is real.
3. Its dependencies are replaced with mocks.
4. `module.get()` retrieves the wired instance.
5. The test calls the class method directly.
6. Jest assertions check:
   - returned value
   - thrown exception
   - mock call arguments

This is why unit tests are fast:
- no HTTP
- no database
- minimal Nest setup

## 3. Repository-mock flow
When a service uses `@InjectRepository(Entity)`:
1. the service expects a repository token
2. tests must provide `getRepositoryToken(Entity)`
3. Nest injects the mocked repository
4. service methods call mocked repository functions such as `findOne` or `save`

If the wrong token is used, dependency injection fails before the test can run.

## 4. E2E runtime flow
1. `Test.createTestingModule({ imports: [AppModule] })` loads the full module graph.
2. `.overrideProvider()` or `.overrideGuard()` swaps out selected pieces.
3. `createNestApplication()` creates a real Nest application instance.
4. `app.useGlobalPipes(...)` mirrors production bootstrap behavior.
5. `await app.init()` starts the app for testing.
6. Supertest sends a real HTTP request through the full Nest pipeline.
7. The response is asserted with status code and body checks.
8. `await app.close()` cleans up the app after all tests.

## 5. Guard-override flow
Protected endpoints often need a simplified auth path in tests.

Typical flow:
1. create a fake guard implementing `CanActivate`
2. attach a fake `req.user`
3. return `true`
4. override the real guard in the test module

This lets the test focus on endpoint behavior instead of JWT setup.

## 6. Common failure points
| Symptom | Likely cause |
| --- | --- |
| test passes alone but fails in suite | mocks were not cleared between tests |
| repository DI error | wrong token instead of `getRepositoryToken(Entity)` |
| E2E accepts invalid payloads | global `ValidationPipe` was not applied in test setup |
| test process hangs | `app.close()` was not called |
| protected route still returns 401 in test | guard was not overridden correctly |

## 7. Debugging checklist
1. Is the test supposed to be unit or E2E?
2. Are dependencies mocked at the correct DI token?
3. Is `jest.clearAllMocks()` being called between tests?
4. For E2E, does the test app apply the same global pipes as production?
5. For protected routes, are you using a real token flow or an overridden guard?
6. Is `await app.close()` cleaning up the test server?

Use this note for lifecycle narration and debugging. Use [4. Testing Revision Cheatsheet](./4_testing_revision_cheatsheet.md) when you only need the compressed version.

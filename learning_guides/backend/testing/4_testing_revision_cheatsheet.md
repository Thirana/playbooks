# Testing Revision Cheatsheet
Purpose: This is the shortest note in the set. Use it for quick recall, interview prep, and fast implementation review.

## Related Notes
- [1. Testing Core Concepts](./1_testing_core_concepts.md)
- [2. Full Testing Learning Guide](./2_testing_learning_guide.md)
- [3. NestJS Testing Runtime Flow](./3_nestjs_testing_runtime_flow.md)

## Memorize These First
- unit tests isolate one class with mocks
- E2E tests boot a real NestJS app
- Jest provides mocks and assertions
- Supertest drives HTTP assertions
- `Test.createTestingModule()` is central to both
- `getRepositoryToken(Entity)` is the correct token for TypeORM repository mocks

## Main tools
| Tool | Use it for |
| --- | --- |
| Jest | test runner, assertions, mocks, spies |
| Supertest | HTTP assertions in E2E tests |
| `@nestjs/testing` | building Nest testing modules |

## Jest reminders
- `describe()` groups tests
- `it()` defines one behavior
- `beforeEach()` resets per-test setup
- `beforeAll()` is for expensive shared setup
- `jest.fn()` creates mock functions
- `jest.spyOn()` wraps existing methods

## Unit vs E2E
| Test Type | Main goal |
| --- | --- |
| Unit | verify one class in isolation |
| E2E | verify full request-response behavior |

## Common setup patterns
```typescript
// Unit test
const module = await Test.createTestingModule({
  providers: [
    RealService,
    { provide: Dependency, useValue: mockDep },
  ],
}).compile();

// E2E test
const module = await Test.createTestingModule({
  imports: [AppModule],
})
  .overrideProvider(SomeService)
  .useValue(mockSvc)
  .compile();
```

## Common mistakes
- forgetting `jest.clearAllMocks()`
- using the wrong DI token for repository mocks
- skipping global pipes in E2E setup
- forgetting `await app.close()`
- making one test depend on state from another

## Interview flash answers
**Unit test vs E2E test**
- unit tests isolate one class
- E2E tests verify endpoint behavior from the outside

**Why use `Test.createTestingModule()`?**
- because it mirrors NestJS DI and lets you override providers cleanly

**Why use `getRepositoryToken()`?**
- because that is the token resolved by `@InjectRepository()`

## Last-minute recall
- mock dependencies in unit tests
- import `AppModule` for E2E tests
- apply real global pipes in E2E setup
- close the app after E2E tests

# NestJS Testing — Unit Tests and E2E Tests
Purpose: This is the long-form implementation guide for unit tests and E2E tests in a NestJS codebase.

## Related Notes
- [1. Testing Core Concepts](./1_testing_core_concepts.md)
- [3. NestJS Testing Runtime Flow](./3_nestjs_testing_runtime_flow.md)
- [4. Testing Revision Cheatsheet](./4_testing_revision_cheatsheet.md)

## The Developer Requirement
TaskFlow enforces this testing rule before code merges:
- every service method should have unit-test coverage for its logic
- every API endpoint should have at least one E2E test
- tests should run fast and avoid real database dependence where possible

## How To Use This Note
- Read this file for the full implementation walkthrough.
- Use [1. Testing Core Concepts](./1_testing_core_concepts.md) for the mental model first.
- Use [3. NestJS Testing Runtime Flow](./3_nestjs_testing_runtime_flow.md) for lifecycle and debugging.
- Use [4. Testing Revision Cheatsheet](./4_testing_revision_cheatsheet.md) for quick revision.

## Part 1: Key Jest concepts
### Test structure
```typescript
describe("AuthService", () => {
  describe("login", () => {
    it("should return a JWT when credentials are valid", async () => {
      // Arrange
      // Act
      // Assert
    });
  });
});
```

### `beforeEach` and `beforeAll`
```typescript
beforeEach(() => {
  // runs before every test
});

beforeAll(async () => {
  // runs once before all tests
});

afterAll(async () => {
  // cleanup
});
```

Rule of thumb:
- `beforeEach` for isolated unit-test setup
- `beforeAll` for expensive shared E2E setup

### `jest.fn()`
```typescript
const mockFn = jest.fn();
mockFn.mockResolvedValue({ id: 1 });

expect(mockFn).toHaveBeenCalled();
expect(mockFn).toHaveBeenCalledTimes(1);
```

### `jest.spyOn()`
```typescript
jest.spyOn(service, "findByEmail").mockResolvedValue(null);
```

Use spies when you want to observe or override one method on an existing object.

## Part 2: File structure
```text
src/
  auth/
    auth.service.ts
    auth.service.spec.ts
    auth.controller.ts
    auth.controller.spec.ts
  users/
    users.service.ts
    users.service.spec.ts
  tasks/
    tasks.service.ts
    tasks.service.spec.ts

test/
  auth.e2e-spec.ts
  tasks.e2e-spec.ts
  jest-e2e.json
```

Convention:
- unit tests live next to source files
- E2E tests live under `test/`

## Part 3: Unit testing a service
We will test `AuthService` by mocking its dependencies.

**`src/auth/auth.service.spec.ts`**
```typescript
import { Test, TestingModule } from "@nestjs/testing";
import { JwtService } from "@nestjs/jwt";
import { UnauthorizedException } from "@nestjs/common";
import * as bcrypt from "bcrypt";
import { AuthService } from "./auth.service";
import { UsersService } from "../users/users.service";

const mockUsersService = {
  findByEmail: jest.fn(),
  create: jest.fn(),
};

const mockJwtService = {
  signAsync: jest.fn(),
};

describe("AuthService", () => {
  let authService: AuthService;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        AuthService,
        { provide: UsersService, useValue: mockUsersService },
        { provide: JwtService, useValue: mockJwtService },
      ],
    }).compile();

    authService = module.get<AuthService>(AuthService);
  });

  afterEach(() => {
    jest.clearAllMocks();
  });

  describe("validateUser", () => {
    it("should return user data without password when credentials are valid", async () => {
      const mockUser = {
        userId: 1,
        email: "user@test.com",
        password: await bcrypt.hash("correct-password", 10),
        role: "user",
      };
      mockUsersService.findByEmail.mockResolvedValue(mockUser);

      const result = await authService.validateUser(
        "user@test.com",
        "correct-password",
      );

      expect(result).toBeDefined();
      expect(result.email).toBe("user@test.com");
      expect(result.password).toBeUndefined();
      expect(mockUsersService.findByEmail).toHaveBeenCalledWith(
        "user@test.com",
      );
    });

    it("should return null when user is not found", async () => {
      mockUsersService.findByEmail.mockResolvedValue(null);

      const result = await authService.validateUser(
        "nobody@test.com",
        "password",
      );

      expect(result).toBeNull();
    });

    it("should return null when password does not match", async () => {
      const mockUser = {
        userId: 1,
        email: "user@test.com",
        password: await bcrypt.hash("correct-password", 10),
        role: "user",
      };
      mockUsersService.findByEmail.mockResolvedValue(mockUser);

      const result = await authService.validateUser(
        "user@test.com",
        "wrong-password",
      );

      expect(result).toBeNull();
    });
  });

  describe("login", () => {
    it("should return an access_token", async () => {
      const user = { userId: 1, email: "user@test.com", role: "user" };
      const fakeToken = "signed.jwt.token";
      mockJwtService.signAsync.mockResolvedValue(fakeToken);

      const result = await authService.login(user);

      expect(result).toEqual({ access_token: fakeToken });
      expect(mockJwtService.signAsync).toHaveBeenCalledWith({
        sub: user.userId,
        email: user.email,
        role: user.role,
      });
    });
  });

  describe("register", () => {
    it("should throw when user already exists", async () => {
      mockUsersService.findByEmail.mockResolvedValue({
        userId: 1,
        email: "taken@test.com",
      });

      await expect(
        authService.register("taken@test.com", "password"),
      ).rejects.toThrow(UnauthorizedException);

      expect(mockUsersService.create).not.toHaveBeenCalled();
    });

    it("should create and return the user when email is available", async () => {
      mockUsersService.findByEmail.mockResolvedValue(null);
      mockUsersService.create.mockResolvedValue({
        userId: 2,
        email: "new@test.com",
        role: "user",
      });

      const result = await authService.register("new@test.com", "password");

      expect(result.email).toBe("new@test.com");
      expect(result.password).toBeUndefined();
      expect(mockUsersService.create).toHaveBeenCalledWith(
        "new@test.com",
        "password",
      );
    });
  });
});
```

Important pattern:
- real class under test
- mocked dependencies in providers
- `jest.clearAllMocks()` after each test

## Part 4: Unit testing a controller
Controllers are thinner. The main job of the unit test is to verify delegation.

**`src/auth/auth.controller.spec.ts`**
```typescript
import { Test, TestingModule } from "@nestjs/testing";
import { AuthController } from "./auth.controller";
import { AuthService } from "./auth.service";

const mockAuthService = {
  login: jest.fn(),
  register: jest.fn(),
};

describe("AuthController", () => {
  let controller: AuthController;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      controllers: [AuthController],
      providers: [{ provide: AuthService, useValue: mockAuthService }],
    }).compile();

    controller = module.get<AuthController>(AuthController);
  });

  afterEach(() => jest.clearAllMocks());

  it("should call authService.login with req.user", async () => {
    const mockReq = {
      user: { userId: 1, email: "user@test.com", role: "user" },
    };
    const mockToken = { access_token: "jwt.token.here" };
    mockAuthService.login.mockResolvedValue(mockToken);

    const result = await controller.login(mockReq);

    expect(result).toEqual(mockToken);
    expect(mockAuthService.login).toHaveBeenCalledWith(mockReq.user);
  });

  it("should call authService.register", async () => {
    const body = { email: "new@test.com", password: "password123" };
    const mockUser = { userId: 3, email: "new@test.com", role: "user" };
    mockAuthService.register.mockResolvedValue(mockUser);

    const result = await controller.register(body);

    expect(result).toEqual(mockUser);
    expect(mockAuthService.register).toHaveBeenCalledWith(
      body.email,
      body.password,
    );
  });
});
```

## Part 5: Mocking TypeORM repositories
When a service injects a TypeORM repository, mock the repository token, not the entity class.

**`src/tasks/tasks.service.spec.ts`**
```typescript
import { Test, TestingModule } from "@nestjs/testing";
import { getRepositoryToken } from "@nestjs/typeorm";
import { NotFoundException } from "@nestjs/common";
import { Repository } from "typeorm";
import { Task, TaskStatus } from "./task.entity";
import { TasksService } from "./tasks.service";

const mockTaskRepository = () => ({
  find: jest.fn(),
  findOne: jest.fn(),
  create: jest.fn(),
  save: jest.fn(),
  remove: jest.fn(),
});

type MockRepository<T = any> = Partial<Record<keyof Repository<T>, jest.Mock>>;

describe("TasksService", () => {
  let tasksService: TasksService;
  let taskRepository: MockRepository<Task>;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        TasksService,
        {
          provide: getRepositoryToken(Task),
          useFactory: mockTaskRepository,
        },
      ],
    }).compile();

    tasksService = module.get<TasksService>(TasksService);
    taskRepository = module.get<MockRepository<Task>>(getRepositoryToken(Task));
  });

  afterEach(() => jest.clearAllMocks());

  it("should return the task when it exists", async () => {
    const mockTask: Partial<Task> = {
      id: 1,
      userId: 5,
      title: "Fix bug",
      status: TaskStatus.OPEN,
    };
    taskRepository.findOne.mockResolvedValue(mockTask);

    const result = await tasksService.findOne(1, 5);

    expect(result).toEqual(mockTask);
    expect(taskRepository.findOne).toHaveBeenCalledWith({
      where: { id: 1, userId: 5 },
      relations: ["labels"],
    });
  });

  it("should throw NotFoundException when task does not exist", async () => {
    taskRepository.findOne.mockResolvedValue(null);

    await expect(tasksService.findOne(99, 5)).rejects.toThrow(
      NotFoundException,
    );
  });
});
```

Important rule:
- use `getRepositoryToken(Entity)` for repository mocks

## Part 6: E2E testing with Supertest
Import the full `AppModule`, then override the parts you do not want to run for real.

**`test/auth.e2e-spec.ts`**
```typescript
import * as request from "supertest";
import { INestApplication, ValidationPipe } from "@nestjs/common";
import { Test, TestingModule } from "@nestjs/testing";
import { AppModule } from "../src/app.module";
import { AuthService } from "../src/auth/auth.service";

const mockAuthService = {
  register: jest.fn(),
  login: jest.fn(),
  validateUser: jest.fn(),
};

describe("Auth Endpoints (E2E)", () => {
  let app: INestApplication;

  beforeAll(async () => {
    const moduleRef: TestingModule = await Test.createTestingModule({
      imports: [AppModule],
    })
      .overrideProvider(AuthService)
      .useValue(mockAuthService)
      .compile();

    app = moduleRef.createNestApplication();
    app.useGlobalPipes(
      new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true }),
    );
    await app.init();
  });

  afterAll(async () => {
    await app.close();
  });

  afterEach(() => jest.clearAllMocks());

  describe("POST /auth/register", () => {
    it("should return 201 and user data on successful registration", async () => {
      const dto = { email: "new@test.com", password: "Password123!" };
      mockAuthService.register.mockResolvedValue({
        userId: 1,
        email: dto.email,
        role: "user",
      });

      return request(app.getHttpServer())
        .post("/auth/register")
        .send(dto)
        .expect(201)
        .expect((res) => {
          expect(res.body.email).toBe(dto.email);
          expect(res.body.password).toBeUndefined();
        });
    });

    it("should return 400 when email is missing", async () => {
      return request(app.getHttpServer())
        .post("/auth/register")
        .send({ password: "Password123!" })
        .expect(400);
    });
  });

  describe("POST /auth/login", () => {
    it("should return 200 and an access_token on valid credentials", async () => {
      const mockUser = { userId: 1, email: "user@test.com", role: "user" };
      mockAuthService.validateUser.mockResolvedValue(mockUser);
      mockAuthService.login.mockResolvedValue({
        access_token: "jwt.token.here",
      });

      return request(app.getHttpServer())
        .post("/auth/login")
        .send({ email: "user@test.com", password: "Password123!" })
        .expect(200)
        .expect((res) => {
          expect(res.body.access_token).toBeDefined();
        });
    });
  });
});
```

Important rules:
- import the full module
- override deep providers
- apply the same global pipes used in `main.ts`
- close the app in `afterAll`

## Part 7: Overriding guards in E2E tests
Sometimes you want to test a protected route without real JWT handling.

```typescript
import { CanActivate, ExecutionContext } from "@nestjs/common";
import { JwtAuthGuard } from "../src/auth/jwt-auth.guard";

class MockJwtAuthGuard implements CanActivate {
  canActivate(context: ExecutionContext): boolean {
    const req = context.switchToHttp().getRequest();
    req.user = { userId: 1, email: "test@test.com", role: "user" };
    return true;
  }
}

const moduleRef = await Test.createTestingModule({
  imports: [AppModule],
})
  .overrideGuard(JwtAuthGuard)
  .useClass(MockJwtAuthGuard)
  .compile();
```

This is the cleanest way to test endpoint logic without real auth complexity.

## Part 8: Jest configuration
**`package.json`** unit-test config:
```json
{
  "jest": {
    "moduleFileExtensions": ["js", "json", "ts"],
    "rootDir": "src",
    "testRegex": ".*\\.spec\\.ts$",
    "transform": { "^.+\\.(t|j)s$": "ts-jest" },
    "collectCoverageFrom": ["**/*.(t|j)s"],
    "coverageDirectory": "../coverage",
    "testEnvironment": "node"
  }
}
```

**`test/jest-e2e.json`**:
```json
{
  "moduleFileExtensions": ["js", "json", "ts"],
  "rootDir": ".",
  "testEnvironment": "node",
  "testRegex": ".e2e-spec.ts$",
  "transform": { "^.+\\.(t|j)s$": "ts-jest" }
}
```

Common commands:
```bash
npm run test
npm run test:watch
npm run test:cov
npm run test:e2e
```

## Part 9: Production reminders
- always call `jest.clearAllMocks()` in `afterEach`
- always mirror production global pipes in E2E setup
- always close the E2E app with `await app.close()`
- prefer `useFactory` when you want fresh mock objects per module setup
- use `getRepositoryToken(Entity)` for TypeORM repository mocks
- test one behavior per `it()` block

## Quick Setup Cheat Sheet
```typescript
// Unit test
const module = await Test.createTestingModule({
  providers: [
    RealService,
    { provide: Dependency, useValue: mockDep },
    { provide: getRepositoryToken(Entity), useFactory: mockRepo },
  ],
}).compile();

// E2E test
const module = await Test.createTestingModule({
  imports: [AppModule],
})
  .overrideProvider(SomeService)
  .useValue(mockSvc)
  .overrideGuard(JwtAuthGuard)
  .useClass(MockGuard)
  .compile();
```

## Quick File Map
| File | Purpose |
| --- | --- |
| `src/auth/auth.service.spec.ts` | unit tests for `AuthService` |
| `src/auth/auth.controller.spec.ts` | unit tests for `AuthController` |
| `src/tasks/tasks.service.spec.ts` | unit tests with TypeORM repository mocks |
| `test/auth.e2e-spec.ts` | E2E tests for auth endpoints |
| `test/jest-e2e.json` | Jest config for E2E tests |

## Final Revision Anchors
- unit tests isolate one class with mocks
- E2E tests boot a real NestJS app
- `Test.createTestingModule()` is central to both
- Supertest drives HTTP assertions
- `getRepositoryToken()` is the right token for repository mocks

For the lifecycle story, go to [3. NestJS Testing Runtime Flow](./3_nestjs_testing_runtime_flow.md). For quick recall, go to [4. Testing Revision Cheatsheet](./4_testing_revision_cheatsheet.md).

# NestJS Authentication & Authorization: Passport + JWT Strategy

Purpose: This is the long-form implementation guide for building auth in NestJS with Passport and JWT.

## Related Notes

- [1. Auth Core Concepts](./1_auth_core_concepts.md)
- [3. NestJS Auth Request Flow](./3_nestjs_auth_request_flow.md)
- [4. Auth Revision Cheatsheet](./4_auth_revision_cheatsheet.md)

---

## The User Story

You are building a task management API called **TaskFlow**. The requirements are:

- A user must be able to register with an email and password.
- A user must be able to log in and receive a token.
- Protected routes should only allow authenticated users.
- Some actions should be restricted by role, such as allowing only an `admin` to delete tasks created by other users.

This guide uses that story from start to finish so every code snippet has a concrete purpose.

---

## How To Use This Note

- Read this file when you want the full implementation walkthrough.
- Use [1. Auth Core Concepts](./1_auth_core_concepts.md) when you want the ideas without the full code journey.
- Use [3. NestJS Auth Request Flow](./3_nestjs_auth_request_flow.md) when you want to rehearse what happens on each request.
- Use [4. Auth Revision Cheatsheet](./4_auth_revision_cheatsheet.md) for fast recall before an interview or coding session.

---

## Part 1: Core Mental Model

### Authentication vs Authorization

These two concepts are related, but they solve different problems:

- **Authentication** answers: "Who are you?"
- **Authorization** answers: "What are you allowed to do?"

In TaskFlow:

- Logging in with email and password is authentication.
- Checking whether a logged-in user is an `admin` before deleting a task is authorization.

### JWT in one sentence

A JWT is a signed token that the server issues after login. The client sends it on later requests, and the server verifies the signature before trusting the payload.

The token has three parts:

```text
header.payload.signature
```

- **Header**: algorithm metadata such as `HS256`
- **Payload**: claims such as `sub`, `email`, and `role`
- **Signature**: proof that the token was signed with the server secret

Important reminder:

- The payload is encoded, not encrypted.
- Never put secrets or passwords inside it.
- The `sub` claim conventionally stores the user identifier.

### Why Passport matters in NestJS

Passport gives NestJS a strategy-based authentication model:

- `passport-local` handles username or email + password login
- `passport-jwt` handles bearer-token verification

In NestJS, the usual runtime chain is:

```text
Request -> Guard -> Passport strategy -> validate() -> req.user
```

That explains three core ideas:

- A **guard** decides whether authentication should run.
- A **strategy** defines how a request is authenticated.
- Whatever the strategy returns from `validate()` becomes `req.user`.

If you want the concept-only version of these ideas, see [1. Auth Core Concepts](./1_auth_core_concepts.md).

---

## Part 2: Project Setup

### Module structure

For this guide, auth lives mainly in an `auth` module and a `users` module.

```text
src/
  auth/
    auth.module.ts
    auth.controller.ts
    auth.service.ts
    local.strategy.ts
    jwt.strategy.ts
    local-auth.guard.ts
    jwt-auth.guard.ts
    roles.guard.ts
    constants.ts
    decorators/
      public.decorator.ts
      roles.decorator.ts
  users/
    users.module.ts
    users.service.ts
  app.module.ts
```

### Install the dependencies

```bash
npm install --save @nestjs/passport passport passport-local @nestjs/jwt passport-jwt bcrypt
npm install --save-dev @types/passport-local @types/passport-jwt @types/bcrypt
```

What each package does:

- `@nestjs/passport`: NestJS integration layer for Passport
- `passport`: core Passport library
- `passport-local`: validates login credentials from the request body
- `@nestjs/jwt`: gives you `JwtService` for signing tokens
- `passport-jwt`: validates JWTs on incoming protected requests
- `bcrypt`: hashes and compares passwords safely

---

## Part 3: The Users Module

The `UsersModule` owns user lookup and creation. In a real application this would use a database, but an in-memory array keeps the learning example focused on auth mechanics.

**`src/users/users.service.ts`**

```typescript
import { Injectable } from "@nestjs/common";
import * as bcrypt from "bcrypt";

export type User = {
  userId: number;
  email: string;
  password: string;
  role: string;
};

@Injectable()
export class UsersService {
  private readonly users: User[] = [];

  async create(email: string, password: string): Promise<User> {
    const hashedPassword = await bcrypt.hash(password, 10);
    const newUser: User = {
      userId: this.users.length + 1,
      email,
      password: hashedPassword,
      role: "user",
    };

    this.users.push(newUser);
    return newUser;
  }

  async findOne(email: string): Promise<User | undefined> {
    return this.users.find((user) => user.email === email);
  }
}
```

**`src/users/users.module.ts`**

```typescript
import { Module } from "@nestjs/common";
import { UsersService } from "./users.service";

@Module({
  providers: [UsersService],
  exports: [UsersService],
})
export class UsersModule {}
```

Why `exports` matters:

- `AuthService` depends on `UsersService`
- so `UsersModule` must export `UsersService`
- and `AuthModule` must import `UsersModule`

---

## Part 4: The Auth Module Step by Step

### Step 4.1: The JWT secret

Start simple for learning:

**`src/auth/constants.ts`**

```typescript
export const jwtConstants = {
  secret: process.env.JWT_SECRET || "taskflow-super-secret-key",
};
```

Why this exists:

- the same secret signs tokens during login
- the same secret verifies tokens on protected routes

Learning note:

- The fallback string is acceptable for a teaching example.
- In production, load the secret from environment variables only.

### Step 4.2: The AuthService

`AuthService` handles three important responsibilities:

- validate credentials
- register a new user
- sign a JWT after successful login

**`src/auth/auth.service.ts`**

```typescript
import { Injectable, UnauthorizedException } from "@nestjs/common";
import { JwtService } from "@nestjs/jwt";
import { UsersService } from "../users/users.service";
import * as bcrypt from "bcrypt";

@Injectable()
export class AuthService {
  constructor(
    private readonly usersService: UsersService,
    private readonly jwtService: JwtService,
  ) {}

  async validateUser(email: string, password: string): Promise<any> {
    const user = await this.usersService.findOne(email);

    if (!user) {
      return null;
    }

    const isPasswordValid = await bcrypt.compare(password, user.password);

    if (!isPasswordValid) {
      return null;
    }

    const { password: _pw, ...result } = user;
    return result;
  }

  async login(user: any) {
    const payload = {
      sub: user.userId,
      email: user.email,
      role: user.role,
    };

    return {
      access_token: await this.jwtService.signAsync(payload),
    };
  }

  async register(email: string, password: string) {
    const existingUser = await this.usersService.findOne(email);

    if (existingUser) {
      throw new UnauthorizedException("User already exists");
    }

    const user = await this.usersService.create(email, password);
    const { password: _pw, ...result } = user;
    return result;
  }
}
```

Key implementation idea:

- `validateUser()` is not called by the controller directly.
- It is called by the local Passport strategy during login.

### Step 4.3: The local strategy

The local strategy handles email + password authentication before the login route handler executes.

**`src/auth/local.strategy.ts`**

```typescript
import { Strategy } from "passport-local";
import { PassportStrategy } from "@nestjs/passport";
import { Injectable, UnauthorizedException } from "@nestjs/common";
import { AuthService } from "./auth.service";

@Injectable()
export class LocalStrategy extends PassportStrategy(Strategy) {
  constructor(private readonly authService: AuthService) {
    super({
      usernameField: "email",
    });
  }

  async validate(email: string, password: string): Promise<any> {
    const user = await this.authService.validateUser(email, password);

    if (!user) {
      throw new UnauthorizedException("Invalid credentials");
    }

    return user;
  }
}
```

Important detail:

- `passport-local` expects `username` by default.
- Here we override that behavior so it reads `email` instead.

### Step 4.4: The local auth guard

**`src/auth/local-auth.guard.ts`**

```typescript
import { Injectable } from "@nestjs/common";
import { AuthGuard } from "@nestjs/passport";

@Injectable()
export class LocalAuthGuard extends AuthGuard("local") {}
```

Why create this wrapper:

- `AuthGuard("local")` works directly
- but a named class is cleaner, reusable, and easier to read

### Step 4.5: The JWT strategy

The JWT strategy protects routes after login. It reads the bearer token, verifies it, and returns the authenticated user shape.

**`src/auth/jwt.strategy.ts`**

```typescript
import { ExtractJwt, Strategy } from "passport-jwt";
import { PassportStrategy } from "@nestjs/passport";
import { Injectable } from "@nestjs/common";
import { jwtConstants } from "./constants";

@Injectable()
export class JwtStrategy extends PassportStrategy(Strategy) {
  constructor() {
    super({
      jwtFromRequest: ExtractJwt.fromAuthHeaderAsBearerToken(),
      ignoreExpiration: false,
      secretOrKey: jwtConstants.secret,
    });
  }

  async validate(payload: any) {
    return {
      userId: payload.sub,
      email: payload.email,
      role: payload.role,
    };
  }
}
```

Important detail:

- By the time `validate()` runs here, the token signature has already been checked.
- `validate()` is where you can add extra business rules, such as checking whether the user still exists or whether the token should be rejected for some application-specific reason.

### Step 4.6: The JWT auth guard

**`src/auth/jwt-auth.guard.ts`**

```typescript
import { Injectable } from "@nestjs/common";
import { AuthGuard } from "@nestjs/passport";

@Injectable()
export class JwtAuthGuard extends AuthGuard("jwt") {}
```

### Step 4.7: The controller

The controller exposes the public register and login endpoints, plus at least one protected route for testing the authenticated request flow.

**`src/auth/auth.controller.ts`**

```typescript
import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Post,
  Request,
  UseGuards,
} from "@nestjs/common";
import { AuthService } from "./auth.service";
import { LocalAuthGuard } from "./local-auth.guard";
import { JwtAuthGuard } from "./jwt-auth.guard";

@Controller("auth")
export class AuthController {
  constructor(private readonly authService: AuthService) {}

  @Post("register")
  async register(@Body() body: { email: string; password: string }) {
    return this.authService.register(body.email, body.password);
  }

  @HttpCode(HttpStatus.OK)
  @UseGuards(LocalAuthGuard)
  @Post("login")
  async login(@Request() req) {
    return this.authService.login(req.user);
  }

  @UseGuards(JwtAuthGuard)
  @Get("profile")
  getProfile(@Request() req) {
    return req.user;
  }
}
```

Important detail:

- `login()` does not manually validate the password.
- The local guard has already done that before the handler runs.

### Step 4.8: The AuthModule

**`src/auth/auth.module.ts`**

```typescript
import { Module } from "@nestjs/common";
import { PassportModule } from "@nestjs/passport";
import { JwtModule } from "@nestjs/jwt";
import { AuthController } from "./auth.controller";
import { AuthService } from "./auth.service";
import { jwtConstants } from "./constants";
import { JwtStrategy } from "./jwt.strategy";
import { LocalStrategy } from "./local.strategy";
import { UsersModule } from "../users/users.module";

@Module({
  imports: [
    UsersModule,
    PassportModule,
    JwtModule.register({
      global: true,
      secret: jwtConstants.secret,
      signOptions: { expiresIn: "1d" },
    }),
  ],
  providers: [AuthService, LocalStrategy, JwtStrategy],
  controllers: [AuthController],
  exports: [AuthService],
})
export class AuthModule {}
```

Two easy things to forget:

- both strategies must be in `providers`
- `UsersModule` must be in `imports`

---

## Part 5: Make Authentication Global

Route-level `@UseGuards(JwtAuthGuard)` works, but it is repetitive. A common NestJS pattern is:

- protect everything by default
- mark selected routes as public

### Step 5.1: Add a `@Public()` decorator

**`src/auth/decorators/public.decorator.ts`**

```typescript
import { SetMetadata } from "@nestjs/common";

export const IS_PUBLIC_KEY = "isPublic";
export const Public = () => SetMetadata(IS_PUBLIC_KEY, true);
```

### Step 5.2: Update the JWT guard to respect `@Public()`

**`src/auth/jwt-auth.guard.ts`**

```typescript
import { ExecutionContext, Injectable } from "@nestjs/common";
import { Reflector } from "@nestjs/core";
import { AuthGuard } from "@nestjs/passport";
import { IS_PUBLIC_KEY } from "./decorators/public.decorator";

@Injectable()
export class JwtAuthGuard extends AuthGuard("jwt") {
  constructor(private reflector: Reflector) {
    super();
  }

  canActivate(context: ExecutionContext) {
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);

    if (isPublic) {
      return true;
    }

    return super.canActivate(context);
  }
}
```

### Step 5.3: Register the JWT guard globally

**`src/app.module.ts`**

```typescript
import { Module } from "@nestjs/common";
import { APP_GUARD } from "@nestjs/core";
import { AuthModule } from "./auth/auth.module";
import { JwtAuthGuard } from "./auth/jwt-auth.guard";

@Module({
  imports: [AuthModule],
  providers: [
    {
      provide: APP_GUARD,
      useClass: JwtAuthGuard,
    },
  ],
})
export class AppModule {}
```

Now explicitly mark public routes:

```typescript
import { Public } from "./decorators/public.decorator";

@Public()
@Post("register")
async register(@Body() body: { email: string; password: string }) {
  return this.authService.register(body.email, body.password);
}

@Public()
@HttpCode(HttpStatus.OK)
@UseGuards(LocalAuthGuard)
@Post("login")
async login(@Request() req) {
  return this.authService.login(req.user);
}
```

Why this pattern is useful:

- secure-by-default behavior is safer
- fewer chances of forgetting to protect a new route
- public routes are obvious when reading the controller

---

## Part 6: Add Role-Based Authorization

Authentication tells you who the user is. RBAC tells you what that user can do.

### Step 6.1: Add a `@Roles()` decorator

**`src/auth/decorators/roles.decorator.ts`**

```typescript
import { SetMetadata } from "@nestjs/common";

export enum Role {
  User = "user",
  Admin = "admin",
}

export const ROLES_KEY = "roles";
export const Roles = (...roles: Role[]) => SetMetadata(ROLES_KEY, roles);
```

### Step 6.2: Add a RolesGuard

**`src/auth/roles.guard.ts`**

```typescript
import { CanActivate, ExecutionContext, Injectable } from "@nestjs/common";
import { Reflector } from "@nestjs/core";
import { Role, ROLES_KEY } from "./decorators/roles.decorator";

@Injectable()
export class RolesGuard implements CanActivate {
  constructor(private reflector: Reflector) {}

  canActivate(context: ExecutionContext): boolean {
    const requiredRoles = this.reflector.getAllAndOverride<Role[]>(ROLES_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);

    if (!requiredRoles) {
      return true;
    }

    const { user } = context.switchToHttp().getRequest();
    return requiredRoles.some((role) => role === user.role);
  }
}
```

### Step 6.3: Apply it to a route

```typescript
import { Controller, Delete, Param, UseGuards } from "@nestjs/common";
import { RolesGuard } from "../auth/roles.guard";
import { Role, Roles } from "../auth/decorators/roles.decorator";

@Controller("tasks")
export class TasksController {
  @Delete(":id")
  @UseGuards(RolesGuard)
  @Roles(Role.Admin)
  deleteTask(@Param("id") id: string) {
    return `Task ${id} deleted by admin`;
  }
}
```

Guard-order rule to remember:

- `JwtAuthGuard` runs first and populates `req.user`
- `RolesGuard` runs after that and checks `req.user.role`

If you want the runtime story in detail, use [3. NestJS Auth Request Flow](./3_nestjs_auth_request_flow.md).

---

## Part 7: Production Notes

### Use `@nestjs/config` for real secrets

For production, do not depend on a fallback secret in source code. A common upgrade is `JwtModule.registerAsync()`:

```typescript
import { Module } from "@nestjs/common";
import { ConfigModule, ConfigService } from "@nestjs/config";
import { JwtModule } from "@nestjs/jwt";

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    JwtModule.registerAsync({
      inject: [ConfigService],
      useFactory: (configService: ConfigService) => ({
        secret: configService.getOrThrow<string>("JWT_SECRET"),
        signOptions: { expiresIn: "15m" },
      }),
    }),
  ],
})
export class AuthModule {}
```

### Access token vs refresh token

The guide above covers access-token auth. In production, many systems add refresh tokens:

- access token: short-lived, sent on normal API requests
- refresh token: longer-lived, used only to obtain a new access token

Why teams do this:

- short-lived access tokens reduce risk if a token leaks
- users can stay signed in without entering credentials repeatedly

### Common mistakes

- putting sensitive data into the JWT payload
- forgetting to mark login and register as `@Public()` after making JWT auth global
- expecting `req.user` to exist when the guard never ran
- forgetting to add the strategy classes to the module `providers`
- thinking `@nestjs/jwt` and `passport-jwt` do the same job

---

## Quick File Map

| File | Purpose |
| --- | --- |
| `users/users.service.ts` | Creates users and looks them up |
| `users/users.module.ts` | Exports `UsersService` for other modules |
| `auth/constants.ts` | Holds the learning-example JWT secret |
| `auth/auth.service.ts` | Validates users, registers users, signs tokens |
| `auth/local.strategy.ts` | Handles email/password login |
| `auth/jwt.strategy.ts` | Handles bearer token verification |
| `auth/local-auth.guard.ts` | Triggers the local strategy |
| `auth/jwt-auth.guard.ts` | Triggers the JWT strategy and can skip `@Public()` routes |
| `auth/roles.guard.ts` | Checks whether the authenticated user has the required role |
| `auth/auth.controller.ts` | Defines the main auth endpoints |
| `auth/auth.module.ts` | Wires auth dependencies and strategies together |
| `auth/decorators/public.decorator.ts` | Marks routes as public |
| `auth/decorators/roles.decorator.ts` | Declares RBAC metadata |
| `app.module.ts` | Registers JWT auth as a global guard |

---

## Final Revision Anchors

If you only remember a few things, remember these:

- login uses `LocalAuthGuard`
- protected routes use `JwtAuthGuard`
- `validate()` returns the object that becomes `req.user`
- `JwtService` signs tokens, `passport-jwt` verifies them
- `401` means authentication failed, `403` means authorization failed

For runtime narration, go to [3. NestJS Auth Request Flow](./3_nestjs_auth_request_flow.md). For fast recall, go to [4. Auth Revision Cheatsheet](./4_auth_revision_cheatsheet.md).

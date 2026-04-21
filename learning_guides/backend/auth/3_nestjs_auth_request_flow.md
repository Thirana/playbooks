# NestJS Auth Request Flow

Purpose: This note explains what happens at runtime when requests move through NestJS auth built with Passport and JWT.

## Related Notes

- [2. Full Auth Learning Guide](./2_auth_learning_guide.md)
- [1. Auth Core Concepts](./1_auth_core_concepts.md)
- [4. Auth Revision Cheatsheet](./4_auth_revision_cheatsheet.md)

---

## TaskFlow setup used in this note

Assume the app has:

- `POST /auth/register`
- `POST /auth/login`
- `GET /auth/profile`
- `DELETE /tasks/:id` restricted to admins

Assume the JWT payload shape is:

```typescript
{
  sub: user.userId,
  email: user.email,
  role: user.role,
}
```

---

## 1. The high-level request chain

For most NestJS auth flows, the runtime story is:

```text
Request
  -> Guard checks whether authentication should run
  -> Passport strategy handles authentication
  -> validate() returns a user-shaped object
  -> Passport assigns it to req.user
  -> Controller handler runs
```

If authentication fails anywhere in that chain, the route handler does not continue normally.

---

## 2. Register flow

Register is usually public because the user does not have a token yet.

### Runtime sequence

1. Client sends `POST /auth/register` with `{ email, password }`.
2. The route is marked `@Public()`, so the global `JwtAuthGuard` skips JWT verification.
3. The controller calls `AuthService.register(email, password)`.
4. `AuthService` checks whether the user already exists.
5. If the email is new, the password is hashed with `bcrypt`.
6. The user is stored and returned without the password field.

### Why this matters

- registration creates identity
- it does not yet prove identity for later requests
- login is the step that creates the JWT

---

## 3. Login flow

Login is where the local strategy and local guard are used.

### Runtime sequence

1. Client sends `POST /auth/login` with `{ email, password }`.
2. The route is marked `@Public()` so the global JWT guard does not block it.
3. The route also uses `@UseGuards(LocalAuthGuard)`.
4. `LocalAuthGuard` triggers the `local` Passport strategy.
5. `LocalStrategy.validate(email, password)` calls `AuthService.validateUser()`.
6. `AuthService.validateUser()` loads the user and compares the supplied password with the stored hash.
7. If valid, `LocalStrategy.validate()` returns the safe user object.
8. Passport stores that object on `req.user`.
9. The controller handler runs and calls `AuthService.login(req.user)`.
10. `AuthService.login()` signs a JWT and returns `{ access_token: "..." }`.

### Critical observation

By the time the `login()` controller method runs:

- credentials are already validated
- `req.user` already exists
- the controller is only responsible for turning that authenticated user into a token response

---

## 4. Protected route flow

This is the most important runtime path to understand.

### Runtime sequence

1. Client sends `GET /auth/profile`.
2. The request includes `Authorization: Bearer <token>`.
3. The global `JwtAuthGuard` intercepts the request.
4. The guard sees the route is not marked `@Public()`.
5. `JwtAuthGuard` triggers the `jwt` Passport strategy.
6. `passport-jwt` extracts the bearer token from the header.
7. `passport-jwt` verifies the signature using the configured secret.
8. `passport-jwt` checks token expiration.
9. If verification succeeds, Passport calls `JwtStrategy.validate(payload)`.
10. `JwtStrategy.validate()` returns:

```typescript
{
  userId: payload.sub,
  email: payload.email,
  role: payload.role,
}
```

11. Passport attaches that returned object to `req.user`.
12. The controller handler runs and can safely read `req.user`.

### What happens if the token is bad

The handler never gets a valid `req.user` if:

- the header is missing
- the token is malformed
- the signature is invalid
- the token is expired

Those usually result in `401`.

---

## 5. What changes when auth becomes global

Global auth changes the default rule from:

- "protect only the routes you remembered to protect"

to:

- "protect everything unless a route is explicitly public"

### Runtime effect

1. Every request first passes through the globally registered `JwtAuthGuard`.
2. The guard checks whether the route or controller has `isPublic` metadata.
3. If `@Public()` is present, the guard returns `true` and skips JWT verification.
4. If `@Public()` is not present, the guard runs the JWT strategy.

This pattern is safer because new routes are protected by default.

### Common routes that should stay public

- register
- login
- health checks, if your design wants them public

---

## 6. RBAC flow

RBAC only makes sense after authentication succeeds.

### Runtime sequence for an admin-only route

1. Client sends `DELETE /tasks/5` with a valid bearer token.
2. The global `JwtAuthGuard` verifies the token first.
3. `JwtStrategy.validate()` returns a user object containing `role`.
4. Passport stores that object on `req.user`.
5. The route-specific `RolesGuard` runs next.
6. `RolesGuard` reads the required roles from `@Roles(Role.Admin)`.
7. `RolesGuard` compares the required roles with `req.user.role`.
8. If the role matches, the controller handler runs.
9. If the role does not match, the request is rejected with `403`.

### Core rule

- authentication must run before authorization
- otherwise there is no trusted `req.user` to authorize against

---

## 7. Order of execution to memorize

For a protected admin-only route, the simplified order is:

```text
Request
  -> JwtAuthGuard
  -> JwtStrategy.validate()
  -> req.user populated
  -> RolesGuard
  -> Controller handler
```

For the login route, the simplified order is:

```text
Request
  -> LocalAuthGuard
  -> LocalStrategy.validate()
  -> req.user populated
  -> Controller handler
  -> JwtService signs token
```

---

## 8. Common failure points

| Symptom | Likely cause |
| --- | --- |
| `401` on `/auth/login` | Invalid credentials or local strategy rejected the request |
| `401` on a protected route | Missing token, malformed token, expired token, or wrong secret |
| `401` on `/auth/register` or `/auth/login` after making auth global | Route is missing `@Public()` |
| `req.user` is undefined in the controller | Guard never ran or authentication failed before the handler |
| `403` on an admin route | Token is valid, but `req.user.role` does not satisfy `@Roles()` |

---

## 9. Debugging checklist

When auth is failing, check in this order:

1. Is the route supposed to be public or protected?
2. If public, did you add `@Public()` after registering JWT auth globally?
3. If protected, is the `Authorization` header present and in `Bearer <token>` format?
4. Is the same secret used for signing and verification?
5. Does `JwtStrategy.validate()` return the fields the app expects on `req.user`?
6. If RBAC fails, does the token payload contain the role you expect?

Use this note to narrate the flow. Use [4. Auth Revision Cheatsheet](./4_auth_revision_cheatsheet.md) to compress it into quick-recall form.

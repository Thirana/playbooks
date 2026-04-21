# Auth Revision Cheatsheet: NestJS + Passport + JWT

Purpose: This is the shortest note in the set. Use it for fast revision, interview prep, and quick recall during implementation.

## Related Notes

- [2. Full Auth Learning Guide](./2_auth_learning_guide.md)
- [1. Auth Core Concepts](./1_auth_core_concepts.md)
- [3. NestJS Auth Request Flow](./3_nestjs_auth_request_flow.md)

---

## Memorize These First

- Authentication = identity check
- Authorization = permission check
- `LocalAuthGuard` handles login
- `JwtAuthGuard` handles protected routes
- `validate()` returns the object that becomes `req.user`
- `JwtService` signs tokens
- `passport-jwt` verifies bearer tokens
- `401` = not authenticated
- `403` = authenticated but not allowed

---

## JWT Quick Facts

- JWT format: `header.payload.signature`
- Payload is encoded, not encrypted
- Do not put sensitive data in the payload
- `sub` usually stores the user id
- Include only claims you actually need, such as `sub`, `email`, and `role`

Typical payload:

```typescript
{
  sub: user.userId,
  email: user.email,
  role: user.role,
}
```

---

## Runtime Flow in One Glance

### Login

```text
Request -> LocalAuthGuard -> LocalStrategy.validate() -> req.user -> AuthService.login() -> JWT
```

### Protected route

```text
Request -> JwtAuthGuard -> JwtStrategy.validate() -> req.user -> Controller
```

### Admin-only route

```text
Request -> JwtAuthGuard -> req.user -> RolesGuard -> Controller
```

---

## Guard and Strategy Map

| Item | Job |
| --- | --- |
| `LocalAuthGuard` | Triggers the `local` strategy |
| `LocalStrategy` | Validates email and password |
| `JwtAuthGuard` | Triggers the `jwt` strategy |
| `JwtStrategy` | Verifies token payload and shapes `req.user` |
| `RolesGuard` | Checks whether `req.user.role` is allowed |

---

## File Responsibility Map

| File | Main responsibility |
| --- | --- |
| `auth.service.ts` | Register users, validate users, sign JWTs |
| `local.strategy.ts` | Handle login credential validation |
| `jwt.strategy.ts` | Handle bearer token validation |
| `local-auth.guard.ts` | Start local auth flow |
| `jwt-auth.guard.ts` | Start JWT auth flow |
| `roles.guard.ts` | Enforce RBAC |
| `public.decorator.ts` | Mark a route as public |
| `roles.decorator.ts` | Declare required roles |
| `auth.controller.ts` | Expose `/register`, `/login`, `/profile` |
| `auth.module.ts` | Wire strategies, controller, and JWT config |

---

## Common Mistakes

- Hardcoding the JWT secret in production
- Forgetting `@Public()` after making JWT auth global
- Expecting `req.user` without running a guard
- Returning the password field from `validateUser()`
- Putting secrets inside the token payload
- Forgetting to register strategies in the module `providers`

---

## Interview Prompts and Fast Answers

**What is the difference between `@nestjs/jwt` and `passport-jwt`?**

- `@nestjs/jwt` signs tokens with `JwtService`
- `passport-jwt` validates tokens on incoming requests

**Where does `req.user` come from?**

- Passport assigns it from whatever the strategy returns in `validate()`

**Why use `sub`?**

- It is the standard JWT claim for the token subject, usually the user id

**Why can a valid token still get rejected with `403`?**

- Because authentication passed, but authorization failed

**Why use refresh tokens?**

- To keep access tokens short-lived without forcing users to log in again constantly

---

## Production Reminders

- Use `@nestjs/config` and environment variables for `JWT_SECRET`
- Prefer short-lived access tokens
- Add refresh tokens when you need longer user sessions
- Consider extra checks in `JwtStrategy.validate()` for banned or deleted users

---

## Last-Minute Recall

If you are revising in 30 seconds, remember this:

- login uses local auth
- protected routes use JWT auth
- admin routes use JWT auth first, then roles auth
- `401` means auth failed
- `403` means permission failed

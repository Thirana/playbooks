# Auth Core Concepts for NestJS: Passport + JWT

Purpose: This note explains the core ideas behind NestJS auth without walking through the full implementation.

## Related Notes

- [2. Full Auth Learning Guide](./2_auth_learning_guide.md)
- [3. NestJS Auth Request Flow](./3_nestjs_auth_request_flow.md)
- [4. Auth Revision Cheatsheet](./4_auth_revision_cheatsheet.md)

---

## 1. Authentication vs Authorization

These are different steps in the security pipeline.

- **Authentication** asks: "Who are you?"
- **Authorization** asks: "What are you allowed to do?"

TaskFlow examples:

- Login with email and password -> authentication
- Check whether the logged-in user is an `admin` -> authorization

Why people mix them up:

- both happen around protected routes
- both can reject a request
- but they fail for different reasons and often return different status codes

---

## 2. What a JWT actually is

A JWT is a signed token with three parts:

```text
header.payload.signature
```

- **Header**: tells you the signing algorithm
- **Payload**: contains claims such as `sub`, `email`, or `role`
- **Signature**: proves the token was signed with the server secret

Important truths:

- the payload is encoded, not encrypted
- anyone holding the token can decode the payload
- sensitive data should never go inside the payload

Typical TaskFlow payload:

```typescript
{
  sub: user.userId,
  email: user.email,
  role: user.role,
}
```

Why `sub` matters:

- `sub` means "subject"
- it is the standard JWT claim for the principal the token refers to
- in most apps that is the user id

---

## 3. Signing vs verifying

This distinction matters a lot in NestJS auth.

### Signing

Signing happens when login succeeds.

- `AuthService.login()` creates the payload
- `JwtService.sign()` or `signAsync()` produces the token
- this usually uses `@nestjs/jwt`

### Verifying

Verification happens on later requests to protected routes.

- `passport-jwt` extracts the bearer token from the request
- it checks the signature and expiration
- only then does the request continue

Short version:

- `@nestjs/jwt` helps create tokens
- `passport-jwt` helps validate tokens on incoming requests

---

## 4. Why JWT is called stateless

A JWT-based system is often called stateless because the server does not need to store a session record for each logged-in user.

Instead:

- the client stores the token
- the server trusts the token only after verification
- the token already carries the claims needed for most auth checks

Important nuance:

- stateless does **not** mean "never check the database"
- many real systems still look up the user in `JwtStrategy.validate()` to confirm the account still exists, is active, or is not banned

So the better mental model is:

- JWT removes server-side session storage
- JWT does not remove all server-side validation

---

## 5. What Passport does in NestJS

Passport is the engine that coordinates authentication strategies.

In NestJS, Passport is wrapped by `@nestjs/passport`, which makes it fit nicely into Nest modules, providers, and guards.

Core runtime shape:

```text
Request -> Guard -> Strategy -> validate() -> req.user
```

That chain explains most auth behavior in NestJS.

---

## 6. Strategy vs guard

These two roles are easy to confuse.

### Strategy

A strategy defines **how** authentication is performed.

Examples:

- local strategy -> validate email and password
- jwt strategy -> validate a bearer token

### Guard

A guard decides whether a route should run and can trigger a strategy.

Examples:

- `LocalAuthGuard` triggers the `local` strategy
- `JwtAuthGuard` triggers the `jwt` strategy

Short memory trick:

- strategy = auth logic
- guard = route gate

---

## 7. What `validate()` does

### In `LocalStrategy`

`validate(email, password)` receives credentials from the request body.

Its job is to:

- find the user
- compare the password
- return the safe user object if valid
- throw `UnauthorizedException` if invalid

### In `JwtStrategy`

`validate(payload)` runs after the token has already been verified.

Its job is to:

- transform the payload into the application user shape
- optionally perform extra checks, such as ensuring the user still exists

Common misunderstanding:

- you do not manually call `validate()`
- Passport calls it for you when the matching guard runs

---

## 8. Where `req.user` comes from

`req.user` is attached by Passport.

More precisely:

- the guard runs the strategy
- the strategy returns a value from `validate()`
- Passport stores that returned value on `req.user`

That means:

- if the guard never ran, `req.user` will not exist
- if the strategy throws, the controller handler never gets a valid `req.user`

---

## 9. `401` vs `403`

These two responses mean different failures.

### `401 Unauthorized`

The request is not properly authenticated.

Examples:

- missing token
- invalid token
- expired token
- bad login credentials

### `403 Forbidden`

The request is authenticated, but the user is not allowed to do the action.

Example:

- a normal user tries to access an admin-only route

Fast rule:

- failed identity check -> `401`
- failed permission check -> `403`

---

## 10. Why secrets belong in environment config

The JWT secret is effectively the authority to mint valid tokens.

If it leaks:

- an attacker can forge tokens
- the server may accept those fake tokens as real

That is why production systems usually use:

- `.env` or platform environment variables
- `@nestjs/config`
- `JwtModule.registerAsync()` for configuration wiring

Avoid:

- hardcoded secrets committed to source control
- sharing the same secret casually across unrelated services

---

## 11. Concept checkpoints

If you can answer these quickly, your foundation is solid:

- What is the difference between authentication and authorization?
- What is the difference between `@nestjs/jwt` and `passport-jwt`?
- What does `validate()` return and where does that value go?
- Why is `sub` usually used for the user id?
- Why can a route return `403` even when the token is valid?

If you want the runtime version of these answers, use [3. NestJS Auth Request Flow](./3_nestjs_auth_request_flow.md).

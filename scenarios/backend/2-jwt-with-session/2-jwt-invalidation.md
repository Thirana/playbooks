## Question 2

### "A user logs in from a browser and receives a JWT with a 15-minute expiry and a refresh token valid for 30 days. The user reports their laptop stolen. How do you immediately invalidate all their active sessions without breaking sessions on their phone?"

---

### The Naive Solution

Delete the user's refresh token from the database. Their laptop session can no longer get new access tokens after the current one expires in 15 minutes.

---

### Problems with the Naive Solution

**The 15-minute window is still exploitable.** A stolen laptop with an active access token can make authenticated requests for up to 15 minutes — enough to read messages, export data, or make transactions.

**"Delete the refresh token" is ambiguous for multiple sessions.** If the user has refresh tokens for browser, phone, and tablet, and you delete all of them, you invalidate the phone too — breaking legitimate sessions. If you delete only the "laptop" one, how do you know which one that is?

**There is no mechanism to kill the access token before it expires.** Standard JWTs are stateless — the server does not track them. A valid token will be accepted until it expires, regardless of what you do to the database.

---

### Production-Grade Solution

The solution requires three things working together: **per-device refresh tokens**, **a token version / revocation mechanism for immediate access token invalidation**, and **a session management UI**.

#### Architecture Overview

```
Browser (laptop)          API Server             Database / Redis
     |                       |                        |
     | Login                 |                        |
     |---------------------->|                        |
     |                       | Create session record  |
     |                       | sessionId: uuid-A      |
     |                       | device: "Chrome/Mac"   |
     |                       | userId: 42             |
     |                       |----------------------->|
     |                       |                        | sessions table
     |  access_token (JWT)   |                        | row: uuid-A
     |  refresh_token: uuid-A|                        |
     |<----------------------|                        |
     |                       |                        |
     | (phone logs in separately, gets session uuid-B)|
     |                       |                        |
     | User reports laptop stolen                     |
     |                       |                        |
     | POST /auth/sessions/uuid-A/revoke              |
     |---------------------->|                        |
     |                       | Mark uuid-A revoked    |
     |                       | Increment tokenVersion |
     |                       | for user 42            |
     |                       |----------------------->|
     |                       |                        |
     | Next request from laptop with old access_token |
     |---------------------->|                        |
     |                       | Decode JWT             |
     |                       | Check tokenVersion     |
     |                       | JWT version < current  |
     |  401 Unauthorized     | version → REJECT       |
     |<----------------------|                        |
```

#### Step 1 — The Sessions Table

Each login creates a session record, tied to a device.

```sql
CREATE TABLE sessions (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_info VARCHAR(255),        -- "Chrome on MacOS", "iOS Safari"
  ip_address  VARCHAR(45),
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  last_used_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at  TIMESTAMPTZ NOT NULL,
  revoked_at  TIMESTAMPTZ,         -- NULL = active, non-null = revoked
  revoked_reason VARCHAR(100)      -- "user_request", "admin", "password_change"
);
```

#### Step 2 — The Users Table Gets a tokenVersion Column

```sql
ALTER TABLE users ADD COLUMN token_version INTEGER NOT NULL DEFAULT 0;
```

Every time a user's access tokens should be universally invalidated (password change, account compromise), increment this number. All existing JWTs with an older version become invalid instantly.

#### Step 3 — The JWT Payload Includes Both sessionId and tokenVersion

```typescript
// src/auth/auth.service.ts

async login(user: User, deviceInfo: string, ipAddress: string): Promise<LoginResponse> {

  // Create a session record for this specific device login
  const session = await this.sessionsRepo.save({
    userId: user.id,
    deviceInfo,
    ipAddress,
    expiresAt: addDays(new Date(), 30),
  });

  // Include tokenVersion in the payload.
  // When the server receives this JWT later, it checks whether the
  // current tokenVersion in the DB still matches this value.
  const payload = {
    sub: user.id,
    email: user.email,
    role: user.role,
    sessionId: session.id,       // Which device session this token belongs to
    tokenVersion: user.tokenVersion, // Current version at time of login
  };

  const accessToken = await this.jwtService.signAsync(payload, {
    expiresIn: '15m',
  });

  // The refresh token IS the session ID — a UUID stored in the DB.
  // It has no information value if stolen — it is just a lookup key.
  return {
    access_token: accessToken,
    refresh_token: session.id,   // The UUID references the sessions table row
  };
}
```

#### Step 4 — The JWT Strategy Checks tokenVersion on Every Request

```typescript
// src/auth/jwt.strategy.ts

async validate(payload: JwtPayload): Promise<RequestUser> {

  // On every authenticated request, check:
  // 1. Does this session still exist and is it not revoked?
  // 2. Does the token's version match the user's current version?
  // This adds one DB/cache read per request — use Redis to keep it fast.

  const [session, user] = await Promise.all([
    this.sessionsRepo.findOneBy({ id: payload.sessionId }),
    this.usersRepo.findOneBy({ id: payload.sub }),
  ]);

  // Session was revoked (laptop reported stolen)
  if (!session || session.revokedAt !== null) {
    throw new UnauthorizedException('Session has been revoked');
  }

  // tokenVersion mismatch — a global revocation happened
  // (password change, security event)
  if (user.tokenVersion !== payload.tokenVersion) {
    throw new UnauthorizedException('Token has been invalidated');
  }

  // Update last used time for session activity tracking
  await this.sessionsRepo.update(session.id, { lastUsedAt: new Date() });

  return { userId: user.id, email: user.email, role: user.role };
}
```

**Performance note**: This adds a DB lookup on every request. Cache the session and user token version in Redis with a short TTL (e.g., 60 seconds). A revocation invalidates the cache key immediately — worst case, a revoked token works for up to 60 more seconds, which is an acceptable trade-off. For zero-tolerance scenarios (banking), skip the cache and always hit the DB.

```typescript
// Redis-cached version of the session check
async validate(payload: JwtPayload): Promise<RequestUser> {
  const cacheKey = `session:${payload.sessionId}`;
  let sessionStatus = await this.cache.get<string>(cacheKey);

  if (!sessionStatus) {
    const session = await this.sessionsRepo.findOneBy({ id: payload.sessionId });
    sessionStatus = session?.revokedAt ? 'revoked' : 'active';
    await this.cache.set(cacheKey, sessionStatus, 60_000); // 60-second cache
  }

  if (sessionStatus === 'revoked') {
    throw new UnauthorizedException('Session has been revoked');
  }

  // tokenVersion check still needs the user record
  // (can also be cached separately under user:42:tokenVersion)
  ...
}
```

#### Step 5 — The Revocation Endpoint

```typescript
// src/auth/auth.controller.ts

@Delete('sessions/:sessionId')
@UseGuards(JwtAuthGuard)
async revokeSession(
  @Param('sessionId') sessionId: string,
  @Request() req,
) {
  await this.authService.revokeSession(sessionId, req.user.userId);
  return { message: 'Session revoked' };
}

@Delete('sessions')
@UseGuards(JwtAuthGuard)
async revokeAllOtherSessions(@Request() req) {
  // "Log out all other devices" — keeps only the current session active
  await this.authService.revokeAllExcept(req.user.userId, req.user.sessionId);
  return { message: 'All other sessions revoked' };
}
```

```typescript
// src/auth/auth.service.ts

async revokeSession(sessionId: string, requestingUserId: number): Promise<void> {
  const session = await this.sessionsRepo.findOneBy({ id: sessionId });

  // Prevent a user from revoking someone else's session
  if (!session || session.userId !== requestingUserId) {
    throw new ForbiddenException();
  }

  await this.sessionsRepo.update(sessionId, {
    revokedAt: new Date(),
    revokedReason: 'user_request',
  });

  // Immediately invalidate the Redis cache for this session
  await this.cache.del(`session:${sessionId}`);
}
```

#### Step 6 — Session Management UI (What the User Sees)

```typescript
// GET /auth/sessions → returns all active sessions for the user
// Response:
[
  {
    id: "uuid-A",
    deviceInfo: "Chrome on MacOS",
    ipAddress: "192.168.1.5",
    lastUsedAt: "2025-04-20T08:30:00Z",
    isCurrent: false, // This is the stolen laptop — show "Revoke" button
  },
  {
    id: "uuid-B",
    deviceInfo: "Safari on iPhone",
    ipAddress: "10.0.0.1",
    lastUsedAt: "2025-04-20T12:45:00Z",
    isCurrent: true, // The session making this request — show "This device"
  },
];
```

#### How Each Requirement Is Met

| Requirement                                            | Mechanism                                                                           |
| ------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| Immediately invalidate laptop                          | Revoke session uuid-A → Redis cache invalidated → next request from laptop rejected |
| Do not break phone                                     | Session uuid-B is untouched — phone continues with its own refresh token            |
| Access token invalidated before 15-min expiry          | `tokenVersion` check in JWT strategy catches it on the very next request            |
| User can see all sessions                              | `GET /auth/sessions` shows all active sessions with device and IP info              |
| One device compromise does not require password change | Revoke only that session — other sessions are unaffected                            |

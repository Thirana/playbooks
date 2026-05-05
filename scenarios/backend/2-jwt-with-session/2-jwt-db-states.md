# JWT Invalidation — Database States Before & After Revocation

This document walks through the exact DB and Redis records at each stage of the stolen laptop scenario.

---

## Scenario

- User **id: 42** logs in from a laptop (Chrome/Mac) → session `uuid-A`
- User **id: 42** logs in from a phone (Safari/iPhone) → session `uuid-B`
- User reports laptop stolen → revokes session `uuid-A`

---

## Stage 1 — After Laptop Login

**`users` table**

| id | email | token_version |
|----|-------|---------------|
| 42 | alice@example.com | 0 |

> `token_version = 0` — no global revocation has happened yet.

---

**`sessions` table**

| id | user_id | device_info | ip_address | created_at | last_used_at | expires_at | revoked_at | revoked_reason |
|----|---------|-------------|------------|------------|--------------|------------|------------|----------------|
| uuid-A | 42 | Chrome on MacOS | 203.0.113.5 | 2025-04-20 08:00 | 2025-04-20 08:00 | 2025-05-20 08:00 | **NULL** | **NULL** |

> `revoked_at = NULL` means the session is active.

---

**JWT issued to laptop**

```json
{
  "sub": 42,
  "email": "alice@example.com",
  "role": "user",
  "sessionId": "uuid-A",
  "tokenVersion": 0,
  "exp": 1713603600
}
```

> Both `sessionId` and `tokenVersion` are baked into the token at login time.

---

**Redis**

| Key | Value | TTL |
|-----|-------|-----|
| `session:uuid-A` | `"active"` | 60s |

---

## Stage 2 — After Phone Login (Second Device)

**`users` table** — unchanged

| id | email | token_version |
|----|-------|---------------|
| 42 | alice@example.com | 0 |

---

**`sessions` table** — new row added for phone

| id | user_id | device_info | ip_address | created_at | last_used_at | expires_at | revoked_at | revoked_reason |
|----|---------|-------------|------------|------------|--------------|------------|------------|----------------|
| uuid-A | 42 | Chrome on MacOS | 203.0.113.5 | 2025-04-20 08:00 | 2025-04-20 08:00 | 2025-05-20 08:00 | NULL | NULL |
| **uuid-B** | **42** | **Safari on iPhone** | **10.0.0.1** | **2025-04-20 09:00** | **2025-04-20 09:00** | **2025-05-20 09:00** | **NULL** | **NULL** |

> Each device gets its own row. The phone session is completely independent of the laptop session.

---

**Redis**

| Key | Value | TTL |
|-----|-------|-----|
| `session:uuid-A` | `"active"` | 60s |
| `session:uuid-B` | `"active"` | 60s |

---

## Stage 3 — User Revokes the Laptop Session

User calls:
```
DELETE /auth/sessions/uuid-A
Authorization: Bearer <phone's JWT>
```

The service runs:
```sql
UPDATE sessions
SET revoked_at = NOW(), revoked_reason = 'user_request'
WHERE id = 'uuid-A';
```

Then immediately:
```
Redis: DEL session:uuid-A
```

---

**`users` table** — unchanged (this was a single-session revoke, not a global one)

| id | email | token_version |
|----|-------|---------------|
| 42 | alice@example.com | 0 |

---

**`sessions` table** — only uuid-A row is updated

| id | user_id | device_info | ip_address | created_at | last_used_at | expires_at | revoked_at | revoked_reason |
|----|---------|-------------|------------|------------|--------------|------------|------------|----------------|
| uuid-A | 42 | Chrome on MacOS | 203.0.113.5 | 2025-04-20 08:00 | 2025-04-20 08:00 | 2025-05-20 08:00 | **2025-04-20 12:00** | **"user_request"** |
| uuid-B | 42 | Safari on iPhone | 10.0.0.1 | 2025-04-20 09:00 | 2025-04-20 09:00 | 2025-05-20 09:00 | NULL | NULL |

> The phone row (`uuid-B`) is untouched. `revoked_at` on `uuid-A` is now set.

---

**Redis after revocation**

| Key | Value | TTL |
|-----|-------|-----|
| ~~`session:uuid-A`~~ | ~~`"active"`~~ | **deleted** |
| `session:uuid-B` | `"active"` | 60s |

> `session:uuid-A` is explicitly deleted. Next request from the laptop triggers a DB lookup, finds `revoked_at IS NOT NULL`, and rejects the token immediately — no waiting for the 60s cache TTL.

---

## Stage 4 — What Happens on the Next Request from Each Device

### Laptop (stolen) — next API request

JWT strategy runs `validate()`:

```
1. Look up Redis: GET session:uuid-A  →  cache miss (key was deleted)
2. Fall through to DB: SELECT * FROM sessions WHERE id = 'uuid-A'
3. session.revokedAt = 2025-04-20 12:00  →  NOT NULL
4. throw UnauthorizedException('Session has been revoked')
```

**Result: 401 Unauthorized — immediately, regardless of the JWT expiry.**

---

### Phone — next API request

JWT strategy runs `validate()`:

```
1. Look up Redis: GET session:uuid-B  →  "active"
2. tokenVersion in JWT = 0, user.tokenVersion = 0  →  match ✓
3. Request proceeds normally
```

**Result: 200 OK — phone is completely unaffected.**

---

## Bonus — Global Revocation (e.g. Password Change)

If the user changes their password, you want to invalidate ALL sessions on ALL devices at once, including the phone.

```sql
UPDATE users SET token_version = token_version + 1 WHERE id = 42;
```

**`users` table** — token_version incremented

| id | email | token_version |
|----|-------|---------------|
| 42 | alice@example.com | **1** |

All existing JWTs still carry `tokenVersion: 0`. The JWT strategy check:

```
user.tokenVersion (1) !== payload.tokenVersion (0)  →  REJECT
```

Every device — laptop, phone, tablet — gets a 401 on their next request. They are all forced to log in again.

> No need to touch the `sessions` table rows individually. Incrementing one integer invalidates every outstanding token across every device instantly.

---

## Summary — Which Column Does What

| Column / Key | What it controls |
|---|---|
| `sessions.revoked_at` | Kills one specific device session |
| `users.token_version` | Kills all sessions for a user globally |
| `Redis session:{id}` | Cache of session status — deleted on revoke to force immediate DB re-check |

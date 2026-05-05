# API Key System — Database States & Request Flows

This document walks through the exact DB and Redis records at each stage, and shows how each field is used during a real request.

---

## Scenario

- **Alice** (user id: 1) creates two API keys for workspace `ws-abc`:
  - Key A — `Production CI pipeline` — scoped to `tasks:read`, `tasks:create` — no expiry
  - Key B — `Temp contractor access` — scoped to `tasks:read` only — expires in 7 days
- An incoming request arrives using Key A → should be allowed to create tasks
- An incoming request arrives using Key B trying to create a task → should be rejected (wrong scope)
- Alice revokes Key B early (contractor engagement ended)
- A request arrives using the revoked Key B → should be rejected immediately

---

## Stage 1 — Before Any Keys Are Created

**`api_keys` table** — empty

| id | user_id | workspace_id | name | key_prefix | key_hash | scopes | expires_at | last_used_at | revoked_at |
|----|---------|-------------|------|------------|----------|--------|------------|-------------|------------|
| _(empty)_ | | | | | | | | | |

**Redis** — no cache entries

---

## Stage 2 — Alice Creates Key A (CI Pipeline)

Alice calls `POST /api-keys` with:
```json
{ "name": "Production CI pipeline", "scopes": ["tasks:read", "tasks:create"] }
```

Inside `createApiKey()`, the service generates:

```
randomBytes(32) → base64url → "xK9mP2nR7qL4vB1wY8..."  (48 chars)
fullKey         → "tkf_live_xK9mP2nR7qL4vB1wY8..."
keyPrefix       → "tkf_live_xK9mP2nR" (first 20 chars — used as DB lookup key)
keyHash         → SHA-256("tkf_live_xK9mP2nR7qL4...") = "3a7f9c2e1b..."  (64 hex chars)
```

Only `keyPrefix` and `keyHash` go into the database. The `fullKey` is returned in the response **once** and then gone forever.

**`api_keys` table** after insert:

| id | user_id | workspace_id | name | key_prefix | key_hash | scopes | expires_at | created_at | last_used_at | revoked_at |
|----|---------|-------------|------|------------|----------|--------|------------|------------|-------------|------------|
| uuid-key-A | 1 | ws-abc | Production CI pipeline | `tkf_live_xK9mP2nR` | `3a7f9c2e1b...` | `{tasks:read, tasks:create}` | NULL | 2025-04-20 10:00 | NULL | NULL |

> `key_hash` is a 64-character SHA-256 hex string. The full key (`tkf_live_xK9mP2nR7qL4...`) does not appear anywhere in this table. `expires_at = NULL` means this key never expires. `revoked_at = NULL` means it is active.

**API response to Alice** — the only time the full key ever appears:

```json
{
  "id": "uuid-key-A",
  "name": "Production CI pipeline",
  "key": "tkf_live_xK9mP2nR7qL4vB1wY8...",
  "keyPrefix": "tkf_live_xK9mP2nR",
  "scopes": ["tasks:read", "tasks:create"],
  "createdAt": "2025-04-20T10:00:00Z",
  "message": "Save this key now. It will not be shown again."
}
```

> After Alice closes this response, the full key is gone. Future `GET /api-keys` calls return only `id`, `name`, `keyPrefix`, `scopes`, `lastUsedAt` — never `keyHash` or the full key.

---

## Stage 3 — Alice Creates Key B (Contractor Access)

Alice calls `POST /api-keys` with:
```json
{ "name": "Temp contractor access", "scopes": ["tasks:read"], "expiresAt": "2025-04-27T10:00:00Z" }
```

A different random body is generated:
```
fullKey   → "tkf_live_mQ3tW6rZ1pN8..."
keyPrefix → "tkf_live_mQ3tW6rZ1p"
keyHash   → SHA-256("tkf_live_mQ3tW6rZ1pN8...") = "b4e8d1f7a2..."
```

**`api_keys` table** — second row added:

| id | user_id | workspace_id | name | key_prefix | key_hash | scopes | expires_at | created_at | last_used_at | revoked_at |
|----|---------|-------------|------|------------|----------|--------|------------|------------|-------------|------------|
| uuid-key-A | 1 | ws-abc | Production CI pipeline | `tkf_live_xK9mP2nR` | `3a7f9c2e1b...` | `{tasks:read, tasks:create}` | NULL | 2025-04-20 10:00 | NULL | NULL |
| uuid-key-B | 1 | ws-abc | Temp contractor access | `tkf_live_mQ3tW6rZ1p` | `b4e8d1f7a2...` | `{tasks:read}` | 2025-04-27 10:00 | 2025-04-20 10:05 | NULL | NULL |

> Each key is an independent row. Revoking Key B has zero effect on Key A — they share no state. `expires_at` is set on Key B; the service checks this field during verification.

---

## Stage 4 — Valid Request Using Key A

The CI pipeline sends:
```
POST /tasks
Authorization: ApiKey tkf_live_xK9mP2nR7qL4vB1wY8...
```

**Inside `verifyKey()`:**

```
Step 1: Extract prefix
  incomingKey.substring(0, 20) → "tkf_live_xK9mP2nR"

Step 2: Check Redis
  GET api-key:tkf_live_xK9mP2nR  →  cache miss (first request)

Step 3: DB lookup
  SELECT * FROM api_keys
  WHERE key_prefix = 'tkf_live_xK9mP2nR'
    AND revoked_at IS NULL
  → Returns the uuid-key-A row

Step 4: Cache the DB record
  SET api-key:tkf_live_xK9mP2nR = { uuid-key-A record }  TTL=5min

Step 5: Hash the incoming key
  SHA-256("tkf_live_xK9mP2nR7qL4vB1wY8...") → "3a7f9c2e1b..."

Step 6: timingSafeEqual("3a7f9c2e1b...", "3a7f9c2e1b...")  →  match ✓

Step 7: Check expiry
  expires_at = NULL  →  no expiry, skip

Step 8: Update last_used_at (async — does not block the request)
  UPDATE api_keys SET last_used_at = NOW(), last_used_ip = '10.0.0.5'
  WHERE id = 'uuid-key-A'

Step 9: Return resolved user context
  { userId: 1, workspaceId: 'ws-abc', scopes: ['tasks:read', 'tasks:create'], authMethod: 'api-key' }
```

**`api_keys` table** — only `last_used_at` changes (async, after response):

| id | key_prefix | scopes | expires_at | last_used_at | revoked_at |
|----|------------|--------|------------|-------------|------------|
| uuid-key-A | `tkf_live_xK9mP2nR` | `{tasks:read, tasks:create}` | NULL | **2025-04-20 11:30** | NULL |
| uuid-key-B | `tkf_live_mQ3tW6rZ1p` | `{tasks:read}` | 2025-04-27 10:00 | NULL | NULL |

**Redis** after the request:

| Key | Value | TTL |
|-----|-------|-----|
| `api-key:tkf_live_xK9mP2nR` | `{ uuid-key-A record }` | 5 min |

**`ApiKeyScopeGuard` check:**
```
Route requires: ["tasks:create"]
user.scopes = ["tasks:read", "tasks:create"]
"tasks:create" ∈ scopes  →  true ✓
```

**Result: 200 OK** — task is created.

---

## Stage 5 — Key B Tries to Create a Task (Wrong Scope)

The contractor sends:
```
POST /tasks
Authorization: ApiKey tkf_live_mQ3tW6rZ1pN8...
```

`verifyKey()` succeeds — the key exists, the hash matches, it is not expired. Returns:
```json
{ "userId": 1, "scopes": ["tasks:read"], "authMethod": "api-key" }
```

**`ApiKeyScopeGuard` check:**
```
Route requires: ["tasks:create"]
user.scopes = ["tasks:read"]
"tasks:create" ∉ scopes  →  false ✗
throw ForbiddenException("This API key does not have the required scope: tasks:create")
```

**Result: 403 Forbidden** — the controller method is never called. The key itself is valid; only the scope is insufficient.

> Key B can still call `GET /tasks` (requires `tasks:read`) successfully. The scope restricts the operation, not the key's existence.

---

## Stage 6 — Alice Revokes Key B

Alice calls:
```
DELETE /api-keys/uuid-key-B
Authorization: Bearer <Alice's JWT>
```

Inside `revokeKey()`:
```sql
UPDATE api_keys
SET revoked_at = NOW(), revoked_by = 1, revoked_reason = 'user_request'
WHERE id = 'uuid-key-B';
```

Then immediately:
```
Redis: DEL api-key:tkf_live_mQ3tW6rZ1p
```

**`api_keys` table** — only Key B row is updated:

| id | key_prefix | scopes | expires_at | last_used_at | revoked_at | revoked_by | revoked_reason |
|----|------------|--------|------------|-------------|------------|------------|----------------|
| uuid-key-A | `tkf_live_xK9mP2nR` | `{tasks:read, tasks:create}` | NULL | 2025-04-20 11:30 | **NULL** | NULL | NULL |
| uuid-key-B | `tkf_live_mQ3tW6rZ1p` | `{tasks:read}` | 2025-04-27 10:00 | NULL | **2025-04-21 09:00** | **1** | **"user_request"** |

> Key A row is completely untouched. The `revoked_at`, `revoked_by`, `revoked_reason` columns are only for auditing — who revoked it, when, and why. The partial index (`WHERE revoked_at IS NULL`) on `key_prefix` now excludes Key B, so it will not be found in future DB lookups.

**Redis after revocation:**

| Key | Value | TTL |
|-----|-------|-----|
| `api-key:tkf_live_xK9mP2nR` | `{ uuid-key-A record }` | 5 min |
| ~~`api-key:tkf_live_mQ3tW6rZ1p`~~ | ~~`{ uuid-key-B record }`~~ | **deleted** |

> The explicit `DEL` forces the next request to go to the DB immediately — it does not wait for the 5-minute TTL. This is the same pattern used in the JWT session revocation system.

---

## Stage 7 — Request Arrives Using the Revoked Key B

The contractor (unaware the key was revoked) sends:
```
GET /tasks
Authorization: ApiKey tkf_live_mQ3tW6rZ1pN8...
```

**Inside `verifyKey()`:**
```
Step 1: Extract prefix → "tkf_live_mQ3tW6rZ1p"

Step 2: Check Redis
  GET api-key:tkf_live_mQ3tW6rZ1p  →  cache miss (key was deleted on revoke)

Step 3: DB lookup
  SELECT * FROM api_keys
  WHERE key_prefix = 'tkf_live_mQ3tW6rZ1p'
    AND revoked_at IS NULL          ← this condition excludes Key B
  → 0 rows returned

Step 4: cachedRecord = null → return null

ApiKeyStrategy.validate() receives null → throw UnauthorizedException
```

**Result: 401 Unauthorized** — immediately, no hash computation even needed.

> The `AND revoked_at IS NULL` in the query does the heavy lifting. The partial index on `key_prefix WHERE revoked_at IS NULL` means the revoked key is not even visible to the lookup query.

---

## Stage 8 — Key B Expires Naturally (If Not Revoked)

If Alice had not revoked Key B manually, the expiry check inside `verifyKey()` would catch it:

```
Step 5 (hash matched, record found):
  cachedRecord.expiresAt = 2025-04-27 10:00
  new Date()              = 2025-04-28 09:00
  expiresAt < new Date()  →  true  →  return null
```

**Result: 401 Unauthorized** — the record exists in the DB and may still be in Redis cache, but the expiry check rejects it before the user context is returned.

> Unlike revocation (which deletes the Redis key), natural expiry relies on the service-layer check. The DB row is never deleted — it stays for audit purposes.

---

## Summary — Which Field Does What at Request Time

| Field / Key | When it is read | What it decides |
|---|---|---|
| `key_prefix` | On every request — extracted from incoming key | Lookup key into the DB/Redis (the index handle) |
| `key_hash` | After DB/cache hit — compared with `SHA-256(incomingKey)` | Verifies the key is genuine, not just a prefix guess |
| `scopes` | After hash verification — read by `ApiKeyScopeGuard` | Which operations this key is allowed to call |
| `expires_at` | After hash verification | Time-bounds the key's validity independent of revocation |
| `revoked_at` | DB query filter (`WHERE revoked_at IS NULL`) + cache deletion | Hard-stops a key immediately when revoked |
| `last_used_at` / `last_used_ip` | Written async after each valid request | Audit trail — when and from where the key was last used |
| `revoked_by` / `revoked_reason` | Written on revocation | Audit trail — who revoked it and why |
| `Redis api-key:{prefix}` | Checked before every DB hit | Caches the full key record; deleted on revoke to force immediate DB re-check |

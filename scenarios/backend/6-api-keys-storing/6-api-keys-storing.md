## "You need to implement an API key system for third-party integrations. API keys must be shown to the user only once at creation, stored securely, and be revocable per key without affecting others. How do you design the storage and verification of these keys?"

---

### The Naive Solution

Generate a random string, store it in a `api_keys` table as plain text, and look it up on every request with `SELECT * FROM api_keys WHERE key = ?`.

```sql
CREATE TABLE api_keys (
  id SERIAL PRIMARY KEY,
  user_id INTEGER,
  key VARCHAR(64),   -- stored as plain text
  created_at TIMESTAMPTZ
);
```

---

### Problems with the Naive Solution

**Plain text storage means a database breach exposes all keys.** An attacker who dumps the `api_keys` table gets every active key for every user — they can immediately impersonate all integrations. This is the same reason you never store plain text passwords.

**Lookup by full key scans every row** unless the key column is indexed. Even indexed, lookups on long random strings are slower than they need to be.

**No metadata.** Plain text keys have no name, no scope, no expiry, no last-used tracking — impossible to audit or manage.

**No structure to the key.** When a leaked key appears in a GitHub commit or log file, you cannot tell which user it belongs to or which service it grants access to without a full table scan.

---

### Production-Grade Solution

The design mirrors how services like GitHub, Stripe, and AWS IAM handle API keys. The key insight is: **store a hash of the key, never the key itself.** When verifying, hash the incoming key and compare hashes — the plaintext never touches your database.

#### The Architecture

```
Key Creation:
  Generate prefix (tkf_live_) + random bytes
         |
         v
  Show FULL key to user ONCE — never again
         |
         v
  Hash the key with SHA-256
         |
         v
  Store: prefix + first 8 chars (for display) + hash + metadata


Key Verification:
  Incoming request: Authorization: ApiKey tkf_live_a1b2c3d4...
         |
         v
  Extract prefix → look up by prefix in DB (fast, indexed)
         |
         v
  Hash the incoming key
         |
         v
  Compare hash with stored hash (constant-time comparison)
         |
         v
  Attach user/scope to request
```

#### Step 1 — The Database Schema

```sql
CREATE TABLE api_keys (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  workspace_id  UUID REFERENCES workspaces(id) ON DELETE CASCADE,

  -- Human-readable name set by the user: "Production integration", "CI pipeline"
  name          VARCHAR(255) NOT NULL,

  -- The key prefix — first 12 characters of the full key.
  -- Used as the lookup index. Shown in the UI so users can identify which key is which.
  -- e.g., "tkf_live_a1b2"
  key_prefix    VARCHAR(20) UNIQUE NOT NULL,

  -- SHA-256 hash of the full key. The full key is NEVER stored.
  key_hash      VARCHAR(64) NOT NULL,

  -- Scopes limit what this key can do — like OAuth2 scopes
  -- e.g., ["tasks:read", "tasks:create"] — cannot do tasks:delete
  scopes        TEXT[] NOT NULL DEFAULT '{}',

  -- Optional expiry — some integrations should be time-limited
  expires_at    TIMESTAMPTZ,

  -- Audit fields
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  last_used_at  TIMESTAMPTZ,
  last_used_ip  VARCHAR(45),
  revoked_at    TIMESTAMPTZ,
  revoked_by    INTEGER REFERENCES users(id),
  revoked_reason VARCHAR(100)
);

-- Index on key_prefix for fast lookups on every incoming request
CREATE INDEX idx_api_keys_prefix ON api_keys(key_prefix)
  WHERE revoked_at IS NULL;  -- Partial index — only active keys
```

#### Step 2 — Key Generation

The key format has three parts: **environment prefix** + **random bytes** + nothing stored.

```
tkf_live_a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6
|______|  |________________________________|
prefix        48 chars of random bytes
              (base62 encoded — URL safe)
```

The prefix (`tkf_live_`, `tkf_test_`) tells users at a glance which environment the key belongs to. This is how Stripe prefixes keys (`sk_live_`, `sk_test_`). It also helps you build monitoring rules — if a `tkf_test_` key is detected in a production request, you can flag it.

```typescript
// src/api-keys/api-keys.service.ts
import { createHash, randomBytes, timingSafeEqual } from "crypto";

@Injectable()
export class ApiKeysService {
  constructor(
    @InjectRepository(ApiKey)
    private readonly apiKeysRepo: Repository<ApiKey>,
    @Inject(CACHE_MANAGER)
    private readonly cache: Cache,
  ) {}

  async createApiKey(
    userId: number,
    workspaceId: string,
    name: string,
    scopes: string[],
    expiresAt?: Date,
  ): Promise<{ key: string; record: ApiKey }> {
    // Step 1: Generate the raw key
    // 32 random bytes → base62 string → 48-character key body
    const rawKeyBody = randomBytes(32).toString("base64url"); // URL-safe base64
    const environment = process.env.NODE_ENV === "production" ? "live" : "test";
    const fullKey = `tkf_${environment}_${rawKeyBody}`;
    // e.g., tkf_live_a1b2c3d4e5f6g7h8...

    // Step 2: Extract prefix for lookup (first 20 chars of full key)
    const keyPrefix = fullKey.substring(0, 20);
    // e.g., "tkf_live_a1b2c3d4e5"

    // Step 3: Hash the full key for storage
    // SHA-256 is appropriate here — unlike passwords, API keys are already
    // high-entropy random values, so no salt or bcrypt needed.
    // bcrypt's cost factor would make every API request slow — SHA-256 is fast
    // but the key's entropy (256 bits of randomness) makes brute force impossible.
    const keyHash = createHash("sha256").update(fullKey).digest("hex");

    // Step 4: Save to database — hash only, never the full key
    const record = await this.apiKeysRepo.save({
      userId,
      workspaceId,
      name,
      keyPrefix,
      keyHash,
      scopes,
      expiresAt,
    });

    // Step 5: Return the full key to the caller ONCE.
    // This is the ONLY time the full key exists in memory.
    // After this function returns, it is gone forever — not in DB, not in logs.
    return { key: fullKey, record };
  }

  // ...
}
```

```typescript
// src/api-keys/api-keys.controller.ts

@Post()
@UseGuards(JwtAuthGuard)
async createApiKey(
  @Request() req,
  @Body() dto: CreateApiKeyDto,
) {
  const { key, record } = await this.apiKeysService.createApiKey(
    req.user.userId,
    req.user.workspaceId,
    dto.name,
    dto.scopes,
    dto.expiresAt,
  );

  // The full key is returned ONLY in this response.
  // The frontend must show it to the user with a "copy now — you won't see this again" warning.
  // Subsequent GET /api-keys requests return the record WITHOUT the key.
  return {
    id: record.id,
    name: record.name,
    key,              // Full key — shown once only
    keyPrefix: record.keyPrefix,  // Shown forever for identification
    scopes: record.scopes,
    createdAt: record.createdAt,
    message: 'Save this key now. It will not be shown again.',
  };
}

// Listing keys — never returns the full key or the hash
@Get()
@UseGuards(JwtAuthGuard)
async listApiKeys(@Request() req) {
  return this.apiKeysService.listKeys(req.user.workspaceId);
  // Returns: id, name, keyPrefix, scopes, lastUsedAt, expiresAt, createdAt
  // Does NOT return: keyHash, fullKey
}
```

#### Step 3 — Key Verification on Incoming Requests

Every API request with an API key goes through a dedicated strategy — separate from the JWT strategy.

```typescript
// src/api-keys/api-key.strategy.ts
import { Strategy } from "passport-http-bearer";
import { PassportStrategy } from "@nestjs/passport";
import { Injectable, UnauthorizedException } from "@nestjs/common";
import { ApiKeysService } from "./api-keys.service";

@Injectable()
export class ApiKeyStrategy extends PassportStrategy(Strategy, "api-key") {
  constructor(private readonly apiKeysService: ApiKeysService) {
    super();
  }

  // Passport calls this with the value from the Authorization: Bearer header
  async validate(token: string): Promise<any> {
    const user = await this.apiKeysService.verifyKey(token);
    if (!user) throw new UnauthorizedException("Invalid or expired API key");
    return user;
  }
}
```

```typescript
// src/api-keys/api-keys.service.ts

async verifyKey(
  incomingKey: string,
  requestIp?: string,
): Promise<ApiKeyUser | null> {

  // Step 1: Extract the prefix (first 20 chars) for fast DB lookup.
  // This avoids scanning the whole table — prefix is indexed.
  if (incomingKey.length < 20) return null;
  const keyPrefix = incomingKey.substring(0, 20);

  // Step 2: Check Redis cache first.
  // Hashing + DB lookup on every request would be slow at scale.
  // Cache the resolved key record for 5 minutes.
  const cacheKey = `api-key:${keyPrefix}`;
  let cachedRecord = await this.cache.get<ApiKey>(cacheKey);

  if (!cachedRecord) {
    // DB lookup by prefix — fast due to partial index
    cachedRecord = await this.apiKeysRepo.findOneBy({
      keyPrefix,
      revokedAt: IsNull(),
    });

    if (cachedRecord) {
      await this.cache.set(cacheKey, cachedRecord, 5 * 60 * 1000);
    }
  }

  if (!cachedRecord) return null;

  // Step 3: Hash the incoming key and compare with stored hash.
  // timingSafeEqual prevents timing attacks — a naive === comparison takes
  // slightly longer when more characters match, leaking information.
  // timingSafeEqual always takes the same time regardless of match length.
  const incomingHash = createHash('sha256').update(incomingKey).digest('hex');
  const storedHashBuffer = Buffer.from(cachedRecord.keyHash, 'hex');
  const incomingHashBuffer = Buffer.from(incomingHash, 'hex');

  const isValid = timingSafeEqual(storedHashBuffer, incomingHashBuffer);
  if (!isValid) return null;

  // Step 4: Check expiry
  if (cachedRecord.expiresAt && cachedRecord.expiresAt < new Date()) {
    return null;
  }

  // Step 5: Update last used metadata asynchronously — do not block the request
  // Fire and forget — if this fails, it is not critical
  setImmediate(() => {
    this.apiKeysRepo.update(cachedRecord.id, {
      lastUsedAt: new Date(),
      lastUsedIp: requestIp,
    });
  });

  // Step 6: Return the resolved user context, including scopes
  return {
    userId: cachedRecord.userId,
    workspaceId: cachedRecord.workspaceId,
    scopes: cachedRecord.scopes,
    apiKeyId: cachedRecord.id,
    authMethod: 'api-key',
  };
}
```

#### Step 4 — Scope Enforcement

API keys have scopes that restrict what they can do. Even if a user's account has full admin permissions, a key scoped to `tasks:read` can only read tasks.

```typescript
// src/api-keys/api-key-scope.guard.ts

@Injectable()
export class ApiKeyScopeGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  canActivate(context: ExecutionContext): boolean {
    const requiredScopes = this.reflector.getAllAndOverride<string[]>(
      "required_scopes",
      [context.getHandler(), context.getClass()],
    );

    if (!requiredScopes || requiredScopes.length === 0) return true;

    const { user } = context.switchToHttp().getRequest();

    // If the request is authenticated via JWT (not API key), skip scope check
    if (user.authMethod !== "api-key") return true;

    // Check that all required scopes are present in the key's scope list
    const hasAll = requiredScopes.every((scope) => user.scopes.includes(scope));

    if (!hasAll) {
      throw new ForbiddenException(
        `This API key does not have the required scope: ${requiredScopes.join(", ")}`,
      );
    }

    return true;
  }
}
```

#### Step 5 — Revocation

Revoking a key is a soft delete — mark it as revoked, invalidate the Redis cache entry.

```typescript
async revokeKey(
  keyId: string,
  requestingUserId: number,
  reason?: string,
): Promise<void> {
  const key = await this.apiKeysRepo.findOneBy({ id: keyId });

  if (!key) throw new NotFoundException('API key not found');

  // Only the key owner or workspace admin can revoke
  if (key.userId !== requestingUserId) {
    throw new ForbiddenException('You cannot revoke this key');
  }

  await this.apiKeysRepo.update(keyId, {
    revokedAt: new Date(),
    revokedBy: requestingUserId,
    revokedReason: reason ?? 'user_request',
  });

  // Immediately invalidate the cache — next request using this key is rejected
  // without waiting for the 5-minute cache TTL to expire
  await this.cache.del(`api-key:${key.keyPrefix}`);
}
```

#### The Full Request Flow

```
POST /tasks
Authorization: ApiKey tkf_live_a1b2c3d4e5f6g7h8...
        |
        v
ApiKeyStrategy.validate(token)
        |
        v
ApiKeysService.verifyKey()
  → Extract prefix: "tkf_live_a1b2c3d4e5"
  → Check Redis → MISS
  → DB lookup WHERE key_prefix = 'tkf_live_a1b2c3d4e5' AND revoked_at IS NULL
  → Found record
  → Hash incoming key: SHA-256("tkf_live_a1b2c3d4e5...") = "abc123..."
  → timingSafeEqual("abc123...", storedHash) → match
  → Check expiry → still valid
  → Cache record for 5 minutes
  → Return { userId: 42, scopes: ['tasks:read', 'tasks:create'], authMethod: 'api-key' }
        |
        v
req.user = { userId: 42, scopes: [...], authMethod: 'api-key' }
        |
        v
ApiKeyScopeGuard
  → Route requires 'tasks:create'
  → user.scopes includes 'tasks:create' → passes
        |
        v
TasksController.create() → runs normally
```

#### Key Interview Points to Mention

- Use **SHA-256** for API key hashing, not bcrypt. API keys are already high-entropy random values (256 bits) — brute force is impossible. Bcrypt's intentional slowness would add 100–300ms to every API request.
- **`timingSafeEqual`** prevents timing side-channel attacks. A naive string comparison `===` leaks information about how many characters match by taking slightly longer on closer matches.
- The **prefix-based lookup** avoids a full table scan. You look up by the indexed prefix, then verify the hash — two cheap operations instead of a hash-then-scan.
- **Update `last_used_at` asynchronously** with `setImmediate`. This is non-critical metadata — blocking the request on a DB write for every API call would add latency.
- **Cache the key record** in Redis for 5 minutes. On revocation, explicitly delete the cache key — do not wait for TTL expiry.
- The key is shown **exactly once** at creation and never stored in plaintext anywhere — not in the database, not in logs, not in responses after the initial creation call.

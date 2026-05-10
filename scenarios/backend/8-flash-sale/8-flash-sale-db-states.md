# Flash Sale System — Database States & Request Flows

This document walks through the exact DB and Redis records at each stage, and shows how each layer filters the 10,000 concurrent requests down to 100 confirmed orders.

---

## Scenario

- Item **id: 42** (`Limited Edition Sneakers`) has **100 units** in stock
- Flash sale is scheduled — inventory pre-loaded into Redis before the sale opens
- **10,000 users** simultaneously hit `POST /flash-sale/items/42/buy`
- Exactly 100 should succeed; 9,900 should be rejected

---

## Stage 1 — Before the Sale (Initial DB State)

**`items` table**

| id | name | stock | price |
|----|------|-------|-------|
| 42 | Limited Edition Sneakers | 100 | 299.99 |

> `stock = 100` is the authoritative count in the database. This is the source of truth. The CHECK constraint `stock >= 0` is already in place — it is the last line of defence.

**`orders` table** — empty

| id | item_id | user_id | status | confirmed_at |
|----|---------|---------|--------|-------------|
| _(empty)_ | | | | |

**Redis** — no sale key yet

---

## Stage 2 — Sale Initialization (Before Users Hit Buy)

Admin or a scheduled job calls `initializeSaleInventory(itemId: 42, stock: 100)`:

```
Redis: SET sale:inventory:42 100  NX
Redis: EXPIRE sale:inventory:42 3600
```

**Redis after initialization:**

| Key | Value | TTL |
|-----|-------|-----|
| `sale:inventory:42` | `100` | 3600s (1 hr) |

> `NX` (only set if Not eXists) makes this idempotent — safe to call multiple times. If the key already exists (e.g., called twice by mistake), Redis ignores the second call. The DB stock and this Redis counter must start at the same number — they will diverge during the sale, but the DB is always the final authority.

**`items` table** — unchanged. DB stock is not touched during the sale. Only Redis changes until the job consumer writes each order.

---

## Stage 3 — The Sale Opens: 10,000 Requests Hit Redis

Every request calls `DECR sale:inventory:42`. Because Redis is **single-threaded**, each `DECR` is processed one at a time — no two requests ever see the same value.

**Redis `DECR` sequence (visualized for the first few and the boundary):**

| Request # | DECR returns | Outcome |
|-----------|-------------|---------|
| 1 | 99 | ≥ 0 → **claimed a unit**, proceed to queue |
| 2 | 98 | ≥ 0 → claimed |
| 3 | 97 | ≥ 0 → claimed |
| ... | ... | ... |
| 100 | 0 | ≥ 0 → claimed (last unit) |
| 101 | -1 | < 0 → **sold out**, `INCR` to restore, return `sold_out` |
| 102 | -2 → restored to -1 | < 0 → sold out |
| ... | ... | ... |
| 10,000 | far negative → restored | < 0 → sold out |

> Each `INCR` after a negative result restores the counter by 1 so it does not drift to -9,900. After all 9,900 rejected requests restore their decrements, the counter stabilizes at `0`.

**Redis after all 10,000 requests pass through the gate:**

| Key | Value | TTL |
|-----|-------|-----|
| `sale:inventory:42` | `0` | ~3590s |

> The value is `0`, not `100` and not negative. The 100 successful claims each took 1 unit; the 9,900 rejected requests each restored their decrement. **9,900 requests never touch the database.**

---

## Stage 4 — BullMQ Queue State (After Redis Gate)

The 100 successful requests each enqueue a job immediately and return `202 Processing` to the user.

**BullMQ `flash-sale` queue** — 100 jobs waiting:

| job id | status | data | attempts |
|--------|--------|------|----------|
| job-001 | waiting | `{ itemId: 42, userId: 1001 }` | 0/3 |
| job-002 | waiting | `{ itemId: 42, userId: 1002 }` | 0/3 |
| job-003 | waiting | `{ itemId: 42, userId: 1003 }` | 0/3 |
| ... | ... | ... | ... |
| job-100 | waiting | `{ itemId: 42, userId: 1100 }` | 0/3 |

> These 100 users all received an HTTP response like `{ "status": "processing", "jobId": "job-001" }` immediately — they are not waiting on a DB transaction. The `attempts: 3` means BullMQ will retry each job up to 3 times on failure before marking it dead.

### Where Does BullMQ Job Data Actually Live?

**BullMQ stores everything in Redis** — not in PostgreSQL. It uses namespaced Redis keys under the queue name alongside your inventory counter.

> **You never write these Redis keys manually.** BullMQ manages them entirely through its abstraction. Your code only calls `saleQueue.add(...)` to enqueue and `process(job)` to consume — BullMQ handles all the Redis operations internally. The table below shows what BullMQ is doing under the hood, not what you implement.

**Redis keys BullMQ creates and manages automatically:**

| Redis Key | Type | What it stores | Created by |
|---|---|---|---|
| `bull:flash-sale:{jobId}` | Hash | Full job payload (`itemId`, `userId`, `attemptsMade`, `opts`, timestamps) | `saleQueue.add()` |
| `bull:flash-sale:wait` | List | Job IDs waiting to be picked up by a worker | `saleQueue.add()` |
| `bull:flash-sale:active` | List | Job IDs currently being processed by a worker | BullMQ worker internals |
| `bull:flash-sale:failed` | Sorted Set | Job IDs that failed all attempts (score = timestamp) | BullMQ worker internals |
| `bull:flash-sale:completed` | Sorted Set | Job IDs that succeeded (empty here — `removeOnComplete: true`) | BullMQ worker internals |
| `bull:flash-sale:delayed` | Sorted Set | Job IDs in backoff delay before retry (score = when to retry) | BullMQ worker internals |

**What your code actually writes vs what BullMQ writes:**

```typescript
// YOUR code — this is all you write:
await this.saleQueue.add('process-purchase', { itemId, userId });

// BULLMQ internally runs (you never write this):
// HSET bull:flash-sale:job-001 { itemId, userId, attemptsMade: 0, ... }
// LPUSH bull:flash-sale:wait "job-001"
```

```typescript
// YOUR code — the consumer method signature:
async process(job: Job): Promise<void> {
  // method returns normally  → BullMQ moves job from :active → removed (or :completed)
  // method throws            → BullMQ moves job from :active → :delayed (retry) or :failed
}

// BULLMQ internally handles the key transitions — you never touch them
```

**Redis while the first batch of 5 jobs is being processed:**

| Key | Type | Value |
|-----|------|-------|
| `sale:inventory:42` | String | `0` |
| `bull:flash-sale:wait` | List | `["job-006", "job-007", ..., "job-100"]` (95 remaining) |
| `bull:flash-sale:active` | List | `["job-001", "job-002", "job-003", "job-004", "job-005"]` |
| `bull:flash-sale:job-001` | Hash | `{ itemId: 42, userId: 1001, attemptsMade: 0, ... }` |

> BullMQ shares the same Redis instance as your `sale:inventory:42` counter. On a high-traffic system, give BullMQ a **dedicated Redis instance** or at minimum ensure `maxmemory-policy noeviction` — BullMQ memory pressure must not evict your inventory key mid-sale.

**`items` table** — still unchanged. DB has not been touched yet.

| id | name | stock |
|----|------|-------|
| 42 | Limited Edition Sneakers | **100** |

---

## Stage 5 — Consumer Processes Jobs (concurrency: 5)

The `PurchaseConsumer` runs 5 jobs at a time. For each job it runs:

```sql
UPDATE items
SET stock = stock - 1
WHERE id = 42
  AND stock > 0
RETURNING id, stock
```

**DB state after first batch of 5 jobs completes:**

**`items` table:**

| id | name | stock |
|----|------|-------|
| 42 | Limited Edition Sneakers | **95** |

**`orders` table:**

| id | item_id | user_id | status | confirmed_at |
|----|---------|---------|--------|-------------|
| ord-001 | 42 | 1001 | confirmed | 2025-04-20 12:00:05 |
| ord-002 | 42 | 1002 | confirmed | 2025-04-20 12:00:05 |
| ord-003 | 42 | 1003 | confirmed | 2025-04-20 12:00:05 |
| ord-004 | 42 | 1004 | confirmed | 2025-04-20 12:00:05 |
| ord-005 | 42 | 1005 | confirmed | 2025-04-20 12:00:05 |

> `AND stock > 0` in the UPDATE is the atomic guard at the DB layer. If two jobs somehow ran the same item simultaneously, only one can decrement — the other gets 0 rows back and throws a `ConflictException`.

---

## Stage 6 — After All 100 Jobs Complete

**`items` table — stock fully consumed:**

| id | name | stock |
|----|------|-------|
| 42 | Limited Edition Sneakers | **0** |

**`orders` table — 100 confirmed rows:**

| id | item_id | user_id | status | confirmed_at |
|----|---------|---------|--------|-------------|
| ord-001 | 42 | 1001 | confirmed | 2025-04-20 12:00:05 |
| ord-002 | 42 | 1002 | confirmed | 2025-04-20 12:00:06 |
| ... | ... | ... | ... | ... |
| ord-100 | 42 | 1100 | confirmed | 2025-04-20 12:00:25 |

**Redis:**

| Key | Value | TTL |
|-----|-------|-----|
| `sale:inventory:42` | `0` | ~3570s |

> DB `stock` and Redis counter are both `0`. They are in sync at the end of a clean run.

---

## Stage 7 — The Redis Drift Problem (Edge Case)

Redis can disagree with the DB if:
- Redis restarts mid-sale and loses the key
- Redis evicts the key under memory pressure (`maxmemory-policy` not set to `noeviction`)
- A consumer job fails after the Redis claim but before the DB write

### Sub-case A — Redis loses the key mid-sale

Suppose 60 orders have been confirmed. Redis key is evicted. DB stock = 40.

```
Redis: GET sale:inventory:42  →  (nil)
Next request: DECR sale:inventory:42
  → Redis treats missing key as 0, decrements to -1
  → Code sees -1 → restored to 0 → returns "sold_out"
```

**All remaining users get `sold_out` even though 40 units remain.**

Fix — `syncInventoryFromDatabase()` runs and detects the missing key:
```
Redis: EXISTS sale:inventory:42  →  0 (missing)
DB: SELECT stock FROM items WHERE id = 42  →  40
Redis: SET sale:inventory:42 40
```

**Redis restored:**

| Key | Value | TTL |
|-----|-------|-----|
| `sale:inventory:42` | `40` | (reset) |

> The sync function checks `EXISTS` before setting — it will **not** overwrite a key that is actively being decremented. Only a missing key triggers a sync.

---

### Sub-case B — Consumer job fails after Redis claim, before DB write

User 1050 passes the Redis gate (DECR returns 5). The DB write fails (network blip). BullMQ retries the job up to 3 times. On the 3rd failure, the consumer runs:

```typescript
await this.releaseRedisInventory(itemId);
// INCR sale:inventory:42  →  puts the unit back
```

**Redis before release:**

| Key | Value |
|-----|-------|
| `sale:inventory:42` | `4` |

**Redis after release:**

| Key | Value |
|-----|-------|
| `sale:inventory:42` | `5` |

> The unit is returned to the Redis pool so the next queued request can claim it. Without this `INCR`, the Redis counter would permanently under-count, and one unit would go unsold even though the DB still has it.

---

## Stage 7b — Job Fails All 3 Attempts

User 1050 passed the Redis gate (DECR returned 5). Their job is enqueued. The DB write fails on all 3 attempts (e.g. DB is temporarily unavailable).

### The Bug in the Naive Implementation

The catch block in the consumer calls `releaseRedisInventory` (INCR) and rethrows on **every** failure:

```typescript
catch (error) {
  await this.releaseRedisInventory(itemId); // ← called on EVERY attempt ← BUG
  throw error; // BullMQ retries
}
```

**What actually happens across all 3 attempts:**

| Attempt | DB write | catch runs | Redis INCR fired | Redis counter after |
|---------|----------|------------|-----------------|---------------------|
| 1 (fails) | ❌ | ✅ | ✅ | 4 → **5** |
| 2 (fails) | ❌ | ✅ | ✅ | 5 → **6** |
| 3 (fails) | ❌ | ✅ | ✅ | 6 → **7** |

The unit is restored **3 times** instead of once. Redis now thinks 7 units are available when only 5 actually are — 3 extra phantom units are visible to the gate. Three other users could claim units that don't exist in the DB, and would only be rejected later at the `WHERE stock > 0` layer. The user also receives 3 "Order could not be processed" notifications.

**Redis after all 3 attempts (buggy version):**

| Key | Value | Expected |
|-----|-------|----------|
| `sale:inventory:42` | `7` | should be `5` |

---

### The Fix — Only Release on the Final Attempt

```typescript
catch (error) {
  const isLastAttempt = job.attemptsMade >= job.opts.attempts - 1;

  if (isLastAttempt) {
    await this.releaseRedisInventory(itemId); // INCR once, on permanent failure only
    await this.notificationsService.notifyUser(userId, 'Order could not be processed');
  }

  throw error;
}
```

**What happens across all 3 attempts with the fix:**

| Attempt | DB write | `isLastAttempt` | Redis INCR fired | User notified |
|---------|----------|-----------------|-----------------|---------------|
| 1 (fails) | ❌ | false | ❌ | ❌ |
| 2 (fails) | ❌ | false | ❌ | ❌ |
| 3 (fails) | ❌ | **true** | ✅ (once) | ✅ (once) |

**Redis after all 3 attempts (fixed version):**

| Key | Value |
|-----|-------|
| `sale:inventory:42` | `5` (correctly restored by 1) |

**BullMQ Redis after final failure:**

| Key | Value |
|-----|-------|
| `bull:flash-sale:failed` | `["job-1050"]` (kept for inspection — `removeOnFail: false`) |
| `bull:flash-sale:job-1050` | `{ itemId: 42, userId: 1050, attemptsMade: 3, failedReason: "..." }` |

**`orders` table** — no row created for user 1050:

| id | item_id | user_id | status |
|----|---------|---------|--------|
| ord-001 | 42 | 1001 | confirmed |
| ... | | | |
| _(no row for user 1050)_ | | | |

**`items` table** — stock unchanged from what it was (DB write never succeeded):

| id | name | stock |
|----|------|-------|
| 42 | Limited Edition Sneakers | 5 (unaffected by the failed job) |

> The DB was never touched by the failing job — `UPDATE WHERE stock > 0` either succeeds fully or not at all (it runs inside a transaction). Since the job never got past the DB error, `stock` was never decremented.

### Final Outcome Comparison

| Scenario | Redis counter | DB stock | Item sold? |
|---|---|---|---|
| Job succeeds | decremented | decremented | ✅ Sold |
| Job fails 3×, `INCR` on final only (fix) | **restored by 1** | unchanged | ⚠️ Unit back in pool |
| Job fails 3×, `INCR` on every attempt (bug) | **restored 3×** | unchanged | ❌ 3 phantom units injected |
| Job fails 3×, no `INCR` at all | unchanged (under-counted) | unchanged | ❌ Ghost-claimed — unsold forever |

> The `syncInventoryFromDatabase()` function is also a recovery tool for the ghost-claimed case — it re-seeds Redis from the DB's actual `stock` value when the key is missing or drifted.

---

## Stage 8 — The Duplicate Order Guard (Idempotency)

BullMQ may retry a job if the consumer crashes after the DB write but before acknowledging the job. Without an idempotency check, user 1001 could end up with two confirmed orders.

Before creating the order, the consumer checks:

```typescript
const existingOrder = await manager.findOneBy(Order, { itemId: 42, userId: 1001 });
if (existingOrder) return existingOrder;  // Already confirmed — return early
```

The `UNIQUE INDEX` on `orders(user_id, item_id) WHERE status = 'confirmed'` also catches this at the DB level — a duplicate insert would throw a unique constraint violation, which the consumer treats as success (the order already exists).

**`orders` table — stays at one row per user, no duplicates:**

| id | item_id | user_id | status |
|----|---------|---------|--------|
| ord-001 | 42 | 1001 | confirmed |
| _(no second row for user 1001)_ | | | |

---

## Stage 9 — The CHECK Constraint as Final Safety Net

If every other layer failed simultaneously (Redis drifted, atomic UPDATE had a bug, queue over-processed), the DB constraint is the last stop:

```sql
ALTER TABLE items ADD CONSTRAINT stock_non_negative CHECK (stock >= 0);
```

A rogue UPDATE that would push `stock` to `-1` is **rejected at the storage engine level** — no application code can bypass it. PostgreSQL raises an error, the transaction rolls back, and no order is created.

**This is why the constraint exists even when the other layers are correct** — it is a structural guarantee, not a runtime check.

---

## Full Request Journey — Single User

```
User 1001: POST /flash-sale/items/42/buy
     │
     ▼
ThrottlerGuard — max 5 req/s per user
     │
     ▼
Redis: DECR sale:inventory:42  →  returns 99
  99 ≥ 0  →  claimed ✓
     │
     ▼
BullMQ: enqueue job-001 { itemId: 42, userId: 1001 }
HTTP response → 202 { status: "processing", jobId: "job-001" }
     │
     │  (user polls GET /orders/status/job-001 or waits for WebSocket push)
     │
     ▼
PurchaseConsumer picks up job-001
     │
     ▼
DB transaction:
  UPDATE items SET stock = stock - 1
  WHERE id = 42 AND stock > 0
  RETURNING id, stock
  → { id: 42, stock: 99 }  ✓

  SELECT * FROM orders WHERE item_id = 42 AND user_id = 1001
  → no existing order ✓

  INSERT INTO orders (item_id, user_id, status, confirmed_at)
  VALUES (42, 1001, 'confirmed', NOW())
  → ord-001 created ✓
     │
     ▼
NotificationsService → push "Order confirmed!" to user 1001
```

---

## Summary — Which Layer Does What

| Layer | Mechanism | Filters out | Speed |
|---|---|---|---|
| Rate limiter | ThrottlerGuard (5 req/s per user) | Repeat spammers from a single user | ~0ms |
| Redis gate | `DECR` + check result | 9,900 of 10,000 requests | < 1ms |
| BullMQ queue | Controlled concurrency (5 workers) | Burst DB load — serializes the 100 survivors | N/A (async) |
| Atomic DB UPDATE | `WHERE stock > 0` | Any Redis drift or off-by-one | ~5ms per job |
| CHECK constraint | `stock >= 0` | Any code-level bug that slips through all above | DB engine |
| Idempotency check | `findOneBy` + UNIQUE INDEX | Duplicate orders from job retries | ~1ms |

| Redis Key | What it stores | What it controls |
|---|---|---|
| `sale:inventory:{itemId}` | Integer counter (units remaining) | Gate for every incoming purchase request |
| `sale:user:{userId}:{itemId}` | Per-user purchase count (Lua script) | Enforces per-user unit limit |

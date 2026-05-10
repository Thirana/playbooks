### "You have a flash sale where 10,000 users simultaneously try to buy one of 100 limited-edition items. Your current approach reads inventory, checks if stock > 0, then decrements — but you are seeing overselling. Walk me through how you fix this at each layer: database, application, and cache."

---

### The Naive Solution

The current approach: read inventory from PostgreSQL, check `stock > 0`, decrement, confirm sale.

```typescript
// Current broken code
const item = await this.itemsRepo.findOneBy({ id: itemId });
if (item.stock <= 0) throw new ConflictException("Sold out");
await this.itemsRepo.update(itemId, { stock: item.stock - 1 });
return this.ordersRepo.save({ itemId, userId, status: "confirmed" });
```

At 10,000 concurrent requests this will massively oversell — hundreds of requests read `stock = 50` simultaneously, all pass the check, all decrement, all confirm.

---

### Problems with the Naive Solution

The flash sale scenario is an extreme version of the same race condition from Question 9, but at much higher volume. The naive atomic SQL fix from Question 9 will work at the database layer — but it creates a new problem: **10,000 concurrent transactions hammering PostgreSQL at the same instant**.

PostgreSQL can handle hundreds of concurrent connections, but at 10,000 simultaneous requests:

- Connection pool exhausts — requests queue waiting for a connection
- Row-level lock contention on the inventory row becomes severe
- Database CPU spikes — slow queries start timing out
- The entire application becomes unresponsive, not just the flash sale endpoint
  The flash sale problem requires a layered fix: each layer filters out requests before they reach the next, progressively narrowing the 10,000 down to 100.

```
10,000 incoming requests
        |
        v
  Layer 1: Cache      ← filter out ~9,900 requests here (fast, cheap)
  (Redis atomic ops)
        |
  ~100 pass through
        |
        v
  Layer 2: Application ← queue and rate-limit the ~100 survivors
  (BullMQ queue)
        |
  100 pass through
        |
        v
  Layer 3: Database   ← handle only 100 concurrent writes (manageable)
  (atomic UPDATE)
        |
        v
  Layer 4: Constraint ← catch any edge cases
  (CHECK constraint)
```

#### Layer 1 — Redis Atomic Decrement as the Inventory Gate

Redis is single-threaded. Every command is processed one at a time — there are no race conditions between Redis commands. The `DECR` command is atomic: read-and-decrement happens in one indivisible operation.

Pre-load the stock count into Redis before the sale starts. Let Redis be the first and cheapest gate.

```typescript
// src/flash-sale/flash-sale.service.ts

// Called before the sale starts — load inventory into Redis
async initializeSaleInventory(itemId: number, stock: number): Promise<void> {
  const key = `sale:inventory:${itemId}`;

  // SET the stock count in Redis — this is the authoritative counter during the sale
  // NX: only set if not already exists (idempotent — safe to call multiple times)
  await this.redisClient.set(key, stock, 'NX');

  // Set an expiry matching the sale duration so Redis self-cleans
  await this.redisClient.expire(key, 3600); // 1 hour
}

async attemptPurchase(itemId: number, userId: number): Promise<PurchaseResult> {
  const inventoryKey = `sale:inventory:${itemId}`;

  // DECR is atomic in Redis — single-threaded, no race condition possible.
  // Returns the new value AFTER decrement.
  // If 10,000 requests call this simultaneously:
  //   - Request 1 gets 99 (decremented from 100)
  //   - Request 2 gets 98
  //   - ...
  //   - Request 100 gets 0
  //   - Request 101 gets -1
  //   - Request 102 gets -2 ... etc
  const remaining = await this.redisClient.decr(inventoryKey);

  if (remaining < 0) {
    // Undo the decrement — we oversold, put the unit back
    // This request is rejected — sold out
    await this.redisClient.incr(inventoryKey);
    return { success: false, reason: 'sold_out' };
  }

  // This request claimed a unit — proceed to queue a DB write
  return { success: true, remaining };
}
```

**Why DECR and check after, not check then DECR?**

```
WRONG (still a race): GET → check → DECR  (three separate commands, not atomic)
RIGHT: DECR → check result             (single atomic command)
```

With `DECR`, even if 10,000 requests hit Redis simultaneously, each gets a unique decremented value. Exactly 100 get values `>= 0`. The other 9,900 get negative values and are immediately rejected — they never reach the database.

**Using a Lua script for combined check-and-decrement:**

For more complex logic (e.g., "each user can only buy 2 units"), use a Redis Lua script. Lua scripts run atomically in Redis — the entire script executes as one operation.

```typescript
// Lua script: decrement only if remaining > 0 AND this user hasn't bought yet
const luaScript = `
  local key = KEYS[1]
  local userKey = KEYS[2]
  local userId = ARGV[1]
  local maxPerUser = tonumber(ARGV[2])
 
  -- Check if user already bought the maximum allowed
  local userCount = tonumber(redis.call('GET', userKey) or 0)
  if userCount >= maxPerUser then
    return -2  -- User limit reached
  end
 
  -- Check and decrement inventory
  local remaining = tonumber(redis.call('GET', key) or 0)
  if remaining <= 0 then
    return -1  -- Sold out
  end
 
  redis.call('DECR', key)
  redis.call('INCR', userKey)
  redis.call('EXPIRE', userKey, 86400)  -- Track for 24 hours
  return remaining - 1
`;

const result = await this.redisClient.eval(
  luaScript,
  2, // Number of keys
  `sale:inventory:${itemId}`, // KEYS[1]
  `sale:user:${userId}:${itemId}`, // KEYS[2]
  String(userId), // ARGV[1]
  "2", // ARGV[2] — max 2 per user
);

if (result === -1) return { success: false, reason: "sold_out" };
if (result === -2) return { success: false, reason: "user_limit_reached" };
```

#### Layer 2 — BullMQ Queue for Database Writes

The ~100 requests that passed the Redis gate should not all hit the database simultaneously. Enqueue them and process them serially (or with controlled concurrency).

```typescript
// src/flash-sale/flash-sale.service.ts

async attemptPurchase(itemId: number, userId: number): Promise<PurchaseResult> {

  // Step 1: Redis gate — fast rejection for the 9,900 who will not get a unit
  const redisResult = await this.claimInventoryInRedis(itemId);
  if (!redisResult.success) {
    return { success: false, reason: 'sold_out' };
  }

  // Step 2: Enqueue the DB write — return immediately to the user
  // The user gets a "your order is being processed" response right away
  // rather than waiting for the DB transaction to complete
  const job = await this.saleQueue.add(
    'process-purchase',
    { itemId, userId, redisClaimId: redisResult.claimId },
    {
      attempts: 3,
      backoff: { type: 'exponential', delay: 1000 },
      // Remove on success — keep failures for inspection
      removeOnComplete: true,
      removeOnFail: false,
    },
  );

  return {
    success: true,
    status: 'processing',
    orderId: job.id,
    message: 'Your order is being processed. You will be notified shortly.',
  };
}
```

```typescript
// src/flash-sale/purchase.consumer.ts

@Processor("flash-sale")
export class PurchaseConsumer extends WorkerHost {
  // concurrency: 5 means 5 jobs process simultaneously — controlled DB load
  // Adjust based on your DB's connection pool size
  constructor() {
    super({ concurrency: 5 });
  }

  async process(job: Job): Promise<void> {
    const { itemId, userId } = job.data;

    try {
      await this.confirmPurchaseInDatabase(itemId, userId);
      await this.notificationsService.notifyUser(userId, "Order confirmed!");
    } catch (error) {
      // Only release the Redis inventory unit and notify the user on the
      // FINAL attempt. If you call INCR on every attempt, the unit gets
      // restored multiple times — injecting phantom inventory into the gate.
      const isLastAttempt = job.attemptsMade >= job.opts.attempts - 1;

      if (isLastAttempt) {
        // Put the unit back so another user can claim it
        await this.releaseRedisInventory(itemId);
        // Notify the user once — not on every retry
        await this.notificationsService.notifyUser(userId, "Order could not be processed");
      }

      throw error; // BullMQ retries until attemptsMade === attempts
    }
  }
}
```

**Where does BullMQ job data live?**

BullMQ stores all job data in **Redis**, not PostgreSQL. It uses a set of namespaced keys alongside your inventory counter:

| Redis Key | Type | Contains |
|---|---|---|
| `bull:flash-sale:{jobId}` | Hash | Job payload, `attemptsMade`, timestamps |
| `bull:flash-sale:wait` | List | IDs of jobs waiting to be picked up |
| `bull:flash-sale:active` | List | IDs of jobs currently running |
| `bull:flash-sale:delayed` | Sorted Set | IDs in exponential backoff before retry |
| `bull:flash-sale:failed` | Sorted Set | IDs of jobs that exhausted all attempts |
| `bull:flash-sale:completed` | Sorted Set | IDs of succeeded jobs (empty — `removeOnComplete: true`) |

> Because BullMQ shares the same Redis instance as `sale:inventory:42`, its memory usage can trigger key eviction if `maxmemory-policy` is not set to `noeviction`. Use a **dedicated Redis instance for BullMQ** on high-traffic sales, or at minimum protect the inventory key from eviction.

#### Layer 3 — Atomic Database Write

The ~100 jobs from the queue hit PostgreSQL. Even here, use an atomic conditional UPDATE as the definitive source of truth.

```typescript
// src/flash-sale/flash-sale.service.ts

private async confirmPurchaseInDatabase(
  itemId: number,
  userId: number,
): Promise<Order> {

  return this.dataSource.transaction(async (manager) => {

    // Atomic decrement — the database is the final source of truth.
    // Even if the Redis count drifts (e.g., Redis restart, eviction),
    // the database will never oversell because of this check.
    const result = await manager.query(`
      UPDATE items
      SET stock = stock - 1
      WHERE id = $1
        AND stock > 0
      RETURNING id, stock
    `, [itemId]);

    if (result.length === 0) {
      // DB says sold out — Redis count was wrong (drift)
      // Reject this purchase
      throw new ConflictException('Item sold out');
    }

    // Idempotency check: has this user already placed this order?
    // Prevents duplicate orders if the job retries after a partial failure
    const existingOrder = await manager.findOneBy(Order, { itemId, userId });
    if (existingOrder) return existingOrder;

    const order = manager.create(Order, {
      itemId,
      userId,
      status: 'confirmed',
      confirmedAt: new Date(),
    });

    return manager.save(order);
  });
}
```

#### Layer 4 — Database Constraint as Final Safety Net

```sql
-- Structural guarantee — cannot be bypassed by any code path
ALTER TABLE items ADD CONSTRAINT stock_non_negative CHECK (stock >= 0);

-- Prevent the same user from buying the same item twice
-- (for limited-edition items where one-per-customer is required)
CREATE UNIQUE INDEX idx_orders_user_item
  ON orders (user_id, item_id)
  WHERE status = 'confirmed';
```

#### The Redis–Database Sync Problem

Using Redis as an inventory gate introduces a potential inconsistency: Redis and the database can drift.

**Scenario — Redis evicts the key under memory pressure:**
Redis may evict keys when it runs out of memory (if `maxmemory-policy` is set to an eviction policy). If the inventory key is evicted, `DECR` on a non-existent key returns `-1` — Redis starts the count from 0 and immediately decrements to -1, which your code treats as sold out. This is a false negative — users get rejected even if inventory is available.

**Fix: use Redis with `maxmemory-policy noeviction` for inventory keys**, combined with the database as the authoritative source of truth.

```typescript
// Sync Redis from DB periodically (or on Redis restart)
async syncInventoryFromDatabase(itemId: number): Promise<void> {
  const item = await this.itemsRepo.findOneBy({ id: itemId });
  const key = `sale:inventory:${itemId}`;

  // Only sync if the key is missing — do not overwrite a running counter
  const exists = await this.redisClient.exists(key);
  if (!exists) {
    await this.redisClient.set(key, item.stock);
  }
}
```

#### The Complete Layered Flow

```
10,000 users hit POST /flash-sale/items/42/buy
        |
        v
Rate Limiter (ThrottlerGuard)
  → 5 requests per second per user — prevents single-user spam
        |
        v
Redis DECR on sale:inventory:42
  → 9,900 requests get value < 0 → immediately return "sold out" (< 1ms)
  → 100 requests get value >= 0 → continue
        |
        v
BullMQ: add job to 'flash-sale' queue
  → Response to user: "processing" (returned in ~5ms)
  → User waits for push notification / polls status endpoint
        |
        v
PurchaseConsumer (concurrency: 5)
  → Processes 5 jobs at a time from the queue
  → Each job:
      UPDATE items SET stock = stock - 1
      WHERE id = 42 AND stock > 0
      → Success: create confirmed order
      → Failure (stock = 0 in DB): release Redis claim, notify user "sold out"
        |
        v
CHECK constraint (stock >= 0)
  → Final backstop — structurally prevents negative stock
```

#### Handling the User Experience During Processing

The user cannot get an instant "confirmed" response because the order is queued. Use one of two patterns:

**Pattern A — Polling:**

```typescript
// Return a job ID immediately
return { status: "processing", jobId: job.id };

// Client polls:
// GET /orders/status/:jobId → { status: 'processing' | 'confirmed' | 'failed' }
```

**Pattern B — WebSocket / Server-Sent Events push:**

```typescript
// After the consumer confirms the order, push to the user's open connection
await this.websocketGateway.emitToUser(userId, "order:confirmed", { orderId });
// or
await this.websocketGateway.emitToUser(userId, "order:failed", {
  reason: "sold_out",
});
```

#### Key Interview Points to Mention

- The core fix at the **database layer** is the same as Question 9: atomic `UPDATE WHERE stock > 0`. This alone is not enough for 10,000 concurrent requests — it becomes a bottleneck.
- The **Redis `DECR` gate** is the scalability trick. 9,900 requests are rejected in under 1ms before any database is touched. Redis's single-threaded model makes `DECR` inherently atomic — no race condition possible.
- The **BullMQ queue** decouples the HTTP response from the database write. Users get an immediate response. The database sees controlled concurrency (5 at a time) instead of 10,000 simultaneous connections.
- **Redis and the database can drift.** Redis is the fast gate, the database is the source of truth. If Redis claims more units than the DB has, the DB's atomic update catches it. If Redis under-counts, the sync mechanism corrects it.
- Always add a **CHECK constraint** regardless of other protections — it is a structural guarantee, not a runtime check.
- The **idempotency check** on the order write (`findOneBy({ itemId, userId })`) protects against duplicate orders if the BullMQ job retries after a partial failure (e.g., the DB write succeeded but the job acknowledgement failed).

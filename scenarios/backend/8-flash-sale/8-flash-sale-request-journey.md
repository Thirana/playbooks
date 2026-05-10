# Flash Sale — Full Request Journey

This document traces a single `POST /flash-sale/items/42/buy` request from the moment the user clicks "Buy" — starting at DNS resolution — through every AWS layer and NestJS service method, for both success and failure scenarios.

---

## The AWS Infrastructure

There are two valid architectures. The difference is **where Route 53 points**.

### Option A — CloudFront in Front (Recommended for Flash Sales)

Route 53 points to **CloudFront**, not the ALB. CloudFront has the ALB set as its origin. WAF is attached to the CloudFront distribution.

```
User's Browser
      │
      │ 1. DNS lookup: api.yourapp.com
      ▼
Route 53
      │ ALIAS → d1234.cloudfront.net   ← points to CloudFront, NOT the ALB
      ▼
CloudFront edge node (nearest to user)
      │ WAF rules evaluated here
      ▼
Application Load Balancer (ALB)   ← CloudFront's origin
      │ selects healthy target
      ▼
ECS Task / EC2 Instance  (NestJS process)
      │
      ├──► ElastiCache (Redis)   — inventory counter + BullMQ job store
      │
      └──► RDS (PostgreSQL)      — items table, orders table
```

### Option B — ALB Directly, No CloudFront

Route 53 points to the ALB. WAF is attached directly to the ALB instead.

```
User's Browser
      │
      │ 1. DNS lookup: api.yourapp.com
      ▼
Route 53
      │ ALIAS → flash-sale-alb-123456.us-east-1.elb.amazonaws.com
      ▼
Application Load Balancer (ALB)
      │ WAF rules evaluated here (WAF attached to ALB, not CloudFront)
      │ selects healthy target
      ▼
ECS Task / EC2 Instance  (NestJS process)
      │
      ├──► ElastiCache (Redis)
      └──► RDS (PostgreSQL)
```

> **This document follows Option A.** CloudFront is the recommended setup for flash sales because it absorbs traffic at edge nodes worldwide before it ever reaches your origin infrastructure. Option B is simpler but all traffic hits your ALB directly.

---

## Phase 1 — DNS Resolution (Route 53)

```
Browser: "Where is api.yourapp.com?"
    │
    ▼
OS checks local DNS cache  →  miss
    │
    ▼
Recursive resolver (ISP or 8.8.8.8)
    │
    ▼
Route 53 authoritative nameserver
    │  ALIAS record points to CloudFront distribution:
    │  api.yourapp.com → d1234.cloudfront.net
    │
    ▼
Resolver resolves CloudFront DNS → returns CloudFront edge IP
(e.g. 13.224.18.10 — an AWS edge node near the user)
    │
    ▼
Browser caches the IP (TTL = 60s)
Browser connects to that CloudFront edge node — NOT the ALB directly
```

> Route 53 health checks run independently. If the CloudFront distribution or origin (ALB) becomes unhealthy, Route 53 can failover to a secondary region. During a flash sale, set TTL low (30–60s) so failover propagates quickly.

---

## Phase 2 — CloudFront Edge + WAF

The request arrives at a **CloudFront edge node** (a PoP — Point of Presence — nearest to the user's geography). WAF rules run here before any traffic touches your origin.

```
Request arrives at CloudFront edge node
    │
    ▼
WAF Rule evaluation (in order):
  Rule 1: IP rate limit — max 100 req/5min per IP  →  if exceeded: 429
  Rule 2: Geo-block list — blocked countries        →  if match: 403
  Rule 3: Bot signature check (managed rule group)  →  if bot: 403
  Rule 4: Allow                                     →  forward to origin (ALB)
    │
    ▼
CloudFront forwards request to origin:
  flash-sale-alb-123456.us-east-1.elb.amazonaws.com
  (the ALB — CloudFront has this configured as its origin)
```

> **Important:** The ALB should only accept traffic from CloudFront's IP ranges (configurable via AWS managed prefix list). This prevents someone from bypassing CloudFront+WAF by hitting the ALB's DNS directly.

### WAF Rate Limiting vs ThrottlerGuard — Why Both?

They operate at different layers and protect against different threats. Neither is redundant.

| | WAF | ThrottlerGuard |
|---|---|---|
| Operates on | IP address | Authenticated `userId` (from JWT) |
| Runs at | CloudFront edge — before your infrastructure | Inside NestJS — after JWT is decoded |
| Stops | IP-level floods, bots, unauthenticated DDoS | Per-user abuse of specific endpoints |
| Blind to | Who the authenticated user is | Unauthenticated floods (no JWT yet) |
| Cost of a miss | Your entire infra absorbs the load | One user gets more requests than allowed |

**The scenario where WAF alone fails — distributed legitimate-looking traffic:**

```
1,000 users, each behind a different IP, each sending 50 req/sec
→ WAF sees 1,000 different IPs, each below its threshold → all pass
→ Total: 50,000 req/sec reaches NestJS
→ ThrottlerGuard blocks each user at 5 req/sec — 9,000 rejected per second
```

WAF cannot stop this because no single IP is misbehaving. A corporate NAT, a shared VPN, or a coordinated group of users each sending a few requests will slip through. ThrottlerGuard catches it because it operates on the authenticated `userId`, not the IP.

**The scenario where ThrottlerGuard alone fails — unauthenticated flood:**

```
Attacker sends 50,000 requests with no JWT, from one IP
→ ThrottlerGuard runs AFTER JwtAuthGuard in the NestJS pipeline
→ JwtAuthGuard rejects all 50,000 with 401 before ThrottlerGuard even runs
→ But NestJS, the ALB, and ElastiCache already absorbed all 50,000 connections
→ WAF would have stopped this at the CloudFront edge — zero infrastructure touched
```

ThrottlerGuard only runs on requests that reach the NestJS process. It cannot protect against floods that exhaust your ALB connection pool or spike your ECS CPU before a single guard fires.

---

## Phase 3 — Application Load Balancer (ALB)

```
Request arrives at ALB
    │
    ▼
ALB checks listener rule:
  POST /flash-sale/*  →  forward to target group: flash-sale-ecs-tasks
    │
    ▼
ALB selects healthy target (round-robin across ECS tasks):
  Target 1: 10.0.1.5:3000  ← selected (least connections)
  Target 2: 10.0.1.6:3000
  Target 3: 10.0.1.7:3000
    │
    ▼
ALB opens TCP connection to ECS Task on port 3000
ALB forwards HTTP/1.1 request, adding headers:
  X-Forwarded-For: <user's real IP>
  X-Forwarded-Proto: https
    │
    ▼
NestJS process on ECS Task receives the request
```

> The ALB health check hits `GET /health` every 30 seconds. A task that fails 2 consecutive checks is removed from rotation. During a flash sale, ensure your `/health` endpoint does NOT check Redis or DB — a slow DB during peak load should not pull healthy NestJS tasks out of rotation.

---

## Phase 4 — NestJS Request Pipeline

The request enters NestJS and passes through layers in this fixed order before any controller code runs:

```
Incoming HTTP Request
        │
        ▼
1. Express body-parser middleware
   → parses JSON body: { "itemId": 42 }
   → attaches to req.body
        │
        ▼
2. Global middleware (if any)
   → e.g. request logging, correlation ID injection
        │
        ▼
3. ThrottlerGuard  (first guard — rate limiting)
   → checks Redis key: throttle:{userId}:{endpoint}
   → if > 5 requests/second for this user → 429 Too Many Requests
   → if within limit → increments counter, continues
        │
        ▼
4. JwtAuthGuard
   → reads Authorization header: "Bearer eyJhbGci..."
   → verifies JWT signature with SECRET
   → decodes payload: { sub: 1001, email: "...", workspaceId: "..." }
   → if invalid/expired → 401 Unauthorized
   → if valid → attaches to req.user
        │
        ▼
5. Pipes (ValidationPipe)
   → validates req.body against DTO schema
   → if itemId is missing or not a number → 400 Bad Request
   → if valid → continues
        │
        ▼
6. FlashSaleController.buy()
   → extracts itemId from @Param, userId from req.user
   → calls FlashSaleService.attemptPurchase(42, 1001)
```

---

## Phase 5 — Service Method Execution (Success Path)

```
FlashSaleService.attemptPurchase(itemId: 42, userId: 1001)
        │
        ▼
5a. claimInventoryInRedis(itemId: 42)
    │
    ├── redisClient.decr("sale:inventory:42")
    │     → Redis processes atomically: 100 → 99
    │     → returns 99
    │
    └── 99 >= 0  →  claim successful
        returns { success: true, remaining: 99 }
        │
        ▼
5b. saleQueue.add("process-purchase", { itemId: 42, userId: 1001 })
    │
    ├── BullMQ serialises job payload to JSON
    ├── Writes to Redis:
    │     HSET  bull:flash-sale:job-001  { itemId: 42, userId: 1001, attemptsMade: 0 }
    │     LPUSH bull:flash-sale:wait     "job-001"
    │
    └── returns Job object with id: "job-001"
        │
        ▼
5c. FlashSaleService returns to controller:
    {
      success: true,
      status: "processing",
      orderId: "job-001",
      message: "Your order is being processed. You will be notified shortly."
    }
        │
        ▼
Controller sends HTTP response:

  HTTP/1.1 202 Accepted
  Content-Type: application/json

  {
    "status": "processing",
    "jobId": "job-001",
    "message": "Your order is being processed. You will be notified shortly."
  }
```

> The HTTP connection closes here. The user's browser has its `202` response. Everything from this point is **asynchronous** — the user's request is done.

---

## Phase 6 — Async Worker Execution (Success Path)

On a separate worker process (same or different ECS task):

```
BullMQ worker polling Redis:
  BRPOPLPUSH bull:flash-sale:wait bull:flash-sale:active
  → picks up "job-001"
        │
        ▼
PurchaseConsumer.process(job)
  job.data = { itemId: 42, userId: 1001 }
  job.attemptsMade = 0
        │
        ▼
6a. confirmPurchaseInDatabase(itemId: 42, userId: 1001)
    │
    ├── dataSource.transaction(async manager => {
    │
    │   6a-i. Atomic stock decrement
    │         manager.query(`
    │           UPDATE items
    │           SET stock = stock - 1
    │           WHERE id = 42 AND stock > 0
    │           RETURNING id, stock
    │         `)
    │         → PostgreSQL acquires row-level lock on items WHERE id=42
    │         → stock was 100, decrements to 99
    │         → returns [{ id: 42, stock: 99 }]
    │         → result.length > 0  →  stock was available ✓
    │
    │   6a-ii. Idempotency check
    │          manager.findOneBy(Order, { itemId: 42, userId: 1001 })
    │          → SELECT * FROM orders WHERE item_id=42 AND user_id=1001
    │          → 0 rows  →  no duplicate ✓
    │
    │   6a-iii. Create and save order
    │           manager.create(Order, {
    │             itemId: 42, userId: 1001,
    │             status: "confirmed", confirmedAt: new Date()
    │           })
    │           manager.save(order)
    │           → INSERT INTO orders (item_id, user_id, status, confirmed_at)
    │             VALUES (42, 1001, 'confirmed', NOW())
    │           → returns saved Order entity (ord-001)
    │
    └── }) → transaction commits
        │
        ▼
6b. notificationsService.notifyUser(1001, "Order confirmed!")
    → WebSocket push / FCM push notification to user's device
        │
        ▼
6c. BullMQ marks job complete:
    LREM  bull:flash-sale:active  "job-001"
    (removed — not added to completed because removeOnComplete: true)
```

---

## Failure Scenarios — Service Method Call Stack

### Failure A — Sold Out at Redis Gate

```
FlashSaleService.attemptPurchase(42, 1001)
        │
        ▼
claimInventoryInRedis(42)
    │
    ├── redisClient.decr("sale:inventory:42")
    │     → returns -1  (all 100 units claimed)
    │
    ├── -1 < 0  →  sold out
    ├── redisClient.incr("sale:inventory:42")  (restore)
    └── returns { success: false, reason: "sold_out" }
        │
        ▼
FlashSaleService returns immediately:
    { success: false, reason: "sold_out" }
        │
        ▼
Controller sends:

  HTTP/1.1 409 Conflict
  {
    "statusCode": 409,
    "message": "Item is sold out"
  }
```

> No DB touched. No BullMQ job created. Total time: < 1ms.

---

### Failure B — JWT Invalid (Never Reaches Service)

```
JwtAuthGuard.canActivate()
    │
    ├── Authorization header missing OR token signature invalid
    └── throw UnauthorizedException
        │
        ▼
NestJS exception filter catches it:

  HTTP/1.1 401 Unauthorized
  {
    "statusCode": 401,
    "message": "Unauthorized"
  }
```

> ThrottlerGuard still ran and incremented the rate-limit counter. The invalid JWT is counted against the IP's rate limit — preventing brute-force token guessing.

---

### Failure C — Rate Limit Exceeded (Never Reaches Service)

```
ThrottlerGuard.canActivate()
    │
    ├── redisClient.get("throttle:1001:/flash-sale/items/42/buy")
    │   → 6 (over the 5/sec limit)
    └── throw ThrottlerException
        │
        ▼
  HTTP/1.1 429 Too Many Requests
  Retry-After: 1
  {
    "statusCode": 429,
    "message": "Too Many Requests"
  }
```

---

### Failure D — DB Write Fails, Job Retries, Then Permanently Fails

```
PurchaseConsumer.process(job)  ← attempt 1 of 3
  job.attemptsMade = 0
        │
        ▼
confirmPurchaseInDatabase(42, 1001)
    │
    ├── dataSource.transaction(...)
    │   └── manager.query(UPDATE items ...)
    │         → RDS connection timeout — throws Error
    │
    └── transaction rolls back automatically
        │
        ▼
catch (error) {
  isLastAttempt = (0 >= 3 - 1)  →  false
  // no INCR, no user notification
  throw error
}
        │
        ▼
BullMQ catches the throw:
  LREM  bull:flash-sale:active     "job-001"
  ZADD  bull:flash-sale:delayed    <score: now+1000ms>  "job-001"
  HSET  bull:flash-sale:job-001    attemptsMade: 1


── (1 second later) ──────────────────────────────────────────

PurchaseConsumer.process(job)  ← attempt 2 of 3
  job.attemptsMade = 1

  [same DB failure]

  isLastAttempt = (1 >= 2)  →  false
  throw error

BullMQ:
  ZADD bull:flash-sale:delayed  <score: now+2000ms>  "job-001"
  HSET bull:flash-sale:job-001  attemptsMade: 2


── (2 seconds later) ──────────────────────────────────────────

PurchaseConsumer.process(job)  ← attempt 3 of 3
  job.attemptsMade = 2

  [same DB failure]

  isLastAttempt = (2 >= 2)  →  true
  │
  ├── releaseRedisInventory(42)
  │   → redisClient.incr("sale:inventory:42")  — unit restored once
  │
  └── notificationsService.notifyUser(1001, "Order could not be processed")
      throw error
        │
        ▼
BullMQ marks job permanently failed:
  LREM  bull:flash-sale:active  "job-001"
  ZADD  bull:flash-sale:failed  <score: now>  "job-001"
  (kept for manual inspection — removeOnFail: false)
```

**End state after Failure D:**

| Store | Key | Value | Note |
|-------|-----|-------|------|
| Redis | `sale:inventory:42` | restored by 1 | unit available again |
| Redis | `bull:flash-sale:failed` | `["job-001"]` | available for inspection |
| Redis | `bull:flash-sale:active` | `[]` | job removed |
| DB | `items.stock` | unchanged | UPDATE never committed |
| DB | `orders` | no row for user 1001 | INSERT never ran |

---

### Failure E — DB Write Succeeds but Worker Crashes Before Acknowledging

This is the scenario where the idempotency check matters most.

```
PurchaseConsumer.process(job)  ← attempt 1
        │
        ▼
confirmPurchaseInDatabase(42, 1001)
    │
    ├── UPDATE items ... RETURNING  →  stock decremented ✓
    ├── findOneBy(Order ...)         →  no duplicate ✓
    └── INSERT INTO orders ...       →  ord-001 created ✓
    Transaction commits ✓
        │
        ▼
[ECS task crashes / OOM killed HERE — before job acknowledgement]
        │
        ▼
BullMQ: job-001 was still in "active" list
  → Worker stall timeout fires (default: 30s)
  → BullMQ moves job-001 back to "wait" list for retry
        │
        ▼
PurchaseConsumer.process(job)  ← attempt 2 (retry)
  job.attemptsMade = 1
        │
        ▼
confirmPurchaseInDatabase(42, 1001)
    │
    ├── UPDATE items SET stock = stock - 1
    │   WHERE id = 42 AND stock > 0
    │   → stock decrements again (now at -1 relative to intent)  ← DANGER
    │
    └── findOneBy(Order, { itemId: 42, userId: 1001 })
        → finds ord-001 (created in attempt 1)
        → returns existingOrder immediately  ✓ idempotency guard fires
        → no second INSERT
        transaction rolls back the stock decrement (early return before commit)
```

> The idempotency check (`findOneBy` before INSERT) is what prevents both the duplicate order and the stock double-decrement. The transaction wraps both the stock UPDATE and the order INSERT — if `findOneBy` returns early, the entire transaction (including the stock decrement) rolls back cleanly.

---

## Full Timeline — Success Scenario

```
t=0ms     User clicks "Buy"
t=10ms    DNS resolved (cached from previous request)
t=15ms    TCP handshake with ALB complete
t=18ms    TLS handshake complete
t=20ms    WAF rules evaluated — pass
t=22ms    ALB forwards to ECS task 10.0.1.5:3000
t=23ms    NestJS receives raw HTTP request
t=24ms    body-parser parses JSON body
t=25ms    ThrottlerGuard — Redis read/write — pass
t=27ms    JwtAuthGuard — JWT decoded and verified — pass
t=28ms    ValidationPipe — DTO validated — pass
t=29ms    Controller calls FlashSaleService.attemptPurchase()
t=30ms    Redis DECR sale:inventory:42  →  returns 99
t=31ms    BullMQ enqueues job to Redis
t=32ms    Service returns { status: "processing", jobId: "job-001" }
t=33ms    HTTP 202 sent — connection closed

── (async, ~50–200ms later) ─────────────────────────────────

t=90ms    BullMQ worker picks up job-001
t=91ms    PurchaseConsumer.process() called
t=92ms    DB transaction begins
t=93ms    UPDATE items SET stock = stock - 1 WHERE id=42 AND stock > 0
t=95ms    findOneBy(Order) — no duplicate
t=96ms    INSERT INTO orders
t=98ms    Transaction commits
t=99ms    notificationsService pushes "Order confirmed!" to user device
t=100ms   BullMQ removes job from active list
```

---

## Method Execution Order — Quick Reference

### On the HTTP request thread (synchronous, blocks until 202 is sent):

```
1. body-parser middleware
2. ThrottlerGuard.canActivate()
   └── redisClient.get(throttle key)
   └── redisClient.incr(throttle key)
3. JwtAuthGuard.canActivate()
   └── jwtService.verify(token)
4. ValidationPipe.transform(body, metadata)
5. FlashSaleController.buy(itemId, req)
6. FlashSaleService.attemptPurchase(itemId, userId)
   └── FlashSaleService.claimInventoryInRedis(itemId)
       └── redisClient.decr(inventoryKey)
       └── [if < 0] redisClient.incr(inventoryKey) → return sold_out
   └── saleQueue.add("process-purchase", jobData)
       └── redisClient.hset(job hash)
       └── redisClient.lpush(wait list)
7. Controller returns 202
```

### On the BullMQ worker thread (async, after HTTP response):

```
1. PurchaseConsumer.process(job)
2. FlashSaleService.confirmPurchaseInDatabase(itemId, userId)
   └── dataSource.transaction(manager => {
       └── manager.query(UPDATE items ...)      ← row lock acquired + released
       └── manager.findOneBy(Order, ...)        ← idempotency check
       └── manager.create(Order, ...)
       └── manager.save(order)
   })                                           ← transaction commits
3. notificationsService.notifyUser(userId, msg)
4. [job acknowledged — removed from active]
```

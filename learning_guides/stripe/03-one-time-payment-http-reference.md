# 03 — One-Time Payments: HTTP Reference

Supplementary to `03-one-time-payment.md`. This note shows the actual request bodies, response shapes, headers, and status codes at every hop in the payment flow — what your frontend sends, what your backend returns, what Stripe sends back, and what the webhook delivers.

---

## The Full Flow with HTTP Details

```
Frontend          Your NestJS API            Stripe API          Stripe Webhooks
    │                    │                       │                      │
    │ POST /payments/     │                       │                      │
    │  create-intent      │                       │                      │
    │──────────────────► │                       │                      │
    │                    │ POST /v1/paymentIntents│                      │
    │                    │──────────────────────►│                      │
    │                    │◄──────────────────────│                      │
    │◄────────────────── │                       │                      │
    │  { clientSecret }  │                       │                      │
    │                    │                       │                      │
    │ stripe.confirmPayment() ─────────────────► │                      │
    │◄──────────────────────────────────────────│                      │
    │  redirect to return_url                   │                      │
    │                    │                       │ POST /webhooks        │
    │                    │◄──────────────────────────────────────────── │
    │                    │  payment_intent.succeeded                    │
    │                    │                       │                      │
```

---

## Step 1 — Frontend → Your NestJS API

**Request**

```
POST /payments/create-intent
Authorization: Bearer eyJhbGciOiJIUzI1NiJ9...
Content-Type: application/json
```

```json
{
  "amount": 2900,
  "currency": "usd"
}
```

> `customerId` is NOT sent by the frontend. Your backend reads `req.user.stripeCustomerId` from the JWT — the frontend never knows the Stripe customer ID.

**What your controller receives:**

| Field | Source | Value |
|---|---|---|
| `dto.amount` | Request body | `2900` |
| `dto.currency` | Request body | `"usd"` |
| `dto.customerId` | `req.user.stripeCustomerId` (from JWT) | `"cus_A1b2C3d4E5f6"` |

---

## Step 2 — Your NestJS API → Stripe API

**Request your backend makes to Stripe:**

```
POST https://api.stripe.com/v1/payment_intents
Authorization: Bearer sk_test_xxxxxxxxxxxx
Content-Type: application/x-www-form-urlencoded
Idempotency-Key: pi-cus_A1b2C3d4E5f6-1713744000000
```

```
amount=2900
&currency=usd
&customer=cus_A1b2C3d4E5f6
&automatic_payment_methods[enabled]=true
&metadata[customerId]=cus_A1b2C3d4E5f6
&metadata[userId]=1
```

> Stripe's API uses `application/x-www-form-urlencoded`, not JSON. The SDK handles this encoding — you write plain TypeScript objects and the SDK serializes them correctly.

**Response from Stripe (200 OK):**

```json
{
  "id": "pi_W8x9Y0z1A2b3",
  "object": "payment_intent",
  "amount": 2900,
  "currency": "usd",
  "status": "requires_payment_method",
  "client_secret": "pi_W8x9Y0z1A2b3_secret_C4d5E6f7G8h9",
  "customer": "cus_A1b2C3d4E5f6",
  "automatic_payment_methods": { "enabled": true },
  "metadata": {
    "customerId": "cus_A1b2C3d4E5f6",
    "userId": "1"
  },
  "created": 1713744000,
  "livemode": false
}
```

> The `client_secret` is what your backend extracts and passes to the frontend. It is safe to send to the browser — it can only be used to confirm this specific PaymentIntent, not to create new charges or access other data.

**DB write — insert a pending payment record immediately after Stripe responds:**

```sql
INSERT INTO payments (user_id, stripe_payment_intent_id, amount_cents, currency, status, created_at)
VALUES (1, 'pi_W8x9Y0z1A2b3', 2900, 'usd', 'pending', NOW());
```

**`payments` table after insert:**

| id | user_id | stripe_payment_intent_id | amount_cents | currency | status | confirmed_at | updated_at |
|----|---------|--------------------------|-------------|----------|--------|-------------|------------|
| pay-1 | 1 | `pi_W8x9Y0z1A2b3` | 2900 | usd | `pending` | NULL | 2025-04-20 10:00 |

> Write this record **before** returning the `client_secret` to the frontend. If the user abandons the payment mid-flow, you have an audit trail of what was initiated. `status = 'pending'` means the user has a PaymentIntent open but has not completed payment yet. Do not grant any access at this point.

---

## Step 3 — Your NestJS API → Frontend

**Response (201 Created):**

```json
{
  "clientSecret": "pi_W8x9Y0z1A2b3_secret_C4d5E6f7G8h9"
}
```

> You return **only** `clientSecret`. Do not return `paymentIntentId`, `amount`, `customerId`, or anything else from the Stripe response — the frontend only needs the secret to render the payment form.

---

## Step 4 — Frontend → Stripe (Stripe.js, not your server)

The frontend calls `stripe.confirmPayment()`. This goes **directly to Stripe's servers** — your backend is not involved.

**What Stripe.js sends internally:**

```
POST https://api.stripe.com/v1/payment_intents/pi_W8x9Y0z1A2b3/confirm
Authorization: Bearer pk_test_xxxxxxxxxxxx   ← publishable key, safe in browser
```

```json
{
  "payment_method": { "card": { ... } },
  "return_url": "https://yourapp.com/payment/complete"
}
```

**If payment succeeds — Stripe redirects browser to:**

```
https://yourapp.com/payment/complete
  ?payment_intent=pi_W8x9Y0z1A2b3
  &payment_intent_client_secret=pi_W8x9Y0z1A2b3_secret_C4d5E6f7G8h9
  &redirect_status=succeeded
```

**If payment fails — redirect with failure status:**

```
https://yourapp.com/payment/complete
  ?payment_intent=pi_W8x9Y0z1A2b3
  &payment_intent_client_secret=pi_W8x9Y0z1A2b3_secret_C4d5E6f7G8h9
  &redirect_status=failed
```

> **Never trust the redirect alone.** A user could manually visit the success URL with fabricated query params. Your DB must only be updated after verifying via webhook (Step 5).

---

## Step 5 — Stripe → Your NestJS Webhook Endpoint

After payment succeeds, Stripe sends a POST to your registered webhook URL.

**Request from Stripe:**

```
POST /webhooks/stripe
Content-Type: application/json
Stripe-Signature: t=1713744100,v1=a1b2c3d4e5f6...,v0=...
```

```json
{
  "id": "evt_I0j1K2l3M4n5",
  "object": "event",
  "type": "payment_intent.succeeded",
  "livemode": false,
  "created": 1713744100,
  "data": {
    "object": {
      "id": "pi_W8x9Y0z1A2b3",
      "object": "payment_intent",
      "amount": 2900,
      "amount_received": 2900,
      "currency": "usd",
      "status": "succeeded",
      "customer": "cus_A1b2C3d4E5f6",
      "metadata": {
        "customerId": "cus_A1b2C3d4E5f6",
        "userId": "1"
      },
      "created": 1713744000
    }
  }
}
```

> The `Stripe-Signature` header is what you verify with `stripe.webhooks.constructEvent()`. If the signature does not match your `STRIPE_WEBHOOK_SECRET`, reject the request immediately — someone is spoofing a payment success event.

**DB writes — triggered by this webhook event:**

```sql
-- 1. Update the payment record to confirmed
UPDATE payments
SET status = 'succeeded', confirmed_at = NOW(), updated_at = NOW()
WHERE stripe_payment_intent_id = 'pi_W8x9Y0z1A2b3';

-- 2. Grant whatever the payment unlocks (e.g. a lifetime feature, credits, an order)
-- This depends on your product — example for a lifetime deal:
INSERT INTO user_entitlements (user_id, feature, granted_at, source)
VALUES (1, 'lifetime_access', NOW(), 'payment:pi_W8x9Y0z1A2b3');
```

**`payments` table after webhook:**

| id | user_id | stripe_payment_intent_id | amount_cents | currency | status | confirmed_at | updated_at |
|----|---------|--------------------------|-------------|----------|--------|-------------|------------|
| pay-1 | 1 | `pi_W8x9Y0z1A2b3` | 2900 | usd | **`succeeded`** | **2025-04-20 10:01** | 2025-04-20 10:01 |

**`user_entitlements` table after webhook (example — depends on your product):**

| id | user_id | feature | granted_at | source |
|----|---------|---------|------------|--------|
| ent-1 | 1 | `lifetime_access` | 2025-04-20 10:01 | `payment:pi_W8x9Y0z1A2b3` |

> `source` links the entitlement back to the specific PaymentIntent. If you ever need to reverse it (e.g. a chargeback), you know exactly which payment granted access and can revoke it precisely.

**What happens if the webhook fires but the payment record does not exist** (e.g. your Step 2 DB write failed):

```sql
-- Use an UPSERT so the webhook is idempotent
INSERT INTO payments (user_id, stripe_payment_intent_id, amount_cents, currency, status, confirmed_at)
VALUES (1, 'pi_W8x9Y0z1A2b3', 2900, 'usd', 'succeeded', NOW())
ON CONFLICT (stripe_payment_intent_id)
DO UPDATE SET status = 'succeeded', confirmed_at = NOW(), updated_at = NOW();
```

> Webhooks can be delivered more than once. The `ON CONFLICT` (or a check-before-update) makes your handler idempotent — running it twice produces the same result as running it once.

**Your webhook handler must respond:**

```
HTTP 200 OK
Content-Type: application/json

{}
```

> If you return anything other than 2xx, Stripe retries the webhook up to 3 days with exponential backoff. Return 200 as soon as you receive the event — do your DB updates asynchronously if needed.

---

## Step 6 — Optional: Retrieve PaymentIntent Status

Your frontend can poll this after redirect to show the user their payment status before the webhook fires.

**Request:**

```
GET /payments/pi_W8x9Y0z1A2b3
Authorization: Bearer eyJhbGciOiJIUzI1NiJ9...
```

**Response (200 OK):**

```json
{
  "status": "succeeded",
  "amount": 2900,
  "currency": "usd"
}
```

> Read this from your local `payments` table, not by calling Stripe's API on every poll — your DB reflects the webhook-confirmed state and avoids unnecessary Stripe API calls.

**`payments` table — what the GET reads from:**

| id | user_id | stripe_payment_intent_id | amount_cents | currency | status | confirmed_at |
|----|---------|--------------------------|-------------|----------|--------|-------------|
| pay-1 | 1 | `pi_W8x9Y0z1A2b3` | 2900 | usd | `succeeded` | 2025-04-20 10:01 |

> If `status` is still `pending` when the user hits this endpoint (webhook hasn't arrived yet), return `{ "status": "pending" }` and let the frontend poll again in a few seconds. Do not grant access based on `pending` — only on `succeeded`.

---

## Step 7 — Cancel a Pending PaymentIntent

Only works while `status` is `requires_payment_method` or `requires_confirmation`. Cannot cancel a payment that is already `processing` or `succeeded`.

**Request:**

```
DELETE /payments/pi_W8x9Y0z1A2b3/cancel
Authorization: Bearer eyJhbGciOiJIUzI1NiJ9...
```

**Response (200 OK):**

```json
{
  "id": "pi_W8x9Y0z1A2b3",
  "status": "canceled",
  "cancellation_reason": "requested_by_customer"
}
```

**DB write — update local record to reflect cancellation:**

```sql
UPDATE payments
SET status = 'canceled', updated_at = NOW()
WHERE stripe_payment_intent_id = 'pi_W8x9Y0z1A2b3';
```

**`payments` table after cancellation:**

| id | user_id | stripe_payment_intent_id | amount_cents | currency | status | confirmed_at | updated_at |
|----|---------|--------------------------|-------------|----------|--------|-------------|------------|
| pay-1 | 1 | `pi_W8x9Y0z1A2b3` | 2900 | usd | **`canceled`** | NULL | 2025-04-20 10:05 |

> `confirmed_at` stays `NULL` — a canceled payment never confirmed. If the user wants to try again, a new PaymentIntent must be created, producing a new `pi_xxx` ID and a new row in the `payments` table.

**Response if already succeeded (400 Bad Request):**

```json
{
  "statusCode": 400,
  "message": "You cannot cancel this PaymentIntent because it has a status of succeeded."
}
```

---

## Error Response Reference

### Your API errors (from NestJS)

**Card declined — 400 Bad Request:**

```json
{
  "statusCode": 400,
  "message": "Your card was declined.",
  "error": "Bad Request"
}
```

**Invalid parameters — 400 Bad Request:**

```json
{
  "statusCode": 400,
  "message": "Invalid payment request",
  "error": "Bad Request"
}
```

**Unauthenticated — 401 Unauthorized:**

```json
{
  "statusCode": 401,
  "message": "Unauthorized"
}
```

**Stripe connection failure — 500 Internal Server Error:**

```json
{
  "statusCode": 500,
  "message": "Payment processing failed",
  "error": "Internal Server Error"
}
```

### Stripe API error shapes (what the SDK catches)

When a Stripe API call fails, the SDK throws a typed error. The raw Stripe error object looks like:

```json
{
  "type": "StripeCardError",
  "code": "card_declined",
  "decline_code": "insufficient_funds",
  "message": "Your card has insufficient funds.",
  "param": null,
  "payment_intent": {
    "id": "pi_W8x9Y0z1A2b3",
    "status": "requires_payment_method"
  }
}
```

| `type` | `code` examples | HTTP status from Stripe |
|---|---|---|
| `StripeCardError` | `card_declined`, `expired_card`, `incorrect_cvc` | 402 |
| `StripeInvalidRequestError` | `amount_too_small`, `currency_invalid` | 400 |
| `StripeAuthenticationError` | `api_key_invalid` | 401 |
| `StripeRateLimitError` | — | 429 |
| `StripeConnectionError` | — | Network timeout |

---

## PaymentIntent Status Transitions

```
[Created]
    │
    ▼
requires_payment_method ──── card details collected ────► requires_confirmation
                                                                  │
                                          ┌───────────────────────┘
                                          ▼
                                  requires_action  ──── 3DS passed ────┐
                                          │                             │
                                          │ 3DS failed                  │
                                          ▼                             ▼
                                      canceled                     processing
                                                                       │
                                              ┌────────────────────────┘
                                              ▼
                                         succeeded ✅
                                              │
                                     (webhook fires:
                                  payment_intent.succeeded)
```

---

## Idempotency Key Behaviour

| Scenario | Key used | Stripe behaviour |
|---|---|---|
| First request | `pi-cus_xxx-1713744000000` | Creates new PaymentIntent |
| Retry with same key within 24h | `pi-cus_xxx-1713744000000` | Returns the **same** PaymentIntent, no duplicate |
| Different key | `pi-cus_xxx-1713744001000` | Creates a **new** PaymentIntent |
| Same key, different params | `pi-cus_xxx-1713744000000` | Stripe returns `400 IdempotencyError` |

> The idempotency key must be unique **per operation**, not per user. `pi-${customerId}-${Date.now()}` is good for interactive payments. For server-side retry loops, use a stable key like `pi-${orderId}` so retries always reference the same intent.

---

## Header Reference

| Header | Direction | Purpose |
|---|---|---|
| `Authorization: Bearer sk_test_...` | Your backend → Stripe | Authenticates your API calls |
| `Authorization: Bearer pk_test_...` | Frontend → Stripe (via Stripe.js) | Authenticates Stripe.js card collection |
| `Authorization: Bearer <JWT>` | Frontend → Your API | Authenticates your user |
| `Idempotency-Key: <string>` | Your backend → Stripe | Prevents duplicate PaymentIntents on retry |
| `Stripe-Signature: t=...,v1=...` | Stripe → Your webhook | Proves webhook is from Stripe, not spoofed |
| `Content-Type: application/json` | Stripe → Your webhook | Stripe sends JSON |
| `Content-Type: application/x-www-form-urlencoded` | Your SDK → Stripe | Stripe's API expects form encoding (SDK handles this) |

---

## DB State Summary — Full Flow

The `payments` table at each stage of the lifecycle:

| Step | Trigger | `status` | `confirmed_at` | Notes |
|---|---|---|---|---|
| Step 2 — PaymentIntent created | Stripe API responds | `pending` | NULL | User has not paid yet |
| Step 4 — User abandons payment | (nothing fires) | `pending` | NULL | Row stays; use for abandoned payment analytics |
| Step 5 — Webhook: `payment_intent.succeeded` | Stripe delivers webhook | `succeeded` | timestamp | **Only here** do you grant access / fulfil the order |
| Step 5 — Webhook: `payment_intent.payment_failed` | Stripe delivers webhook | `failed` | NULL | Notify user; no access granted |
| Step 7 — User cancels | `DELETE /payments/:id/cancel` | `canceled` | NULL | New PaymentIntent needed for retry |

**Rule: never grant access based on the frontend redirect or `pending` status. Only `succeeded` — set by the webhook — unlocks your product.**

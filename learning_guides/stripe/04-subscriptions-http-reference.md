# 04 — Subscriptions: HTTP Reference

Supplementary to `04-subscriptions.md`. This note shows the actual request bodies, response shapes, headers, status codes, and DB states at every hop in the subscription lifecycle — creation, trial, renewal, failure, cancellation, and deletion.

---

## The Full Lifecycle with HTTP Details

```
Frontend        Your NestJS API          Stripe API        Stripe Webhooks
    │                  │                     │                    │
    │ POST /subscriptions                    │                    │
    │─────────────────►│                     │                    │
    │                  │ POST /v1/subscriptions                   │
    │                  │────────────────────►│                    │
    │                  │◄────────────────────│                    │
    │◄─────────────────│                     │                    │
    │  { clientSecret, subscriptionId }      │                    │
    │                  │                     │                    │
    │ stripe.confirmPayment()───────────────►│                    │
    │◄──────────────────────────────────────│                    │
    │  redirect to return_url               │                    │
    │                  │                     │ customer.subscription.updated (active)
    │                  │◄───────────────────────────────────────►│
    │                  │  [DB: status → active]                  │
    │                  │                     │                    │
    │                  │           (30 days later — renewal)     │
    │                  │                     │ invoice.paid       │
    │                  │◄───────────────────────────────────────►│
    │                  │  [DB: current_period_end extended]      │
    │                  │                     │                    │
    │ DELETE /subscriptions/:id              │                    │
    │─────────────────►│                     │                    │
    │                  │ POST /v1/subscriptions/:id (update)     │
    │                  │────────────────────►│                    │
    │◄─────────────────│                     │                    │
    │                  │                     │ customer.subscription.deleted
    │                  │◄───────────────────────────────────────►│
    │                  │  [DB: status → canceled]                │
```

---

## Step 1 — Frontend → Your NestJS API (Create Subscription)

**Request:**

```
POST /subscriptions
Authorization: Bearer eyJhbGciOiJIUzI1NiJ9...
Content-Type: application/json
```

```json
{
  "priceId": "price_starter_monthly"
}
```

> The frontend only sends the `priceId` — which plan the user chose. `customerId` is read server-side from `req.user.stripeCustomerId`. The user never touches Stripe IDs directly.

**What your controller receives:**

| Field | Source | Value |
|---|---|---|
| `dto.priceId` | Request body | `"price_starter_monthly"` |
| `customerId` | `req.user.stripeCustomerId` (from JWT) | `"cus_A1b2C3d4E5f6"` |

---

## Step 2 — Your NestJS API → Stripe API (Create Subscription)

**Request your backend makes to Stripe:**

```
POST https://api.stripe.com/v1/subscriptions
Authorization: Bearer sk_test_xxxxxxxxxxxx
Content-Type: application/x-www-form-urlencoded
```

```
customer=cus_A1b2C3d4E5f6
&items[0][price]=price_starter_monthly
&payment_behavior=default_incomplete
&payment_settings[save_default_payment_method]=on_subscription
&expand[]=latest_invoice.payment_intent
```

> `payment_behavior=default_incomplete` is critical. Without it, Stripe activates the subscription immediately even if payment hasn't been confirmed — the user gets access before paying.

**Response from Stripe (200 OK):**

```json
{
  "id": "sub_P7q8R9s0T1u2",
  "object": "subscription",
  "customer": "cus_A1b2C3d4E5f6",
  "status": "incomplete",
  "current_period_start": 1713744000,
  "current_period_end": 1716422400,
  "cancel_at_period_end": false,
  "trial_end": null,
  "items": {
    "data": [
      {
        "id": "si_abc123",
        "price": {
          "id": "price_starter_monthly",
          "unit_amount": 900,
          "currency": "usd",
          "recurring": { "interval": "month" }
        }
      }
    ]
  },
  "latest_invoice": {
    "id": "in_Q2r3S4t5U6v7",
    "status": "open",
    "amount_due": 900,
    "payment_intent": {
      "id": "pi_W8x9Y0z1A2b3",
      "status": "requires_payment_method",
      "client_secret": "pi_W8x9Y0z1A2b3_secret_C4d5E6f7G8h9"
    }
  }
}
```

> The `expand` option causes Stripe to embed `latest_invoice.payment_intent` in the response — without it you would need a second API call to get the `client_secret`. The subscription starts as `incomplete` and the invoice as `open` — nothing is charged yet.

**DB write — insert a local subscription record immediately:**

```sql
INSERT INTO subscriptions (
  user_id, stripe_subscription_id, stripe_price_id,
  status, current_period_end, trial_end, cancel_at_period_end
)
VALUES (1, 'sub_P7q8R9s0T1u2', 'price_starter_monthly',
        'incomplete', '2025-05-20 10:00', NULL, false);
```

**`subscriptions` table after insert:**

| id | user_id | stripe_subscription_id | stripe_price_id | status | trial_end | current_period_end | cancel_at_period_end |
|----|---------|------------------------|-----------------|--------|-----------|-------------------|---------------------|
| sub-1 | 1 | `sub_P7q8R9s0T1u2` | `price_starter_monthly` | `incomplete` | NULL | 2025-05-20 10:00 | false |

> `status = 'incomplete'` — do not grant any access yet. The user still needs to confirm payment.

---

## Step 3 — Your NestJS API → Frontend

**Response (201 Created):**

```json
{
  "clientSecret": "pi_W8x9Y0z1A2b3_secret_C4d5E6f7G8h9",
  "subscriptionId": "sub_P7q8R9s0T1u2"
}
```

> Unlike the one-time payment flow, you return `subscriptionId` here as well — the frontend may need it to poll subscription status or display in the UI. `clientSecret` is still the only thing needed for `stripe.confirmPayment()`.

---

## Step 4 — Frontend → Stripe (Confirm Payment)

The frontend calls `stripe.confirmPayment()` — goes directly to Stripe, your backend is not involved.

**If payment succeeds — Stripe redirects to:**

```
https://yourapp.com/subscription/complete
  ?payment_intent=pi_W8x9Y0z1A2b3
  &payment_intent_client_secret=pi_W8x9Y0z1A2b3_secret_C4d5E6f7G8h9
  &redirect_status=succeeded
```

> **Never update the DB based on this redirect.** Trust only the webhook (Step 5).

---

## Step 5 — Webhook: `customer.subscription.updated` (Subscription Activated)

After payment confirms, Stripe sends two webhooks in quick succession — wait for both to handle correctly.

**Webhook 1 — Subscription status changed:**

```
POST /webhooks/stripe
Stripe-Signature: t=1713744100,v1=a1b2c3d4e5f6...
```

```json
{
  "id": "evt_sub_activated",
  "type": "customer.subscription.updated",
  "data": {
    "object": {
      "id": "sub_P7q8R9s0T1u2",
      "status": "active",
      "customer": "cus_A1b2C3d4E5f6",
      "current_period_start": 1713744000,
      "current_period_end": 1716422400,
      "cancel_at_period_end": false,
      "trial_end": null,
      "items": {
        "data": [
          { "price": { "id": "price_starter_monthly" } }
        ]
      }
    },
    "previous_attributes": {
      "status": "incomplete"
    }
  }
}
```

> `previous_attributes` shows what changed — useful for only updating when status specifically transitions, not on every `subscription.updated` event.

**DB write:**

```sql
UPDATE subscriptions
SET status = 'active',
    stripe_price_id = 'price_starter_monthly',
    current_period_end = '2025-05-20 10:00',
    updated_at = NOW()
WHERE stripe_subscription_id = 'sub_P7q8R9s0T1u2';
```

**`subscriptions` table after webhook:**

| id | user_id | stripe_subscription_id | stripe_price_id | status | trial_end | current_period_end | cancel_at_period_end |
|----|---------|------------------------|-----------------|--------|-----------|-------------------|---------------------|
| sub-1 | 1 | `sub_P7q8R9s0T1u2` | `price_starter_monthly` | **`active`** | NULL | 2025-05-20 10:00 | false |

> `status = 'active'` — your app now grants full access. Every authenticated request checks this column.

---

## Step 6 — Webhook: `invoice.paid` (Monthly Renewal)

30 days later, Stripe auto-charges the saved card. No action needed from the user or your API. Stripe sends:

```json
{
  "id": "evt_renewal_paid",
  "type": "invoice.paid",
  "data": {
    "object": {
      "id": "in_renewal_001",
      "subscription": "sub_P7q8R9s0T1u2",
      "customer": "cus_A1b2C3d4E5f6",
      "amount_paid": 900,
      "status": "paid",
      "period_start": 1716422400,
      "period_end": 1719100800,
      "payment_intent": "pi_renewal_001"
    }
  }
}
```

**DB write — advance the billing period:**

```sql
UPDATE subscriptions
SET current_period_end = '2025-06-20 10:00',
    updated_at = NOW()
WHERE stripe_subscription_id = 'sub_P7q8R9s0T1u2';
```

**`subscriptions` table after renewal:**

| id | user_id | stripe_subscription_id | stripe_price_id | status | trial_end | current_period_end | cancel_at_period_end |
|----|---------|------------------------|-----------------|--------|-----------|-------------------|---------------------|
| sub-1 | 1 | `sub_P7q8R9s0T1u2` | `price_starter_monthly` | `active` | NULL | **2025-06-20 10:00** | false |

> Only `current_period_end` advances. `status` stays `active`. No user interaction needed — Stripe handles the charge and you handle the DB update.

---

## Step 7 — Webhook: `invoice.payment_failed` (Renewal Failed)

The next month's charge fails. Stripe retries automatically, but sends a webhook immediately.

```json
{
  "id": "evt_renewal_failed",
  "type": "invoice.payment_failed",
  "data": {
    "object": {
      "id": "in_renewal_002",
      "subscription": "sub_P7q8R9s0T1u2",
      "customer": "cus_A1b2C3d4E5f6",
      "amount_due": 900,
      "status": "open",
      "attempt_count": 1,
      "next_payment_attempt": 1719532800,
      "payment_intent": {
        "id": "pi_failed_001",
        "status": "requires_payment_method",
        "last_payment_error": {
          "code": "card_declined",
          "decline_code": "insufficient_funds",
          "message": "Your card has insufficient funds."
        }
      }
    }
  }
}
```

> `attempt_count` tells you which retry this is (1, 2, 3...). `next_payment_attempt` is when Stripe will try again. You should notify the user on attempt 1 and escalate the message on subsequent attempts.

**DB write — mark past_due (Stripe also sends `customer.subscription.updated`):**

```sql
UPDATE subscriptions
SET status = 'past_due',
    updated_at = NOW()
WHERE stripe_subscription_id = 'sub_P7q8R9s0T1u2';
```

**`subscriptions` table after payment failure:**

| id | user_id | stripe_subscription_id | stripe_price_id | status | trial_end | current_period_end | cancel_at_period_end |
|----|---------|------------------------|-----------------|--------|-----------|-------------------|---------------------|
| sub-1 | 1 | `sub_P7q8R9s0T1u2` | `price_starter_monthly` | **`past_due`** | NULL | 2025-06-20 10:00 | false |

> `current_period_end` does NOT advance — the period is not paid for. Your app reads `past_due` and shows a "Update your card" banner. Most SaaS apps allow continued access during `past_due` while Stripe retries.

---

## Step 8 — Cancel at Period End (User Cancels)

**Request:**

```
DELETE /subscriptions/sub_P7q8R9s0T1u2
Authorization: Bearer eyJhbGciOiJIUzI1NiJ9...
```

**Request your backend makes to Stripe:**

```
POST https://api.stripe.com/v1/subscriptions/sub_P7q8R9s0T1u2
Authorization: Bearer sk_test_xxxxxxxxxxxx
```

```
cancel_at_period_end=true
```

**Response from Stripe (200 OK):**

```json
{
  "id": "sub_P7q8R9s0T1u2",
  "status": "active",
  "cancel_at_period_end": true,
  "cancel_at": 1719100800,
  "current_period_end": 1719100800
}
```

> `status` is still `active` — the subscription is not canceled yet. The user keeps access until `current_period_end`. Only `cancel_at_period_end` flips to `true`.

**Your API response to frontend (200 OK):**

```json
{
  "message": "Subscription will cancel on 2025-06-20",
  "cancelAt": "2025-06-20T10:00:00Z",
  "status": "active"
}
```

**DB write — flip the flag, leave status active:**

```sql
UPDATE subscriptions
SET cancel_at_period_end = true,
    updated_at = NOW()
WHERE stripe_subscription_id = 'sub_P7q8R9s0T1u2';
```

**`subscriptions` table after cancel request:**

| id | user_id | stripe_subscription_id | stripe_price_id | status | trial_end | current_period_end | cancel_at_period_end |
|----|---------|------------------------|-----------------|--------|-----------|-------------------|---------------------|
| sub-1 | 1 | `sub_P7q8R9s0T1u2` | `price_starter_monthly` | `active` | NULL | 2025-06-20 10:00 | **true** |

> Your app reads `cancel_at_period_end = true` to show a "Your subscription ends on June 20" banner instead of the normal billing UI. Access is still granted because `status = 'active'`.

---

## Step 9 — Webhook: `customer.subscription.deleted` (Period Ends, Access Revoked)

When the billing period expires, Stripe automatically sends:

```json
{
  "id": "evt_sub_deleted",
  "type": "customer.subscription.deleted",
  "data": {
    "object": {
      "id": "sub_P7q8R9s0T1u2",
      "status": "canceled",
      "customer": "cus_A1b2C3d4E5f6",
      "canceled_at": 1719100800,
      "ended_at": 1719100800,
      "cancel_at_period_end": true
    }
  }
}
```

**DB write — revoke access:**

```sql
UPDATE subscriptions
SET status = 'canceled',
    cancel_at_period_end = false,
    updated_at = NOW()
WHERE stripe_subscription_id = 'sub_P7q8R9s0T1u2';
```

**`subscriptions` table — final state:**

| id | user_id | stripe_subscription_id | stripe_price_id | status | trial_end | current_period_end | cancel_at_period_end |
|----|---------|------------------------|-----------------|--------|-----------|-------------------|---------------------|
| sub-1 | 1 | `sub_P7q8R9s0T1u2` | `price_starter_monthly` | **`canceled`** | NULL | 2025-06-20 10:00 | false |

> Your app reads `status = 'canceled'` and redirects the user to a re-subscribe page. The row stays in your DB — never delete it. It is your billing history.

---

## Step 10 — Resume a Scheduled Cancellation

If the user changes their mind before the period ends:

**Request:**

```
PATCH /subscriptions/sub_P7q8R9s0T1u2/resume
Authorization: Bearer eyJhbGciOiJIUzI1NiJ9...
```

**Request your backend makes to Stripe:**

```
POST https://api.stripe.com/v1/subscriptions/sub_P7q8R9s0T1u2
```

```
cancel_at_period_end=false
```

**Response from Stripe (200 OK):**

```json
{
  "id": "sub_P7q8R9s0T1u2",
  "status": "active",
  "cancel_at_period_end": false,
  "cancel_at": null
}
```

**DB write:**

```sql
UPDATE subscriptions
SET cancel_at_period_end = false,
    updated_at = NOW()
WHERE stripe_subscription_id = 'sub_P7q8R9s0T1u2';
```

**`subscriptions` table — back to normal:**

| id | user_id | stripe_subscription_id | stripe_price_id | status | current_period_end | cancel_at_period_end |
|----|---------|------------------------|-----------------|--------|--------------------|---------------------|
| sub-1 | 1 | `sub_P7q8R9s0T1u2` | `price_starter_monthly` | `active` | 2025-06-20 10:00 | **false** |

---

## Free Trial Variant — Step 2 Differences

When creating a subscription with a trial, the Stripe response and DB state differ:

**Stripe response (trial subscription):**

```json
{
  "id": "sub_trial_001",
  "status": "trialing",
  "trial_start": 1713744000,
  "trial_end": 1714953600,
  "latest_invoice": {
    "amount_due": 0,
    "payment_intent": null
  }
}
```

> `amount_due = 0` and `payment_intent = null` — no charge during trial. Your Step 3 response must handle `clientSecret` being null:
> ```json
> { "clientSecret": null, "subscriptionId": "sub_trial_001" }
> ```
> The frontend skips `confirmPayment()` — there is nothing to confirm.

**`subscriptions` table (trial):**

| id | user_id | stripe_subscription_id | stripe_price_id | status | trial_end | current_period_end | cancel_at_period_end |
|----|---------|------------------------|-----------------|--------|-----------|-------------------|---------------------|
| sub-2 | 1 | `sub_trial_001` | `price_starter_monthly` | `trialing` | **2025-05-04 10:00** | 2025-05-04 10:00 | false |

> `trial_end` is populated. Your app shows "Trial ends May 4" and grants full access because `status = 'trialing'`.

When the trial ends and the card is charged successfully, Stripe sends `customer.subscription.updated` with `status: active` — the same webhook as Step 5. `trial_end` in the DB stays as a historical record of when the trial ended.

---

## Webhook Events Reference

| Event | When it fires | DB action |
|---|---|---|
| `customer.subscription.created` | New subscription created | Insert row with `incomplete` or `trialing` |
| `customer.subscription.updated` | Any status change | Update `status`, `stripe_price_id`, `current_period_end`, `cancel_at_period_end` |
| `customer.subscription.deleted` | Subscription fully ended | Set `status = 'canceled'` |
| `invoice.paid` | Successful charge (renewal or initial) | Advance `current_period_end` |
| `invoice.payment_failed` | Charge failed | Set `status = 'past_due'`, notify user |
| `invoice.upcoming` | 7 days before renewal | Send renewal reminder email (optional) |

> Handle `customer.subscription.updated` as your **catch-all**. It fires on every state change. Read the new `status` from the event and mirror it into your DB — simpler than handling every individual event separately.

---

## Error Response Reference

### Your API errors (from NestJS)

**Missing customer — 400 Bad Request:**

```json
{
  "statusCode": 400,
  "message": "Failed to initialize payment",
  "error": "Bad Request"
}
```

**Already subscribed — 409 Conflict:**

```json
{
  "statusCode": 409,
  "message": "User already has an active subscription",
  "error": "Conflict"
}
```

**Unauthenticated — 401 Unauthorized:**

```json
{
  "statusCode": 401,
  "message": "Unauthorized"
}
```

### Stripe API error shapes

**Invalid price ID:**

```json
{
  "type": "StripeInvalidRequestError",
  "code": "resource_missing",
  "message": "No such price: 'price_invalid'",
  "param": "items[0][price]"
}
```

**No payment method on customer:**

```json
{
  "type": "StripeInvalidRequestError",
  "code": "resource_missing",
  "message": "This customer has no attached payment source or default payment method.",
  "param": null
}
```

---

## DB State Summary — Full Subscription Lifecycle

| Step | Trigger | `status` | `cancel_at_period_end` | `current_period_end` | Access |
|---|---|---|---|---|---|
| Step 2 — Subscription created | Stripe API responds | `incomplete` | false | set | ❌ No |
| Step 5 — Payment confirmed | `customer.subscription.updated` webhook | `active` | false | set | ✅ Yes |
| Step 6 — Monthly renewal | `invoice.paid` webhook | `active` | false | **advanced** | ✅ Yes |
| Step 7 — Renewal fails | `invoice.payment_failed` webhook | `past_due` | false | unchanged | ⚠️ Grace period |
| Step 8 — User cancels | `DELETE /subscriptions/:id` | `active` | **true** | unchanged | ✅ Until period end |
| Step 9 — Period expires | `customer.subscription.deleted` webhook | `canceled` | false | unchanged | ❌ No |
| Trial created | Stripe API responds | `trialing` | false | = trial_end | ✅ Yes |
| Trial ends, charge succeeds | `customer.subscription.updated` webhook | `active` | false | advanced | ✅ Yes |
| Trial ends, charge fails | `invoice.payment_failed` + `customer.subscription.updated` | `past_due` | false | unchanged | ⚠️ Grace period |

**Rule: your app reads `subscriptions.status` on every request. Only `active` and `trialing` get full access. The DB is updated exclusively by webhooks — never by frontend redirects.**

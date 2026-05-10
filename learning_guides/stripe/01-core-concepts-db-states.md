# Stripe Core Concepts — Local DB States & Object Relationships

This document shows what your **local PostgreSQL database** looks like at each stage of the Stripe integration, alongside the corresponding Stripe-side objects. The goal is to make the relationship between your DB and Stripe's API concrete.

---

## The Golden Rule

> Stripe is the source of truth for billing. Your DB is the source of truth for your application state. You sync them via **webhooks**.

Your DB stores Stripe IDs (e.g. `cus_xxx`, `sub_xxx`) as foreign keys into Stripe's system. When you need billing details, you either read your local copy (for speed) or call Stripe's API directly (for accuracy).

---

## Scenario

- **Alice** signs up → Stripe Customer created
- Alice starts a **free trial** → SetupIntent to save card, Subscription created
- Trial ends → Stripe auto-charges → Invoice + PaymentIntent created
- Alice upgrades from Starter to Pro → Subscription updated
- Payment fails next month → Subscription goes `past_due`

---

## Stage 1 — Alice Signs Up (Customer Created)

When Alice registers, you immediately create a Stripe Customer and store the ID.

**Stripe side — Customer object:**
```json
{
  "id": "cus_A1b2C3d4E5f6",
  "email": "alice@example.com",
  "name": "Alice Smith",
  "created": 1713744000
}
```

**Your local `users` table:**

| id | email | name | stripe_customer_id | created_at |
|----|-------|------|--------------------|------------|
| 1 | alice@example.com | Alice Smith | `cus_A1b2C3d4E5f6` | 2025-04-20 09:00 |

> `stripe_customer_id` is the bridge between your world and Stripe's world. Every Stripe API call for Alice uses this ID — `stripe.subscriptions.create({ customer: 'cus_A1b2C3d4E5f6', ... })`. Without it you cannot look up her billing history.

**Your local `subscriptions` table** — no row yet (Alice hasn't chosen a plan):

| id | user_id | stripe_subscription_id | stripe_price_id | status | trial_end | current_period_end |
|----|---------|------------------------|-----------------|--------|-----------|-------------------|
| _(empty)_ | | | | | | |

---

## Stage 2 — Alice Starts a Free Trial (SetupIntent + Subscription)

Alice picks the Starter Plan (14-day free trial). You collect her card via SetupIntent (no charge yet), then create a Subscription with a trial period.

**Stripe side — SetupIntent (card saved, not charged):**
```json
{
  "id": "seti_X9y8Z7w6V5",
  "customer": "cus_A1b2C3d4E5f6",
  "status": "succeeded",
  "payment_method": "pm_K1l2M3n4O5p6"
}
```

**Stripe side — Subscription created:**
```json
{
  "id": "sub_P7q8R9s0T1u2",
  "customer": "cus_A1b2C3d4E5f6",
  "status": "trialing",
  "trial_end": 1714953600,
  "current_period_start": 1713744000,
  "current_period_end": 1716422400,
  "items": [
    {
      "price": {
        "id": "price_starter_monthly",
        "product": "prod_StarterPlan",
        "unit_amount": 900,
        "currency": "usd",
        "recurring": { "interval": "month" }
      }
    }
  ]
}
```

**Your local `subscriptions` table** — row inserted after receiving `customer.subscription.created` webhook:

| id | user_id | stripe_subscription_id | stripe_price_id | status | trial_end | current_period_end |
|----|---------|------------------------|-----------------|--------|-----------|-------------------|
| sub-1 | 1 | `sub_P7q8R9s0T1u2` | `price_starter_monthly` | `trialing` | 2025-05-04 09:00 | 2025-05-20 09:00 |

> `status = 'trialing'` is what your app gates features on. Only `trialing` and `active` get full access. Your app reads this local column — not Stripe's API — on every request so there is no Stripe API call in the hot path.

**Stripe side — Products & Prices (created once in Dashboard, never in code):**

| Stripe Object | id | name | amount | interval |
|---|---|---|---|---|
| Product | `prod_StarterPlan` | Starter Plan | — | — |
| Price | `price_starter_monthly` | — | $9.00 (900 cents) | monthly |
| Product | `prod_ProPlan` | Pro Plan | — | — |
| Price | `price_pro_monthly` | — | $29.00 (2900 cents) | monthly |

> You store these `price_id` values in your app config or `.env`. You never hardcode `900` or `2900` in your code — you reference the Price ID and let Stripe handle the amount.

---

## Stage 3 — Trial Ends, Stripe Auto-Charges (Invoice + PaymentIntent)

When the trial ends, Stripe automatically:
1. Creates an Invoice
2. Creates a PaymentIntent on that Invoice
3. Attempts to charge the saved card

**Stripe side — Invoice:**
```json
{
  "id": "in_Q2r3S4t5U6v7",
  "customer": "cus_A1b2C3d4E5f6",
  "subscription": "sub_P7q8R9s0T1u2",
  "amount_due": 900,
  "status": "paid",
  "payment_intent": "pi_W8x9Y0z1A2b3"
}
```

**Stripe side — PaymentIntent (the actual charge):**
```json
{
  "id": "pi_W8x9Y0z1A2b3",
  "customer": "cus_A1b2C3d4E5f6",
  "amount": 900,
  "currency": "usd",
  "status": "succeeded"
}
```

**Your local `subscriptions` table** — updated after `invoice.paid` webhook:

| id | user_id | stripe_subscription_id | stripe_price_id | status | trial_end | current_period_end |
|----|---------|------------------------|-----------------|--------|-----------|-------------------|
| sub-1 | 1 | `sub_P7q8R9s0T1u2` | `price_starter_monthly` | **`active`** | 2025-05-04 09:00 | **2025-06-20 09:00** |

> `status` flipped from `trialing` → `active`. `current_period_end` advanced by 1 month. Your app starts granting paid-tier access because the local `status` column is now `active`. No Stripe API call needed on each page load.

**Your local `invoices` table** (optional but recommended for receipts/audit):

| id | user_id | stripe_invoice_id | stripe_payment_intent_id | amount_cents | status | paid_at |
|----|---------|-------------------|--------------------------|-------------|--------|---------|
| inv-1 | 1 | `in_Q2r3S4t5U6v7` | `pi_W8x9Y0z1A2b3` | 900 | `paid` | 2025-05-04 09:01 |

> You do not need to store full invoice details locally — Stripe keeps the canonical record. Store the IDs and amount so you can render a billing history page without calling Stripe on every page load.

---

## Stage 4 — Alice Upgrades to Pro (Subscription Updated)

Alice clicks "Upgrade to Pro" in your UI. You call `stripe.subscriptions.update()` — you do **not** cancel and re-create. Stripe handles prorating the difference.

**Stripe API call:**
```typescript
await stripe.subscriptions.update('sub_P7q8R9s0T1u2', {
  items: [{ id: existingItemId, price: 'price_pro_monthly' }],
  proration_behavior: 'create_prorations',
});
```

**Stripe side — Subscription after update:**
```json
{
  "id": "sub_P7q8R9s0T1u2",
  "status": "active",
  "items": [
    { "price": { "id": "price_pro_monthly", "unit_amount": 2900 } }
  ]
}
```

**Your local `subscriptions` table** — updated after `customer.subscription.updated` webhook:

| id | user_id | stripe_subscription_id | stripe_price_id | status | trial_end | current_period_end |
|----|---------|------------------------|-----------------|--------|-----------|-------------------|
| sub-1 | 1 | `sub_P7q8R9s0T1u2` | **`price_pro_monthly`** | `active` | 2025-05-04 09:00 | 2025-06-20 09:00 |

> Only `stripe_price_id` changed. The same subscription row is reused — no new row. Your app reads `stripe_price_id` to determine which tier Alice is on (`price_starter_monthly` → Starter features, `price_pro_monthly` → Pro features).

---

## Stage 5 — Payment Fails Next Month (Subscription Goes Past Due)

Stripe attempts to charge Alice's card on the next renewal date. The charge fails (card expired). Stripe retries according to your Smart Retries settings — after all retries fail, it marks the subscription `past_due`.

**Stripe side — Invoice (failed):**
```json
{
  "id": "in_C4d5E6f7G8h9",
  "status": "open",
  "amount_due": 2900,
  "payment_intent": {
    "id": "pi_I0j1K2l3M4n5",
    "status": "requires_payment_method"
  }
}
```

**Your local `subscriptions` table** — updated after `customer.subscription.updated` webhook (status changed):

| id | user_id | stripe_subscription_id | stripe_price_id | status | trial_end | current_period_end |
|----|---------|------------------------|-----------------|--------|-----------|-------------------|
| sub-1 | 1 | `sub_P7q8R9s0T1u2` | `price_pro_monthly` | **`past_due`** | 2025-05-04 09:00 | 2025-07-20 09:00 |

> Your app reads `status = 'past_due'` and shows Alice a banner: "Your payment failed — please update your card." Feature access can be degraded or blocked depending on your policy. You do **not** cancel access immediately — Stripe retries for a configurable number of days.

**Your local `invoices` table** — new failed invoice row:

| id | user_id | stripe_invoice_id | stripe_payment_intent_id | amount_cents | status | paid_at |
|----|---------|-------------------|--------------------------|-------------|--------|---------|
| inv-1 | 1 | `in_Q2r3S4t5U6v7` | `pi_W8x9Y0z1A2b3` | 900 | `paid` | 2025-05-04 09:01 |
| inv-2 | 1 | `in_C4d5E6f7G8h9` | `pi_I0j1K2l3M4n5` | 2900 | **`open`** | NULL |

---

## Full Object Relationship Map

```
Your DB: users.id = 1
         └── stripe_customer_id = "cus_A1b2C3d4E5f6"
                       │
                       │  (Stripe side)
                       ▼
               Customer: cus_A1b2C3d4E5f6
               ├── PaymentMethod: pm_K1l2M3n4O5p6  (saved card)
               │
               ├── Subscription: sub_P7q8R9s0T1u2
               │   ├── Price: price_pro_monthly  ($29/mo)
               │   │   └── Product: prod_ProPlan
               │   │
               │   └── Invoice: in_Q2r3S4t5U6v7  (each billing cycle)
               │       └── PaymentIntent: pi_W8x9Y0z1A2b3  (the charge)
               │
               └── Invoice: in_C4d5E6f7G8h9  (failed renewal)
                   └── PaymentIntent: pi_I0j1K2l3M4n5  (failed charge)
```

```
Your DB:
users           ──── stripe_customer_id ────────────────► Stripe Customer
  │
  └── subscriptions ── stripe_subscription_id ──────────► Stripe Subscription
  │      └── stripe_price_id ──────────────────────────► Stripe Price
  │                                                            └── Stripe Product
  └── invoices ──── stripe_invoice_id ────────────────── ► Stripe Invoice
                 └── stripe_payment_intent_id ──────────► Stripe PaymentIntent
```

---

## Summary — Which Field Does What

| Your DB field | Stripe object it references | When it is set | What your app uses it for |
|---|---|---|---|
| `users.stripe_customer_id` | `Customer.id` | On user signup | All Stripe API calls for this user |
| `subscriptions.stripe_subscription_id` | `Subscription.id` | On `customer.subscription.created` webhook | Cancelling, upgrading, fetching details |
| `subscriptions.stripe_price_id` | `Price.id` | On subscription create/update webhook | Determining which feature tier to grant |
| `subscriptions.status` | `Subscription.status` | On every `customer.subscription.*` webhook | Gating app features (`active`/`trialing` = allow) |
| `subscriptions.current_period_end` | `Subscription.current_period_end` | On every billing cycle | Showing "next billing date" in UI |
| `subscriptions.trial_end` | `Subscription.trial_end` | On subscription create | Showing "trial ends on X" in UI |
| `invoices.stripe_invoice_id` | `Invoice.id` | On `invoice.paid` / `invoice.payment_failed` webhook | Rendering billing history |
| `invoices.stripe_payment_intent_id` | `PaymentIntent.id` | On `invoice.paid` webhook | Linking charge to invoice for receipts |

---

## Subscription Status → Feature Access

This is the logic your app runs on every authenticated request (or caches in the JWT):

| `subscriptions.status` | Feature access | Action |
|---|---|---|
| `trialing` | Full access | None — enjoy the trial |
| `active` | Full access | None — paying customer |
| `past_due` | Degraded or full | Show "update payment" banner |
| `unpaid` | Blocked | Redirect to billing page |
| `canceled` | Blocked | Redirect to re-subscribe |
| `incomplete` | Blocked | Initial payment not confirmed |
| _(no row)_ | Free tier only | Prompt to subscribe |

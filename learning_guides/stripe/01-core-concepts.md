# 01 — Stripe Core Concepts

---

## 1. What is Stripe?

Stripe is a **payment processing platform** that handles the complexity of accepting money online — card processing, fraud detection, subscriptions, invoicing, tax, and more.

As a developer, you interact with Stripe through its **REST API**. Stripe handles the hard parts (PCI compliance, card network communication, bank settlements) so you don't have to.

---

## 2. Stripe Environments — Test vs Live

Stripe gives you **two completely separate environments**:

| Environment | Purpose               | Real Money? |
| ----------- | --------------------- | ----------- |
| **Test**    | Development & testing | ❌ No       |
| **Live**    | Production            | ✅ Yes      |

Each environment has its own set of API keys. Everything you do in test mode (create customers, charge cards, trigger webhooks) is completely isolated from live mode.

> **Rule:** Always build and test in test mode. Switch to live keys only when you are ready to go to production.

---

## 3. API Keys

Stripe uses API keys to authenticate your requests. You get these from your Stripe Dashboard under **Developers → API Keys**.

### Key types:

| Key                 | Prefix                        | Used Where            | Can it charge cards? |
| ------------------- | ----------------------------- | --------------------- | -------------------- |
| **Publishable key** | `pk_test_...` / `pk_live_...` | Frontend (browser)    | ❌ No                |
| **Secret key**      | `sk_test_...` / `sk_live_...` | Backend (server only) | ✅ Yes               |
| **Webhook secret**  | `whsec_...`                   | Backend only          | N/A                  |

> ⚠️ **Critical:** Never expose your **secret key** in frontend code or commit it to Git. It can be used to make real charges, issue refunds, and access all your customer data.

### In NestJS — storing keys safely:

```bash
# .env
STRIPE_SECRET_KEY=sk_test_xxxxxxxxxxxx
STRIPE_PUBLISHABLE_KEY=pk_test_xxxxxxxxxxxx
STRIPE_WEBHOOK_SECRET=whsec_xxxxxxxxxxxx
```

```typescript
// stripe.module.ts
import { Module } from "@nestjs/common";
import { ConfigModule, ConfigService } from "@nestjs/config";
import Stripe from "stripe";

@Module({
  imports: [ConfigModule],
  providers: [
    {
      provide: "STRIPE_CLIENT",
      useFactory: (configService: ConfigService) => {
        return new Stripe(configService.get("STRIPE_SECRET_KEY"), {
          apiVersion: "2024-04-10",
        });
      },
      inject: [ConfigService],
    },
  ],
  exports: ["STRIPE_CLIENT"],
})
export class StripeModule {}
```

---

## 4. Core Stripe Objects

Understanding these objects is fundamental. Everything in Stripe revolves around them.

---

### 4.1 Customer

A **Customer** object represents a person who pays you. Stripe stores their payment methods, billing info, and payment history.

```
Customer
├── id: cus_xxxxxxxx
├── email: user@example.com
├── name: John Doe
└── payment methods (cards attached to this customer)
```

**Why create a Customer?**

- Saves card details for future payments (no re-entering card)
- Required for subscriptions
- Lets you view all payments for a user in Stripe Dashboard
- Enables Stripe Customer Portal (self-service billing management)

> **SaaS rule:** Always create a Stripe Customer when a user signs up (or at latest, when they first pay). Store the `customer.id` in your database linked to your user.

```typescript
// Creating a customer in NestJS
async createCustomer(email: string, name: string): Promise<Stripe.Customer> {
  return await this.stripe.customers.create({ email, name });
}
```

---

### 4.2 Product

A **Product** represents what you are selling. In a SaaS context, this is typically your plan (e.g., "Starter Plan", "Pro Plan").

```
Product
├── id: prod_xxxxxxxx
├── name: "Pro Plan"
└── description: "Access to all Pro features"
```

Products themselves have **no price** attached — that comes from the Price object.

> Products are usually created once in the Stripe Dashboard, not programmatically on every request.

---

### 4.3 Price

A **Price** is attached to a Product and defines **how much** and **how often** to charge.

```
Price
├── id: price_xxxxxxxx
├── product: prod_xxxxxxxx       ← linked to a Product
├── unit_amount: 2900            ← $29.00 (always in smallest currency unit — cents)
├── currency: usd
└── recurring:
    ├── interval: month          ← monthly or yearly
    └── interval_count: 1
```

**Two types of prices:**

| Type          | Description           | Example                          |
| ------------- | --------------------- | -------------------------------- |
| **One-time**  | Charged once          | A setup fee, lifetime deal       |
| **Recurring** | Charged on a schedule | Monthly/yearly SaaS subscription |

> ⚠️ **Important:** Stripe stores amounts in the **smallest currency unit**. For USD, that is **cents**. So $29.00 = `2900`. Always remember this when reading or writing amounts.

---

### 4.4 PaymentIntent

A **PaymentIntent** represents a **single attempt to collect a payment**. It tracks the full lifecycle of a one-time payment.

```
PaymentIntent
├── id: pi_xxxxxxxx
├── amount: 2900                 ← $29.00 in cents
├── currency: usd
├── status: requires_payment_method | requires_confirmation | processing | succeeded | canceled
├── customer: cus_xxxxxxxx
└── client_secret: pi_xxx_secret_xxx   ← sent to frontend to confirm payment
```

**PaymentIntent statuses:**

| Status                    | Meaning                                 |
| ------------------------- | --------------------------------------- |
| `requires_payment_method` | Waiting for card details                |
| `requires_confirmation`   | Ready to be confirmed                   |
| `processing`              | Payment is being processed              |
| `succeeded`               | Payment completed ✅                    |
| `requires_action`         | 3D Secure / extra authentication needed |
| `canceled`                | Payment was canceled                    |

```typescript
// Creating a PaymentIntent in NestJS
async createPaymentIntent(amount: number, customerId: string): Promise<Stripe.PaymentIntent> {
  return await this.stripe.paymentIntents.create({
    amount,          // in cents e.g. 2900 for $29.00
    currency: 'usd',
    customer: customerId,
  });
}
```

---

### 4.5 Subscription

A **Subscription** represents a recurring billing relationship between a Customer and a Price.

```
Subscription
├── id: sub_xxxxxxxx
├── customer: cus_xxxxxxxx
├── status: trialing | active | past_due | canceled | unpaid | incomplete
├── current_period_start: 1713744000
├── current_period_end: 1716336000
└── items:
    └── price: price_xxxxxxxx    ← the plan they are subscribed to
```

**Subscription statuses:**

| Status       | Meaning                                      |
| ------------ | -------------------------------------------- |
| `trialing`   | In free trial period                         |
| `active`     | Paying and active ✅                         |
| `past_due`   | Payment failed, retrying                     |
| `unpaid`     | All retries failed, access should be revoked |
| `canceled`   | Subscription ended                           |
| `incomplete` | Initial payment not completed                |

> **SaaS rule:** Gate your app features based on the subscription status. Only `active` and `trialing` should have full access.

```typescript
// Creating a Subscription in NestJS
async createSubscription(customerId: string, priceId: string): Promise<Stripe.Subscription> {
  return await this.stripe.subscriptions.create({
    customer: customerId,
    items: [{ price: priceId }],
    payment_behavior: 'default_incomplete',
    expand: ['latest_invoice.payment_intent'],
  });
}
```

---

### 4.6 Invoice

An **Invoice** is automatically created by Stripe for every billing cycle of a subscription. It represents the bill sent to the customer.

```
Invoice
├── id: in_xxxxxxxx
├── customer: cus_xxxxxxxx
├── subscription: sub_xxxxxxxx
├── amount_due: 2900
├── status: draft | open | paid | void | uncollectible
└── payment_intent: pi_xxxxxxxx   ← the actual charge attempt
```

You don't create invoices manually for subscriptions — Stripe creates them automatically. However, you will receive **webhook events** about invoices (`invoice.paid`, `invoice.payment_failed`) which are critical for your SaaS.

---

### 4.7 SetupIntent

A **SetupIntent** is used to **save a payment method for future use** without charging immediately.

```
SetupIntent
├── id: seti_xxxxxxxx
├── customer: cus_xxxxxxxx
├── status: requires_payment_method | succeeded
└── payment_method: pm_xxxxxxxx   ← saved card
```

**When to use SetupIntent vs PaymentIntent:**

|              | PaymentIntent    | SetupIntent               |
| ------------ | ---------------- | ------------------------- |
| **Purpose**  | Charge now       | Save card for later       |
| **Use case** | One-time payment | Free trial → charge after |

> In SaaS, SetupIntent is commonly used for **free trials** — collect the card at signup, but don't charge until the trial ends.

---

## 5. How These Objects Relate

```
Customer (cus_xxx)
│
├── PaymentMethod (pm_xxx)     ← saved card
│
├── PaymentIntent (pi_xxx)     ← one-time payment
│   └── amount, currency, status
│
└── Subscription (sub_xxx)     ← recurring billing
    ├── Price (price_xxx)      ← how much & how often
    │   └── Product (prod_xxx) ← what they're buying
    │
    └── Invoice (in_xxx)       ← generated each billing cycle
        └── PaymentIntent (pi_xxx) ← the actual charge
```

---

## 6. Stripe Dashboard — What to Know

The Stripe Dashboard ([dashboard.stripe.com](https://dashboard.stripe.com)) is where you:

- Switch between **Test and Live** mode (toggle in the top left)
- View all customers, payments, subscriptions, invoices
- Create Products and Prices
- Get your API keys
- Set up webhook endpoints
- Use the **Stripe CLI** for local testing

> Always create your **Products and Prices** in the Dashboard first, then copy the `price_id` into your NestJS code. Do not hardcode price amounts in code — reference Stripe Price IDs.

---

## 7. Idempotency Keys

Stripe API calls can sometimes fail due to network issues. If you retry, you might accidentally double-charge a customer. **Idempotency keys** prevent this.

By sending a unique key with your request, Stripe guarantees that even if you retry, it will not create a duplicate.

```typescript
// Using idempotency key in NestJS
await this.stripe.paymentIntents.create(
  { amount: 2900, currency: "usd", customer: customerId },
  { idempotencyKey: `payment-${userId}-${orderId}` }, // unique per operation
);
```

> **Rule:** Always use idempotency keys for payment creation requests.

---

## 8. Quick Summary

| Object            | What it is                                      |
| ----------------- | ----------------------------------------------- |
| **Customer**      | The person paying you                           |
| **Product**       | What you are selling (e.g., "Pro Plan")         |
| **Price**         | How much and how often (attached to a Product)  |
| **PaymentIntent** | A single payment attempt (one-time)             |
| **Subscription**  | Recurring billing relationship                  |
| **Invoice**       | Auto-generated bill per billing cycle           |
| **SetupIntent**   | Save a card without charging (e.g., free trial) |

---

_Next → `02-frontend-integration.md` — Stripe.js, Stripe Elements, and securely collecting card details_

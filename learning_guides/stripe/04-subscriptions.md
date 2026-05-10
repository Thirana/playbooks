# 04 — Subscriptions (NestJS)

---

## 1. What is a Stripe Subscription?

A subscription is a **recurring billing relationship** between your app and a customer. Stripe automatically:

- Charges the customer on each billing cycle
- Creates invoices
- Handles failed payments and retries
- Sends you webhook events at every stage

You define **what** to charge (Product + Price), and Stripe handles the **when** and **how**.

---

## 2. The Building Blocks of a Subscription

Before creating a subscription, you need these in place:

```
Product  →  Price  →  Customer  →  Subscription
"Pro Plan"  "$29/mo"  "John Doe"   (billing relationship)
```

| Object           | Created by                | When                     |
| ---------------- | ------------------------- | ------------------------ |
| **Product**      | You (in Stripe Dashboard) | Once, upfront            |
| **Price**        | You (in Stripe Dashboard) | Once per plan tier       |
| **Customer**     | Your NestJS backend       | When user signs up       |
| **Subscription** | Your NestJS backend       | When user selects a plan |

> **Rule:** Create Products and Prices in the Stripe Dashboard. Store their IDs in your `.env` or config. Never hardcode amounts in code — always reference Price IDs.

```bash
# .env
STRIPE_PRICE_STARTER_MONTHLY=price_xxxxxxxxxxxxxxxx
STRIPE_PRICE_PRO_MONTHLY=price_xxxxxxxxxxxxxxxx
STRIPE_PRICE_PRO_YEARLY=price_xxxxxxxxxxxxxxxx
```

---

## 3. Subscription Lifecycle

Understanding the full lifecycle is critical for a SaaS — each status determines what access a user should have.

```
                    ┌─────────────────────────────────────┐
                    ↓                                     |
[incomplete] → [trialing] → [active] → [past_due] → [unpaid]
                                ↓                        ↓
                           [canceled]              [canceled]
```

| Status               | Meaning                                  | Grant Access?    |
| -------------------- | ---------------------------------------- | ---------------- |
| `incomplete`         | Initial payment not completed            | ❌ No            |
| `incomplete_expired` | User never finished setup (23hr timeout) | ❌ No            |
| `trialing`           | In free trial period                     | ✅ Yes           |
| `active`             | Paying, all good                         | ✅ Yes           |
| `past_due`           | Payment failed, Stripe is retrying       | ⚠️ Your choice\* |
| `unpaid`             | All retries failed                       | ❌ No            |
| `canceled`           | Subscription ended                       | ❌ No            |
| `paused`             | Billing paused (Stripe feature)          | ❌ No            |

> \*`past_due` — Most SaaS apps give a grace period (3–7 days) while retrying. You can show a banner saying "Payment failed, please update your card" without immediately revoking access.

---

## 4. The Subscription Creation Flow

```
1. User selects a plan on your pricing page
        ↓
2. Frontend calls NestJS → create subscription
        ↓
3. NestJS creates Subscription → Stripe generates an Invoice + PaymentIntent
        ↓
4. NestJS returns client_secret to frontend
        ↓
5. Frontend confirms payment via stripe.confirmPayment()
        ↓
6. Stripe activates the subscription
        ↓
7. Stripe sends webhook → customer.subscription.updated (status: active)
        ↓
8. NestJS webhook handler updates your database
```

---

## 5. NestJS Implementation

### 5.1 DTO

```typescript
// src/subscriptions/dto/create-subscription.dto.ts
import { IsString } from "class-validator";

export class CreateSubscriptionDto {
  @IsString()
  priceId: string; // e.g. 'price_xxxxxxxx' — the Stripe Price ID
}
```

---

### 5.2 Subscriptions Service

```typescript
// src/subscriptions/subscriptions.service.ts
import { Injectable, Inject, BadRequestException } from "@nestjs/common";
import Stripe from "stripe";

@Injectable()
export class SubscriptionsService {
  constructor(@Inject("STRIPE_CLIENT") private readonly stripe: Stripe) {}

  // Create a new subscription
  async createSubscription(
    customerId: string,
    priceId: string,
  ): Promise<{ clientSecret: string; subscriptionId: string }> {
    const subscription = await this.stripe.subscriptions.create({
      customer: customerId,
      items: [{ price: priceId }],
      payment_behavior: "default_incomplete", // don't activate until payment confirmed
      payment_settings: {
        save_default_payment_method: "on_subscription", // save card for future renewals
      },
      expand: ["latest_invoice.payment_intent"], // get client_secret in one call
    });

    const invoice = subscription.latest_invoice as Stripe.Invoice;
    const paymentIntent = invoice.payment_intent as Stripe.PaymentIntent;

    if (!paymentIntent?.client_secret) {
      throw new BadRequestException("Failed to initialize payment");
    }

    return {
      clientSecret: paymentIntent.client_secret,
      subscriptionId: subscription.id,
    };
  }

  // Cancel a subscription (at period end — user keeps access until billing period ends)
  async cancelSubscription(
    subscriptionId: string,
  ): Promise<Stripe.Subscription> {
    return await this.stripe.subscriptions.update(subscriptionId, {
      cancel_at_period_end: true, // polite cancel — access until end of billing period
    });
  }

  // Cancel immediately (revoke access right away)
  async cancelSubscriptionImmediately(
    subscriptionId: string,
  ): Promise<Stripe.Subscription> {
    return await this.stripe.subscriptions.cancel(subscriptionId);
  }

  // Retrieve subscription details
  async getSubscription(subscriptionId: string): Promise<Stripe.Subscription> {
    return await this.stripe.subscriptions.retrieve(subscriptionId);
  }

  // Resume a subscription that was set to cancel at period end
  async resumeSubscription(
    subscriptionId: string,
  ): Promise<Stripe.Subscription> {
    return await this.stripe.subscriptions.update(subscriptionId, {
      cancel_at_period_end: false,
    });
  }
}
```

**Key options explained:**

| Option                                           | Meaning                                                                                                |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| `payment_behavior: 'default_incomplete'`         | Subscription starts as `incomplete` until payment is confirmed — prevents activating without payment   |
| `save_default_payment_method: 'on_subscription'` | Saves the card so Stripe can auto-charge on renewal                                                    |
| `expand: ['latest_invoice.payment_intent']`      | Tells Stripe to include nested objects — otherwise you'd need a second API call to get `client_secret` |
| `cancel_at_period_end: true`                     | Polite cancel — user keeps access until the end of their paid period                                   |

---

### 5.3 Subscriptions Controller

```typescript
// src/subscriptions/subscriptions.controller.ts
import {
  Controller,
  Post,
  Delete,
  Patch,
  Body,
  Param,
  UseGuards,
  Req,
} from "@nestjs/common";
import { SubscriptionsService } from "./subscriptions.service";
import { CreateSubscriptionDto } from "./dto/create-subscription.dto";
import { JwtAuthGuard } from "../auth/jwt-auth.guard";

@Controller("subscriptions")
@UseGuards(JwtAuthGuard)
export class SubscriptionsController {
  constructor(private readonly subscriptionsService: SubscriptionsService) {}

  // Create subscription → returns client_secret for frontend
  @Post()
  async createSubscription(@Body() dto: CreateSubscriptionDto, @Req() req) {
    return await this.subscriptionsService.createSubscription(
      req.user.stripeCustomerId,
      dto.priceId,
    );
  }

  // Cancel at end of billing period (recommended)
  @Delete(":id")
  async cancelSubscription(@Param("id") id: string) {
    return await this.subscriptionsService.cancelSubscription(id);
  }

  // Resume a scheduled cancellation
  @Patch(":id/resume")
  async resumeSubscription(@Param("id") id: string) {
    return await this.subscriptionsService.resumeSubscription(id);
  }
}
```

---

## 6. Free Trials

Stripe has built-in support for free trials. You set a `trial_period_days` when creating the subscription.

```typescript
async createSubscriptionWithTrial(
  customerId: string,
  priceId: string,
  trialDays: number,
): Promise<{ clientSecret: string; subscriptionId: string }> {
  const subscription = await this.stripe.subscriptions.create({
    customer: customerId,
    items: [{ price: priceId }],
    trial_period_days: trialDays, // e.g. 14
    payment_behavior: 'default_incomplete',
    payment_settings: {
      save_default_payment_method: 'on_subscription',
    },
    expand: ['latest_invoice.payment_intent'],
  });

  // During trial, the invoice amount is $0
  // client_secret may be null if no payment is needed yet
  const invoice = subscription.latest_invoice as Stripe.Invoice;
  const paymentIntent = invoice.payment_intent as Stripe.PaymentIntent;

  return {
    clientSecret: paymentIntent?.client_secret ?? '',
    subscriptionId: subscription.id,
  };
}
```

**Trial flow:**

```
Day 0:  User signs up → subscription status: trialing
Day 14: Trial ends → Stripe charges card automatically
        → If payment succeeds: status becomes active
        → If payment fails: status becomes past_due
```

> **Important:** For free trials, you should collect the card at signup using a **SetupIntent** (covered in Note 01) even if there's nothing to charge yet. This way Stripe can auto-charge when the trial ends.

---

## 7. What to Store in Your Database

When a subscription is created, store these fields in your `users` table (or a dedicated `subscriptions` table):

```typescript
// Example user entity
@Entity()
export class User {
  @Column({ nullable: true })
  stripeCustomerId: string; // cus_xxxxxxxx

  @Column({ nullable: true })
  stripeSubscriptionId: string; // sub_xxxxxxxx

  @Column({ nullable: true })
  stripePriceId: string; // price_xxxxxxxx — which plan they're on

  @Column({ default: "inactive" })
  subscriptionStatus: string; // mirror of Stripe's status

  @Column({ nullable: true })
  trialEndsAt: Date; // when trial expires

  @Column({ nullable: true })
  currentPeriodEnd: Date; // when current billing period ends
}
```

> Your database is the **source of truth for your app**. Stripe is the source of truth for billing. Keep them in sync via webhooks.

---

## 8. Cancellation — Two Approaches

| Approach                 | Method                       | Access after cancel          |
| ------------------------ | ---------------------------- | ---------------------------- |
| **Cancel at period end** | `cancel_at_period_end: true` | ✅ Until billing period ends |
| **Cancel immediately**   | `subscriptions.cancel(id)`   | ❌ Immediate                 |

**Recommended for SaaS:** Always use `cancel_at_period_end: true`. Users expect to keep access for the period they paid for. Immediate cancellation feels hostile and leads to chargebacks.

```typescript
// What Stripe sends back after cancel_at_period_end = true
{
  status: 'active',               // still active!
  cancel_at_period_end: true,     // but will cancel on...
  cancel_at: 1716336000,          // this timestamp
  current_period_end: 1716336000  // same as cancel_at
}
```

When the period ends, Stripe sends a `customer.subscription.deleted` webhook — that's when you revoke access in your DB.

---

## 9. The Invoice Object in Subscriptions

Every billing cycle, Stripe automatically creates an **Invoice** for the subscription. Understanding it is important for webhook handling.

```
Subscription billing cycle
        ↓
Stripe creates Invoice (status: open)
        ↓
Stripe creates PaymentIntent and charges saved card
        ↓
Payment succeeds → Invoice status: paid
        ↓
Stripe sends webhook: invoice.paid ✅

OR

Payment fails → Invoice status: open (retry later)
        ↓
Stripe sends webhook: invoice.payment_failed ❌
```

The two most important invoice webhook events for your SaaS:

| Event                    | What it means      | Your action                          |
| ------------------------ | ------------------ | ------------------------------------ |
| `invoice.paid`           | Renewal successful | Extend `currentPeriodEnd` in DB      |
| `invoice.payment_failed` | Renewal failed     | Notify user, show update card banner |

---

## 10. Subscription vs PaymentIntent — Key Difference

|                          | PaymentIntent              | Subscription                                     |
| ------------------------ | -------------------------- | ------------------------------------------------ |
| **Use case**             | One-time charge            | Recurring billing                                |
| **Who creates invoices** | You (implicit)             | Stripe (automatic)                               |
| **Renewal**              | Manual                     | Automatic                                        |
| **Main webhook event**   | `payment_intent.succeeded` | `invoice.paid` / `customer.subscription.updated` |

---

## 11. Testing Subscriptions

Use Stripe's test clock feature in the Dashboard to simulate time passing (trial ending, renewal, etc.) without waiting.

Test cards for subscriptions:

| Card                  | Scenario                                  |
| --------------------- | ----------------------------------------- |
| `4242 4242 4242 4242` | Subscription activates ✅                 |
| `4000 0000 0000 0341` | Card attached but payment fails on charge |
| `4000 0000 0000 9995` | Insufficient funds on renewal             |

---

## 12. Quick Summary

| Concept                                     | Key Takeaway                                            |
| ------------------------------------------- | ------------------------------------------------------- |
| `payment_behavior: 'default_incomplete'`    | Prevents activating subscription without payment        |
| `expand: ['latest_invoice.payment_intent']` | Gets client_secret without a second API call            |
| `save_default_payment_method`               | Saves card for auto-renewal                             |
| `cancel_at_period_end: true`                | Polite cancellation — keep access till period ends      |
| **Trial**                                   | Set `trial_period_days`, collect card via SetupIntent   |
| **DB fields**                               | Store subscriptionId, status, priceId, currentPeriodEnd |
| **invoice.paid**                            | Most important webhook event for subscription renewals  |

---

_Next → `05-upgrade-downgrade-proration.md` — Handling plan changes and how Stripe calculates prorated amounts_

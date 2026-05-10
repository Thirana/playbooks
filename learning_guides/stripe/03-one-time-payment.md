# 03 — One-Time Payments (NestJS)

---

## 1. What is a One-Time Payment?

A one-time payment is a **single charge** to a customer — no recurring billing. Common SaaS use cases:

- Lifetime deal purchases
- Add-on features (pay once, unlock forever)
- Setup or onboarding fees
- Credits or top-ups

Stripe handles one-time payments through the **PaymentIntent API**.

---

## 2. The Complete One-Time Payment Flow

```
1. User clicks "Buy"
        ↓
2. Frontend calls your NestJS backend
        ↓
3. NestJS creates a PaymentIntent → returns client_secret to frontend
        ↓
4. Frontend renders PaymentElement with client_secret
        ↓
5. User enters card details and clicks "Pay"
        ↓
6. Stripe.js sends card details directly to Stripe (not your server)
        ↓
7. Stripe processes the payment
        ↓
8. Stripe redirects to your return_url (success/failure)
        ↓
9. Stripe sends a webhook to your NestJS backend (payment_intent.succeeded)
        ↓
10. Your NestJS backend updates the database
```

> Steps 2–8 are the **frontend flow**. Step 9–10 is the **backend confirmation** via webhook (covered in Note 07). Never rely only on the frontend redirect to confirm a payment — always verify via webhook.

---

## 3. Project Structure

Here is a clean NestJS module structure for payments:

```
src/
└── payments/
    ├── payments.module.ts
    ├── payments.controller.ts
    ├── payments.service.ts
    └── dto/
        └── create-payment-intent.dto.ts
```

---

## 4. Installing Stripe in NestJS

```bash
npm install stripe
npm install --save-dev @types/stripe
```

---

## 5. Stripe Module Setup

Create a dedicated Stripe module so the client is injectable across your app:

```typescript
// src/stripe/stripe.module.ts
import { Module, Global } from "@nestjs/common";
import { ConfigModule, ConfigService } from "@nestjs/config";
import Stripe from "stripe";

@Global() // Makes StripeModule available everywhere without re-importing
@Module({
  imports: [ConfigModule],
  providers: [
    {
      provide: "STRIPE_CLIENT",
      useFactory: (configService: ConfigService): Stripe => {
        return new Stripe(configService.get<string>("STRIPE_SECRET_KEY")!, {
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

```typescript
// src/app.module.ts
import { StripeModule } from "./stripe/stripe.module";

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    StripeModule,
    PaymentsModule,
  ],
})
export class AppModule {}
```

---

## 6. DTO — Validating Incoming Requests

```typescript
// src/payments/dto/create-payment-intent.dto.ts
import { IsNumber, IsString, IsOptional, Min } from "class-validator";

export class CreatePaymentIntentDto {
  @IsNumber()
  @Min(50) // Stripe minimum is 50 cents
  amount: number; // in cents

  @IsString()
  currency: string; // e.g. 'usd'

  @IsString()
  @IsOptional()
  customerId?: string; // Stripe customer ID (cus_xxx)
}
```

---

## 7. Payments Service

```typescript
// src/payments/payments.service.ts
import { Injectable, Inject } from "@nestjs/common";
import Stripe from "stripe";
import { CreatePaymentIntentDto } from "./dto/create-payment-intent.dto";

@Injectable()
export class PaymentsService {
  constructor(@Inject("STRIPE_CLIENT") private readonly stripe: Stripe) {}

  async createPaymentIntent(
    dto: CreatePaymentIntentDto,
  ): Promise<Stripe.PaymentIntent> {
    return await this.stripe.paymentIntents.create(
      {
        amount: dto.amount,
        currency: dto.currency,
        customer: dto.customerId,
        automatic_payment_methods: { enabled: true }, // enables Apple Pay, Google Pay etc.
        metadata: {
          // attach any useful info — this comes back in webhook events
          customerId: dto.customerId ?? "",
        },
      },
      {
        idempotencyKey: `pi-${dto.customerId}-${Date.now()}`, // prevents duplicate charges
      },
    );
  }

  async retrievePaymentIntent(
    paymentIntentId: string,
  ): Promise<Stripe.PaymentIntent> {
    return await this.stripe.paymentIntents.retrieve(paymentIntentId);
  }

  async cancelPaymentIntent(
    paymentIntentId: string,
  ): Promise<Stripe.PaymentIntent> {
    return await this.stripe.paymentIntents.cancel(paymentIntentId);
  }
}
```

**Key options explained:**

| Option                      | Meaning                                                   |
| --------------------------- | --------------------------------------------------------- |
| `amount`                    | In smallest currency unit (cents for USD)                 |
| `currency`                  | 3-letter ISO code: `usd`, `eur`, `gbp`                    |
| `customer`                  | Attach to a Stripe Customer (optional but recommended)    |
| `automatic_payment_methods` | Enables all available payment methods automatically       |
| `metadata`                  | Custom key-value data you attach — comes back in webhooks |
| `idempotencyKey`            | Prevents duplicate PaymentIntents on retry                |

---

## 8. Payments Controller

```typescript
// src/payments/payments.controller.ts
import {
  Controller,
  Post,
  Get,
  Delete,
  Body,
  Param,
  UseGuards,
  Req,
} from "@nestjs/common";
import { PaymentsService } from "./payments.service";
import { CreatePaymentIntentDto } from "./dto/create-payment-intent.dto";
import { JwtAuthGuard } from "../auth/jwt-auth.guard"; // your existing auth guard

@Controller("payments")
@UseGuards(JwtAuthGuard) // protect all payment routes
export class PaymentsController {
  constructor(private readonly paymentsService: PaymentsService) {}

  // Step 1: Frontend calls this to get a client_secret
  @Post("create-intent")
  async createPaymentIntent(@Body() dto: CreatePaymentIntentDto, @Req() req) {
    const paymentIntent = await this.paymentsService.createPaymentIntent({
      ...dto,
      customerId: req.user.stripeCustomerId, // pull from authenticated user
    });

    // Only return client_secret to frontend — nothing else
    return { clientSecret: paymentIntent.client_secret };
  }

  // Optional: retrieve status of a payment
  @Get(":id")
  async getPaymentIntent(@Param("id") id: string) {
    const paymentIntent = await this.paymentsService.retrievePaymentIntent(id);
    return {
      status: paymentIntent.status,
      amount: paymentIntent.amount,
      currency: paymentIntent.currency,
    };
  }

  // Optional: cancel a pending payment
  @Delete(":id/cancel")
  async cancelPaymentIntent(@Param("id") id: string) {
    return await this.paymentsService.cancelPaymentIntent(id);
  }
}
```

---

## 9. Payments Module

```typescript
// src/payments/payments.module.ts
import { Module } from "@nestjs/common";
import { PaymentsController } from "./payments.controller";
import { PaymentsService } from "./payments.service";

@Module({
  controllers: [PaymentsController],
  providers: [PaymentsService],
  exports: [PaymentsService],
})
export class PaymentsModule {}
```

---

## 10. What `metadata` Is and Why It Matters

Stripe's `metadata` field lets you attach custom key-value pairs to any Stripe object. This data is returned in webhook events.

```typescript
await this.stripe.paymentIntents.create({
  amount: 2900,
  currency: "usd",
  metadata: {
    userId: "123", // your internal user ID
    productId: "lifetime", // what they bought
    orderId: "order_456", // your internal order ID
  },
});
```

When Stripe sends you a `payment_intent.succeeded` webhook, the `metadata` comes back with it. This is how you know **which user paid for what** — without storing extra state.

> **Rule:** Always put your internal `userId` in metadata. This is the most important link between Stripe and your database.

---

## 11. PaymentIntent Statuses — Full Reference

```
requires_payment_method
        ↓ (card details provided)
requires_confirmation
        ↓ (confirmPayment() called from frontend)
requires_action         ← 3D Secure needed (Stripe.js handles this automatically)
        ↓
processing
        ↓
     succeeded ✅    OR    canceled ❌
```

| Status                    | When it happens              | What to do              |
| ------------------------- | ---------------------------- | ----------------------- |
| `requires_payment_method` | Just created                 | Show payment form       |
| `requires_confirmation`   | Card attached, not confirmed | Call `confirmPayment()` |
| `requires_action`         | 3DS authentication needed    | Stripe.js handles it    |
| `processing`              | Bank is processing           | Show "processing" UI    |
| `succeeded`               | Payment done                 | Update DB (via webhook) |
| `canceled`                | Expired or canceled          | Allow retry             |

---

## 12. 3D Secure (3DS) — What It Is

3D Secure is an extra authentication step (a popup from the user's bank) for high-risk transactions. Examples: "Verified by Visa", "Mastercard SecureCode".

**The good news:** When you use `PaymentElement` + `stripe.confirmPayment()`, **Stripe.js handles 3DS completely automatically**. No extra code needed on your side.

Stripe detects when 3DS is required, shows the authentication popup, and continues the flow. Your `return_url` receives the final result.

---

## 13. Handling Errors Gracefully

```typescript
// In your service — wrap Stripe calls properly
async createPaymentIntent(dto: CreatePaymentIntentDto) {
  try {
    return await this.stripe.paymentIntents.create({ ... });
  } catch (error) {
    if (error instanceof Stripe.errors.StripeCardError) {
      // Card was declined
      throw new BadRequestException(error.message);
    }
    if (error instanceof Stripe.errors.StripeInvalidRequestError) {
      // Invalid parameters sent to Stripe
      throw new BadRequestException('Invalid payment request');
    }
    // Unexpected error
    throw new InternalServerErrorException('Payment processing failed');
  }
}
```

**Stripe error types:**

| Error Type                  | Cause                             |
| --------------------------- | --------------------------------- |
| `StripeCardError`           | Card declined, insufficient funds |
| `StripeInvalidRequestError` | Bad parameters in your API call   |
| `StripeAuthenticationError` | Wrong API key                     |
| `StripeRateLimitError`      | Too many requests                 |
| `StripeConnectionError`     | Network issue with Stripe         |

---

## 14. Testing One-Time Payments

Stripe provides test card numbers that simulate different scenarios:

| Card Number           | Scenario            |
| --------------------- | ------------------- |
| `4242 4242 4242 4242` | Payment succeeds ✅ |
| `4000 0000 0000 0002` | Card declined ❌    |
| `4000 0025 0000 3155` | 3D Secure required  |
| `4000 0000 0000 9995` | Insufficient funds  |

Use any future expiry date, any 3-digit CVC, and any 5-digit ZIP.

---

## 15. Quick Summary

| Concept                       | Key Takeaway                                      |
| ----------------------------- | ------------------------------------------------- |
| **PaymentIntent**             | Core object for one-time payments                 |
| **client_secret**             | Only thing returned to frontend from your backend |
| **metadata**                  | Attach your userId — it comes back in webhooks    |
| **automatic_payment_methods** | Enables Apple Pay, Google Pay automatically       |
| **idempotencyKey**            | Prevents duplicate charges on retry               |
| **3DS**                       | Handled automatically by Stripe.js                |
| **Webhook**                   | The only reliable way to confirm payment success  |

---

_Next → `04-subscriptions.md` — Subscription lifecycle, creating plans, and managing billing in NestJS_

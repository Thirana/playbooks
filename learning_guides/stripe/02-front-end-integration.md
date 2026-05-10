# 02 — Frontend Integration (Stripe.js & Stripe Elements)

---

## 1. Why Can't We Use a Plain HTML `<input>` for Card Details?

This is the first question most developers ask. The answer is **PCI Compliance**.

PCI DSS (Payment Card Industry Data Security Standard) is a set of rules that govern how card data must be handled. If raw card numbers pass through your server, you become responsible for securing them — which requires expensive audits, infrastructure, and certifications.

**Stripe's solution:** Card details never touch your server at all.

```
❌ Wrong flow (PCI nightmare):
User → types card → Your Frontend → Your Server → Stripe

✅ Correct flow:
User → types card → Stripe's secure iframe → Stripe servers
                                                    ↓
                              Your Server ← token/PaymentMethod id only
```

Stripe's frontend library (**Stripe.js**) renders card fields inside a **secure iframe hosted by Stripe**. Your code never sees the actual card number — only a safe token.

---

## 2. Stripe.js — What It Is

**Stripe.js** is Stripe's official JavaScript library for the browser. It:

- Loads the secure iframe for card input
- Handles 3D Secure authentication popups
- Communicates directly with Stripe servers
- Returns safe tokens/PaymentMethod IDs to your code

### Loading Stripe.js

Always load Stripe.js from Stripe's CDN — never self-host it:

```html
<!-- In your HTML -->
<script src="https://js.stripe.com/v3/"></script>
```

Or in a React/framework project, use the official package:

```bash
npm install @stripe/stripe-js
```

```typescript
// React
import { loadStripe } from "@stripe/stripe-js";

const stripePromise = loadStripe("pk_test_your_publishable_key");
```

> ⚠️ Always use your **publishable key** (`pk_test_...`) here — never the secret key.

---

## 3. Stripe Elements — What They Are

**Stripe Elements** are pre-built, customizable UI components (rendered inside Stripe's secure iframes) that collect payment information.

Think of Elements as special `<input>` fields — they look like yours, but they live inside Stripe's world.

### Types of Elements:

| Element             | What it collects                                        |
| ------------------- | ------------------------------------------------------- |
| `CardElement`       | Card number + expiry + CVC in one field                 |
| `CardNumberElement` | Card number only                                        |
| `CardExpiryElement` | Expiry date only                                        |
| `CardCvcElement`    | CVC only                                                |
| `PaymentElement`    | All payment methods (card, Apple Pay, Google Pay, etc.) |

> **Recommendation for SaaS:** Use **`PaymentElement`** — it handles all payment methods automatically and is the modern standard. Stripe calls this the "Payment Element" and it replaces the older Card Element.

---

## 4. The Two Main Frontend Flows

### Flow A — One-Time Payment

```
1. User clicks "Pay"
2. Your Frontend → calls your NestJS backend → creates a PaymentIntent
3. NestJS → returns client_secret to frontend
4. Frontend → uses client_secret to confirm payment via Stripe.js
5. Stripe processes the payment
6. Frontend → redirects to success page OR shows error
```

### Flow B — Subscription (with or without trial)

```
1. User selects a plan and clicks "Subscribe"
2. Your Frontend → calls your NestJS backend → creates a Subscription
3. NestJS → returns client_secret (from the subscription's latest invoice)
4. Frontend → uses client_secret to confirm payment via Stripe.js
5. Stripe activates the subscription
6. Frontend → redirects to dashboard
```

> In both flows, the `client_secret` is the bridge between your backend and the frontend. It tells Stripe.js which payment to confirm.

---

## 5. Setting Up Stripe Elements in React

Here is a full working setup using React + `@stripe/react-stripe-js`:

```bash
npm install @stripe/stripe-js @stripe/react-stripe-js
```

### Step 1 — Wrap your app with `Elements` provider

```tsx
// App.tsx or your payment page wrapper
import { Elements } from "@stripe/react-stripe-js";
import { loadStripe } from "@stripe/stripe-js";

const stripePromise = loadStripe(
  process.env.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY!,
);

export default function PaymentPage({
  clientSecret,
}: {
  clientSecret: string;
}) {
  const options = { clientSecret };

  return (
    <Elements stripe={stripePromise} options={options}>
      <CheckoutForm />
    </Elements>
  );
}
```

> The `clientSecret` comes from your NestJS backend (from a PaymentIntent or Subscription). You fetch it before rendering this component.

---

### Step 2 — Build the Checkout Form

```tsx
// CheckoutForm.tsx
import {
  PaymentElement,
  useStripe,
  useElements,
} from "@stripe/react-stripe-js";
import { useState } from "react";

export default function CheckoutForm() {
  const stripe = useStripe();
  const elements = useElements();
  const [isLoading, setIsLoading] = useState(false);
  const [errorMessage, setErrorMessage] = useState("");

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!stripe || !elements) return; // Stripe.js not loaded yet

    setIsLoading(true);

    const { error } = await stripe.confirmPayment({
      elements,
      confirmParams: {
        return_url: "https://yourapp.com/payment/success", // redirect after payment
      },
    });

    // If we get here, something went wrong (successful payments redirect)
    if (error) {
      setErrorMessage(error.message ?? "An unexpected error occurred");
    }

    setIsLoading(false);
  };

  return (
    <form onSubmit={handleSubmit}>
      <PaymentElement /> {/* Stripe renders the secure card input here */}
      <button type="submit" disabled={!stripe || isLoading}>
        {isLoading ? "Processing..." : "Pay Now"}
      </button>
      {errorMessage && <p>{errorMessage}</p>}
    </form>
  );
}
```

**What `stripe.confirmPayment()` does:**

- Takes the card details from the `PaymentElement`
- Sends them directly to Stripe (never to your server)
- Handles 3D Secure authentication if required
- On success, redirects to `return_url`
- On failure, returns an error

---

## 6. Fetching the `client_secret` from NestJS

Before rendering the payment form, your frontend needs to get the `client_secret` from your NestJS backend:

```tsx
// In your payment page component
useEffect(() => {
  fetch("/payments/create-intent", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ amount: 2900, currency: "usd" }),
  })
    .then((res) => res.json())
    .then((data) => setClientSecret(data.clientSecret));
}, []);
```

```typescript
// NestJS — payments.controller.ts
@Post('create-intent')
async createPaymentIntent(@Body() body: { amount: number; currency: string }) {
  const paymentIntent = await this.paymentsService.createPaymentIntent(
    body.amount,
    body.currency,
  );
  return { clientSecret: paymentIntent.client_secret };
}
```

> **Security note:** Never send the full PaymentIntent object to the frontend — only the `client_secret`. Everything else (amount, currency, metadata) stays on the server.

---

## 7. Handling the Return URL (After Payment)

When Stripe redirects back to your `return_url`, you need to check the payment status:

```tsx
// success.tsx — your return URL page
import { useStripe } from "@stripe/react-stripe-js";
import { useEffect, useState } from "react";

export default function PaymentSuccess() {
  const stripe = useStripe();
  const [status, setStatus] = useState("");

  useEffect(() => {
    if (!stripe) return;

    const clientSecret = new URLSearchParams(window.location.search).get(
      "payment_intent_client_secret",
    );

    stripe.retrievePaymentIntent(clientSecret!).then(({ paymentIntent }) => {
      switch (paymentIntent?.status) {
        case "succeeded":
          setStatus("Payment successful! 🎉");
          break;
        case "processing":
          setStatus("Payment is processing...");
          break;
        case "requires_payment_method":
          setStatus("Payment failed. Please try again.");
          break;
      }
    });
  }, [stripe]);

  return <p>{status}</p>;
}
```

> Stripe appends `payment_intent_client_secret` to the return URL automatically. You use it to retrieve the final payment status.

---

## 8. Customizing the Appearance of Elements

Stripe Elements can be styled to match your app. You pass an `appearance` object to the `Elements` provider:

```tsx
const options = {
  clientSecret,
  appearance: {
    theme: "stripe", // 'stripe' | 'night' | 'flat'
    variables: {
      colorPrimary: "#6366f1", // your brand color
      colorBackground: "#ffffff",
      colorText: "#1f2937",
      borderRadius: "8px",
      fontFamily: "Inter, sans-serif",
    },
  },
};
```

> You can style the **container** with your own CSS, but the actual input fields inside the iframe are controlled only through Stripe's `appearance` API — not direct CSS.

---

## 9. Apple Pay & Google Pay — Automatic with PaymentElement

One major advantage of using `PaymentElement` over the older `CardElement` is that **Apple Pay and Google Pay are automatically supported** — no extra code needed.

Stripe detects the user's browser/device and shows the relevant payment buttons inside the `PaymentElement`. Your code stays the same.

Requirements:

- Must be on **HTTPS** (required by Apple Pay and Google Pay)
- Must register your domain in Stripe Dashboard → **Settings → Payment methods → Apple Pay**

---

## 10. Key Security Rules — Summary

| Rule                                    | Why                                              |
| --------------------------------------- | ------------------------------------------------ |
| Use publishable key on frontend only    | Secret key on frontend = anyone can make charges |
| Never log or store `client_secret`      | It can be used to confirm the payment            |
| Load Stripe.js from Stripe's CDN        | Self-hosting breaks PCI compliance               |
| Always use HTTPS in production          | Required for Apple Pay, Google Pay, and 3DS      |
| Never send raw card data to your server | Defeats the purpose of Stripe Elements           |

---

## 11. Quick Summary

| Concept              | Key Takeaway                                                |
| -------------------- | ----------------------------------------------------------- |
| **Stripe.js**        | Browser library that communicates with Stripe securely      |
| **Stripe Elements**  | Secure iframe-based input fields for card details           |
| **PaymentElement**   | Modern, all-in-one payment field (recommended)              |
| **client_secret**    | Bridge between your backend and frontend to confirm payment |
| **confirmPayment()** | Sends card details to Stripe and handles auth               |
| **return_url**       | Where Stripe redirects after payment attempt                |
| **Appearance API**   | How to style Elements to match your brand                   |

---

_Next → `03-one-time-payments.md` — Full one-time payment flow implemented in NestJS_

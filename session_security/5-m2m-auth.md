# Topic 5 — Machine-to-Machine (M2M) Authentication

> Scope: why the user-auth model from Topics 1–4 doesn't fit service-to-service calls, and what should replace it. We use your actual current setup as a running case study throughout — not as a hypothetical, but because it happens to demonstrate almost every M2M anti-pattern in one place, and fixing it concretely is the real deliverable of this note.

---

## 1. The case study: what's actually happening today

Before any theory, let's lay out your current setup precisely, because every section below refers back to it:

```
                    ┌──────────────┐
 Mobile App ───┐    │  GCP Load     │
 Admin Panel ──┼───►│  Balancer     │───► BE Server
                    └──────────────┘           │
                                                 │ forwards the SAME user JWT
                                                 │ it received from the client
                                    ┌────────────┼────────────┐
                                    ▼                          ▼
                          Notification Svc              Rewards Svc
                       (Cloud Run, PUBLIC/unauth)    (Cloud Run, PUBLIC/unauth)

   All three (BE, Notification, Rewards) share ONE HS256 secret to sign/verify that JWT.

   ⚠ Mobile App can ALSO call Notification/Rewards Cloud Run URLs directly,
     bypassing BE entirely — and those URLs accept unauthenticated requests.
```

Walking through exactly what this means, using vocabulary from the earlier notes:

**1. Forwarding the user's JWT is Topic 1 §6.1's "Shortcut B," happening for real.** Notification and Rewards can't tell "the user called us directly" from "BE called us on the user's behalf" — because as far as they can see, it's literally the same token either way. There's no way to express "BE is acting on behalf of user 41213" as distinct from "user 41213 is calling us" — the two situations are indistinguishable by design.

**2. The shared HS256 secret is Topic 2 §4.4's exact warning, now with three holders instead of one.** HS256 means whoever can *verify* a token can also *sign* one. Right now, that's BE, Notification, *and* Rewards — three separate deployables, three separate attack surfaces, any one of which being compromised gives an attacker the ability to **mint a valid JWT for any user, including an admin**, and have it accepted everywhere. This isn't a theoretical risk specific to your setup — it's the textbook reason RS256 exists (Topic 2 §4.4): a service that only ever needs to *check* a token should never also hold the power to *create* one.

**3. "Public/unauthenticated" Cloud Run + a single app-level JWT check is zero defense in depth.** There is exactly one gate between the open internet and these services: your application code's JWT verification. If that check ever has a bug, or an attacker gets hold of *any* valid token (or, per point 2, forges one), there is **no second layer** — no platform-level barrier — standing in the way. This is why the mobile-bypass leak flagged in Topic 4 §7 is possible at all: those URLs will happily respond to anyone who can construct a request that satisfies the app-level check, with nothing above that check pushing back.

Every fix in this note traces back to closing one of these three gaps. Let's build up the right model properly, then apply it.

---

## 2. Why the user-auth model can't just be reused here

Topic 1 §5.2 flagged this conceptually; here's the concrete version. Everything we built in Topics 2–4 — passwords, MFA, short sessions, refresh tokens, "the user steps away and comes back" — assumes an intermittently-present **human**. A service calling another service has none of the properties that made those mechanisms make sense:

| | Human user | Service (BE calling Notification) |
|---|---|---|
| Can type a password / tap MFA | Yes | No — nobody's watching at 3am |
| Session naturally has "idle" periods | Yes | No — calls happen continuously, automatically |
| Credential should be short-lived and re-proven often | Yes (that's the whole access/refresh design) | Yes, but re-proving must be **fully automated**, no human step possible |
| Identity is "this one person" | Yes | Identity is "this one *deployable*" — every instance of BE is the same principal |

The conclusion isn't "M2M needs weaker auth because it's automated" — if anything it needs to be *more* rigorous, because there's no human in the loop to notice something's wrong. The conclusion is that **the credential and the verification mechanism have to be fully machine-manageable**: no typing, no MFA prompts, and ideally no human ever manually handling the secret at all (which, as we'll see, is exactly what GCP's native option gets you for free).

---

## 3. What we actually need from an M2M scheme

Distilling the case study's three gaps into requirements:

1. **A service proves its own identity — never the identity of a user it's acting for.** "BE is calling" and "user 41213 is calling" must be two different, distinguishable facts.
2. **Verifying a service's credential must never also grant the power to forge one.** (Rules out shared-secret/HS256 for this purpose, same logic as Topic 2 §4.4.)
3. **Credentials should be short-lived and ideally auto-rotated**, so a leaked one has a small blast radius — same principle as access tokens (Topic 2 §5.1), applied to services.
4. **There should be a platform-level gate, independent of your application code**, so a bug in your JWT-checking logic isn't the *only* thing standing between the internet and an internal service.
5. **"Acting on behalf of user X" needs to travel as plain, non-impersonating context** — not by forwarding the user's own credential.

With those five in hand, here are the real options, roughly in order of how much infrastructure they demand.

---

## 4. Option 1 — Static API keys (what you effectively have, misapplied)

### 4.1 The mechanism

A fixed, long-lived secret string is generated once and given to every service that needs to call another. The caller attaches it to every request; the receiver checks it matches.

```http
POST /notifications/send HTTP/1.1
Host: notification-service-xyz.run.app
X-API-Key: sk_live_9f8c7b6a5d4e3f2a1b0c
```

This is, functionally, exactly what your shared HS256 secret is doing today — just wearing a JWT-shaped costume. It has the same problems: it's long-lived (no natural expiry), it's typically all-or-nothing (no per-service scoping — whoever has the key can call *anything* the receiving service exposes), and rotating it means coordinating a simultaneous update across every service that holds it, which in practice tends to mean it never gets rotated at all.

**Where a static key genuinely is the right tool:** a single, narrow, well-scoped purpose — like verifying an inbound webhook from a third party (§8) — where there's no better alternative because you don't control the caller's infrastructure. It's the wrong tool for authenticating your *own* services to each other, because you *do* control that infrastructure, and better options are available for free.

---

## 5. Option 2 — OAuth 2.0 Client Credentials Grant

This is the vendor-neutral, industry-standard answer to "how does one service prove its identity to another," and it's worth knowing properly even though — spoiler — GCP gives you something even less effortful for Cloud Run-to-Cloud Run calls (§6). You'll still want this pattern for anything that isn't GCP-native (a future third-party integration, a partner API).

### 5.1 The flow

Each service gets its own `client_id` / `client_secret` pair (not shared — Notification and Rewards each get their own), registered with a central **token endpoint** (often your own auth service, or a dedicated identity provider).

```
1. BE wants to call Notification. First, it authenticates itself:

   POST /oauth/token
   Content-Type: application/x-www-form-urlencoded

   grant_type=client_credentials
   &client_id=be-service
   &client_secret=***
   &scope=notification:send
```

```json
// Response — a short-lived, SCOPED access token, just for this service
{
  "access_token": "eyJhbGciOiJSUzI1NiIs...",
  "token_type": "Bearer",
  "expires_in": 300,
  "scope": "notification:send"
}
```

```
2. BE calls Notification, presenting that token:

   POST /notifications/send
   Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
```

Notification verifies the token exactly like an access token in Topic 2 (signature + expiry), but the claims describe a **service**, not a user:

```json
{
  "sub": "be-service",
  "scope": "notification:send",
  "iat": 1751536400,
  "exp": 1751536700
}
```

### 5.2 Why this already fixes two of the three gaps

- **`sub: "be-service"`** is unambiguously a service identity — nothing here could be confused with a user token (gap 1).
- **`scope: "notification:send"`** means BE's service credential can be limited to exactly what BE needs to call — Notification could reject a token scoped only for, say, `notification:read_status` if it's presented against the `send` endpoint. Compare this to your current setup, where possessing the shared secret means being able to do *anything* any of the three services can do.
- Tokens are short-lived (300s above) — a leaked one expires fast, same logic as Topic 2 §5.1.

This still requires you to run a token endpoint and manage `client_id`/`client_secret` pairs per service — real, but modest, infrastructure. Section 6 shows how GCP gives you an equivalent (arguably stronger) result with **zero secrets for you to manage at all**, since you're already all-in on Cloud Run.

---

## 6. Option 3 — mTLS (mentioned for completeness)

Instead of a bearer token, each service holds a TLS client certificate, and *both* sides authenticate each other during the TLS handshake itself (recall Topic 1's certificate chain — this is that same mechanism, but now the *client* also presents a cert, not just the server). This is strong — identity is proven at the transport layer before a single byte of application data moves — and it's the backbone of tools like Istio/Linkerd service meshes.

For a 3–4 service system, running your own certificate issuance/rotation infrastructure (or standing up a service mesh) to get mTLS is a genuinely heavy lift relative to the problem size — this is the kind of thing that becomes worth it once you have dozens of services and a dedicated platform team. Worth knowing it exists and why it's strong; not the recommendation for `mo-marketplace` today, especially given GCP already gives you an equivalent property for less operational cost — which brings us to the actual recommendation.

---

## 7. Option 4 (recommended) — GCP-native: Service Accounts + Cloud Run IAM Invoker

Since every one of your services already runs on Cloud Run, GCP gives you an M2M scheme that satisfies all five requirements from §3 **without you managing a single shared secret** — no client_secret to rotate, no HS256 key to leak, nothing.

### 7.1 The mechanism

Every Cloud Run service already runs *as* a specific GCP service account (yours can be dedicated per service: `be-service@mo-marketplace.iam.gserviceaccount.com`, `notification-service@...`, etc.). When one Cloud Run service calls another, it can request a **Google-signed OIDC identity token**, scoped to the exact target URL, directly from the metadata server — no secret ever touches your code:

```typescript
// be-server calling notification-service
import { GoogleAuth } from 'google-auth-library';

const auth = new GoogleAuth();
const targetUrl = 'https://notification-service-xyz-uc.a.run.app';

async function notifyOrderConfirmed(userId: string) {
  const client = await auth.getIdTokenClient(targetUrl);   // fetches a fresh, short-lived
                                                             // Google-signed token automatically
  const res = await client.request({
    url: `${targetUrl}/notifications/send`,
    method: 'POST',
    data: { userId, template: 'order_confirmed' },
  });
  return res.data;
}
```

That call transparently attaches a header like:

```http
Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6...   ← signed by GOOGLE, not by you
```

### 7.2 Turning on the platform-level gate (this is the fix for the mobile bypass)

Right now Notification/Rewards allow unauthenticated invocations — the gap from §1, point 3. Two commands close it:

```bash
# 1. Require authentication at the platform level (removes the public/unauthenticated flag)
gcloud run services update notification-service --no-allow-unauthenticated

# 2. Explicitly grant ONLY be-service's service account permission to invoke it
gcloud run services add-iam-policy-binding notification-service \
  --member="serviceAccount:be-service@mo-marketplace.iam.gserviceaccount.com" \
  --role="roles/run.invoker"
```

Here's why this is a materially stronger fix than "add a better check in your app code": **Cloud Run itself validates the identity token before your application code ever runs.** If the Mobile App tries to hit `notification-service-xyz.run.app` directly — no valid Google-signed identity token for an authorized invoker — the platform returns `403` immediately. Your Node.js process, your JWT-verification logic, your business logic: none of it even executes. This is requirement 4 from §3 (a platform-level gate independent of your app code) satisfied directly, and it's the concrete, closeable fix for the exact leak flagged back in Topic 4 §7.

```
                    ┌───────────────────────────────────┐
Mobile App ────X──► │  Cloud Run platform IAM check       │   ← rejected HERE, before
(no valid            │  "is caller be-service@...? "        │      your code runs at all
 identity token)      │   NO → 403, request never reaches    │
                     │   your Node.js process               │
                     └───────────────────────────────────┘

BE Server ─────────► │  same gate, but BE HAS a valid,     │──► your app code runs
(valid Google-signed  │  Google-signed identity token        │
 identity token)      │  → ALLOWED through                    │
                     └───────────────────────────────────┘
```

### 7.3 Why this also fixes the shared-secret problem

Google signs these tokens with keys **you never see and never manage** — there's no shared secret sitting in three services' environment variables anymore. Verification (which Cloud Run does automatically when "require authentication" is on) is done against **Google's own public keys**, published and rotated by Google. Nothing your BE, Notification, or Rewards services hold has the power to *forge* a token — the private signing key never leaves Google's infrastructure. This directly resolves gap 2 from §1 — no service, however compromised, can mint a token as another service.

### 7.4 Solving "acting on behalf of user X" — without impersonation

This is the piece that fixes gap 1 (forwarding the raw user JWT). Once the *channel itself* is authenticated (Notification now knows, with certainty, "this request really is BE, because Cloud Run's platform-level IAM check already proved it"), you don't need to re-prove identity a second time inside the payload — you just need to pass **plain contextual data**, because the transport already guarantees who's sending it:

```json
POST /notifications/send
Authorization: Bearer <Google-signed identity token proving "this is be-service">

{
  "onBehalfOfUserId": "41213",
  "userRoles": ["buyer"],
  "template": "order_confirmed"
}
```

Notice `onBehalfOfUserId` here is just a **data field**, not a forwarded credential — Notification isn't being asked to trust "this is a valid user session," it's being told "the already-authenticated caller (BE) is telling you this event concerns user 41213," which is a fact BE is entitled to assert because BE already did the real RBAC check (Topic 4) before ever making this call. This is the general fix for Topic 1 §6.1's Shortcut B: **separate "who is calling" (proven cryptographically, once, at the transport layer) from "who this action concerns" (just data, since the caller is already trusted).**

---

## 8. A related but different case: inbound webhooks (e.g. PayHere)

Worth distinguishing clearly, since it looks similar but is a genuinely different situation: PayHere calling *your* system (a payment webhook) is M2M too, but you don't control PayHere's infrastructure, so GCP-native identity tokens aren't an option — you can't ask a third party to authenticate as one of your GCP service accounts. This is the legitimate, narrow case where a **static shared secret is the right and standard tool** (§4) — specifically, verifying a signature PayHere computes over the payload:

```
Webhook payload arrives + a signature header, e.g.:
X-PayHere-Signature: 8f3c1a...

Your code recomputes:
  expected = HMAC_SHA256(raw_payload_bytes, shared_webhook_secret)

if expected !== received_signature: reject (403)
```

The differences that make this an appropriate use of a static secret, unlike your BE/Notification/Rewards case: it's **single-purpose** (this secret does nothing but verify webhook payloads — it can't be used to call any other endpoint or mint any other kind of token), it's **scoped to one external relationship** (rotatable independently without touching your internal service auth), and there genuinely is no alternative since you don't control PayHere's signing infrastructure. This is the same static-egress-IP-plus-webhook-verification pattern you already built out for PayHere — this note just gives you the vocabulary for *why* that's the correct shape for this particular relationship, while a shared secret across your *own* services is not.

---

## 9. Applying this to CloudAMQP (RabbitMQ)

Your BE→RabbitMQ→Notification/Rewards path is a different shape (async, no direct request/response), but the same least-privilege principle applies. Managed RabbitMQ (CloudAMQP) authenticates connections via username/password over TLS per-connection — the concrete recommendation:

- **Separate credentials per service role**, not one shared username for everything: a publisher credential for BE (permission: `write` only on the relevant exchange), separate consumer credentials for Notification and Rewards (permission: `read` only on their specific queues). CloudAMQP supports per-vhost/per-user permission scoping natively — this is a configuration change, not new infrastructure.
- This means a compromised Notification service (which only ever needs to *consume*) never held *publish* rights in the first place — it structurally can't inject fake events into the queue, even if fully compromised. That's requirement 2 from §3 (verifying ≠ forging power), applied to the queue instead of a token.

---

## 10. Concrete remediation checklist for `mo-marketplace`

Pulling every fix from this note into one list — this is essentially ready to drop into your proposal as the M2M section's action items:

1. **Stop forwarding the user's raw JWT** from BE to Notification/Rewards. Replace with: BE calls using its own Google-signed identity token (§7.1), and passes `onBehalfOfUserId`/`userRoles` as plain request data (§7.4).
2. **Stop sharing one HS256 secret across BE, Notification, and Rewards.** That secret should only ever have existed for verifying *user* tokens, and per Topic 2 §4.4, user-token verification should move to RS256 anyway (auth service holds the private key; every service gets only the public key) — but with fix #1, Notification/Rewards likely won't need to verify user tokens at all anymore, since they'll trust BE's already-authenticated context instead.
3. **Turn off "allow unauthenticated invocations"** on both Notification and Rewards Cloud Run services; grant `roles/run.invoker` only to BE's specific service account (§7.2). This is the direct, platform-level fix for the mobile-bypass leak.
4. **Give BE, Notification, and Rewards their own distinct GCP service accounts** (if they don't already have one each) rather than sharing one — this is what makes the IAM invoker binding in #3 meaningful and auditable ("who, specifically, can call Notification" should have exactly one answer).
5. **Split CloudAMQP credentials by role** — BE gets publish-only, Notification/Rewards get consume-only on their respective queues (§9).
6. **Leave the PayHere webhook HMAC verification as-is** — it's already the correct pattern for that specific external relationship (§8); this note just explains why it's different from #1–2.

---

## 11. Summary

| Term | One-line definition |
|---|---|
| **Client Credentials Grant** | OAuth2 flow where a service authenticates with its own `client_id`/`secret` to get a short-lived, scoped access token |
| **mTLS** | Both sides of a TLS connection present certificates, authenticating each other at the transport layer |
| **Cloud Run identity token** | A short-lived, Google-signed OIDC token proving "this call comes from this specific Cloud Run service account" |
| **IAM invoker binding** | The GCP-level allowlist of exactly which identities may invoke a given Cloud Run service — enforced before your code runs |
| **On-behalf-of context** | Plain data (not a forwarded credential) asserting who/what an already-authenticated service's action concerns |

```
BEFORE (today):
  Mobile ──user JWT──► BE ──same user JWT──► Notification/Rewards (public, shared secret)
                                                  ▲
                                    Mobile ───────┘ (bypasses BE entirely — same JWT works)

AFTER (this note's recommendation):
  Mobile ──user JWT──► BE ──Google-signed identity token + on-behalf-of data──► Notification/Rewards
                            (IAM invoker restricted to BE's service account — Mobile's direct
                             calls now rejected by the PLATFORM, before any app code runs)
```

**Where we go next (Topic 6):** with both user-facing auth (Topics 1–4) and service-to-service auth (this note) properly modeled, Topic 6 zooms out to the architecture level — where identity/context should be enforced across your whole system (gateway-style vs. per-service), how identity propagates cleanly across multiple hops (not just BE→one-service, but chains), and applying Zero Trust principles to your internal traffic generally, tying together everything from Topics 1–5 into one coherent picture you can put in front of stakeholders.
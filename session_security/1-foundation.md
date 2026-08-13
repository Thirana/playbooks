# Topic 1 — Foundations: Identity, Authentication & Authorization

> Scope for this note: what "identity" means for a system, what authentication actually proves, what authorization actually decides, the different *kinds* of principals you'll deal with in `mo-marketplace` (users, services, devices), and why microservices break the assumptions that authentication alone used to satisfy.
>
> Everything after this topic (JWTs, RBAC, M2M, gateway patterns) is built on the vocabulary defined here — so this note is intentionally precise about definitions, even where they sound obvious.

---

## 1. The problem before any of this exists

Take away every login page, every token, every `@Roles()` decorator. Strip a system down to its rawest form: a client sends a request, a server does something in response.

```
Client  ---- HTTP request --->  Server
Client  <--- HTTP response ---  Server
```

At this raw level, the server has **no idea who sent the request**. It's just bytes over a socket. Before the server can decide anything — show this user their orders, let this admin delete a listing, let this internal service write to the payments table — it has to answer two completely different questions, in a strict order:

1. **"Who (or what) is on the other end of this connection?"**
2. **"Is that party allowed to do the specific thing they're asking for?"**

Question 1 is **Authentication (AuthN)**. Question 2 is **Authorization (AuthZ)**. They get merged into "auth" casually in conversation, but they are separate systems, solving separate problems, and — this matters a lot for your redesign — **they can fail independently**. A request can be perfectly authenticated (we know exactly who you are) and still be correctly rejected (you're not allowed to do that). Keeping these two concerns cleanly separated in your architecture is one of the biggest structural decisions you'll make.

---

## 2. Identity — the thing that exists *before* authentication

Before you can authenticate someone, there has to be something to authenticate *as*. This is **identity**.

An **identity** is a durable, addressable record that says "this entity exists in our system, and here's how we refer to it." It's not a proof of anything by itself — it's just a row that a proof can be checked against.

In your marketplace, examples of identities:

- A buyer with `user_id = 41213`
- A seller with `user_id = 88820`
- The `mo-notification-service` itself, as a *service identity*
- A GCP service account like `notification-sa@mo-marketplace.iam.gserviceaccount.com`
- A physical device (less relevant for you today, more relevant if you ever ship a mobile app with device-bound sessions)

The entity that holds an identity and is making a request is called a **principal**. This word matters — you'll see it constantly in IAM, OAuth, and security literature. A principal is "the thing being authenticated and authorized," regardless of whether it's a human, a script, or a service.

```
Identity  = the record ("user #41213 exists, email is x@y.com, status active")
Principal = the identity when it's actively making a request right now
Credential = the secret/proof used to authenticate as that identity (password, private key, token)
```

**Why separate identity from credential?** Because credentials rotate, expire, get compromised, and get replaced — but identity should stay stable. If user #41213 changes their password, resets their MFA device, or gets a new refresh token, they are still user #41213. This separation is *exactly* why token systems are designed the way they are (more in Topic 2) — the token is a disposable credential; the `user_id`/`sub` claim inside it is the durable identity.

---

## 3. Authentication — proving a claimed identity

Authentication is the act of a principal **proving** it is the identity it claims to be.

```
Client:  "I am user_id 41213"
Server:  "Prove it."
Client:  <presents a credential — password, valid token, signed certificate...>
Server:  <verifies the credential against something it trusts>
Server:  "Confirmed. You are, in fact, 41213."
```

That verification step is the whole game. The server must check the credential against **something it already trusts** — a stored password hash, a signing key, a trusted certificate authority. This is the same "bootstrapping trust" problem from your TLS note (a signature only means something if you already trust the signer's key) — authentication is that exact same problem, just applied to *people and services* instead of *servers*.

### 3.1 Authentication factors

Credentials are grouped into three factor categories:

| Factor | Examples | Property |
|---|---|---|
| **Something you know** | Password, PIN | Can be phished, guessed, leaked in breaches |
| **Something you have** | Phone (OTP/push), hardware key, private key on disk | Can be stolen/lost, but not guessed |
| **Something you are** | Fingerprint, face | Can't be reset if compromised |

**Multi-Factor Authentication (MFA)** requires two different *categories* — not two of the same category (two passwords isn't MFA). MFA is a user-facing concern; you likely won't build this for M2M auth (services can't "possess a phone"), but it matters for your admin/seller login flows later.

### 3.2 What "authenticated" actually produces

Authentication doesn't just return `true`/`false`. On success, it produces an **authenticated context** — a small trusted bundle of facts the rest of the system can rely on for the duration of that request:

```json
{
  "sub": "41213",
  "type": "user",
  "authenticated_at": "2026-07-03T09:12:04Z",
  "auth_method": "password+mfa"
}
```

This bundle is what authorization will read from next. Notice: **no roles, no permissions in here.** Authentication answers "who," full stop. It should not be answering "what can they do" — that's a completely separate lookup, and conflating the two is one of the most common design mistakes in home-grown auth systems (and, based on what you described about the current `mo-marketplace` setup, likely part of what's gone wrong there).

**Gap this exposes:** knowing *who* someone is tells you nothing about what they're *allowed to do*. A confirmed identity is necessary but not sufficient to make any access decision.

---

## 4. Authorization — deciding what an authenticated principal may do

Authorization takes the authenticated context from step 3 and answers a *specific, per-action* question:

> "Can principal `41213` perform action `DELETE` on resource `listing:9981`?"

This is fundamentally a **policy evaluation**, not an identity check. The inputs are:

- **Who** — the authenticated principal (from AuthN)
- **What** — the action being attempted (`read`, `write`, `delete`, `refund`, ...)
- **On what** — the resource/object being acted on
- **Under what conditions** — time of day, ownership, resource state, etc. (this becomes relevant once we cover ABAC/ReBAC in Topic 3)

```
                 ┌───────────────────────┐
Request  ──────► │  Is this a listing     │
"delete          │  owned by user 41213,  │ ──► ALLOW / DENY
listing 9981"    │  or is 41213 an admin?"│
                 └───────────────────────┘
                     (authorization policy)
```

A critical property: **authorization decisions must be re-evaluated on every single request.** Unlike authentication (which can be "remembered" for the life of a session/token), authorization can legitimately change *between two requests made one second apart* — a role gets revoked, a listing gets sold, an account gets suspended. If your system caches an authorization decision instead of the *data authorization depends on*, you get stale-permission bugs — a known real-world failure class (revoked admins who can still act for minutes/hours after revocation because the "you're an admin" fact got baked into a long-lived token or cache).

**Gap this exposes:** once you have both AuthN and AuthZ, you now need a durable, queryable model of "who can do what" — a data model, not just a checkpoint. That's RBAC/ABAC territory (Topic 3). Before we get there, we need to deal with a fact that's specific to your redesign: **not all principals are people.**

---

## 5. Principals aren't all the same shape

This is the part of "foundations" that's most directly relevant to why your current system is in trouble. There are (at least) three distinct principal types in `mo-marketplace`, and each needs its **own** identity + authentication model — not one model stretched to cover all three.

### 5.1 Human users (buyers, sellers, admins)

- Long-lived identity (a row in your `users` table), but the *human* is not always present — they log in, walk away, come back.
- Needs a credential lifecycle that assumes the human is intermittently connected: login, session, refresh, logout, password reset, MFA.
- Authorization is typically **role + ownership** based ("is this seller's own listing").
- The credential (password) is inherently weak and phishable — this is *why* token systems, MFA, and short-lived sessions exist for this principal type.

### 5.2 Machine / service principals (e.g. `mo-notification-service` calling `mo-payment-service`)

- The "identity" is the *service itself*, not a person operating it. There's no human at the keyboard to type a password or tap an MFA prompt.
- The principal is always "present" in the sense that the code runs continuously — but each individual call still needs proof, because network-level trust ("it came from inside our VPC") is not identity proof (this is exactly the origin-locking lesson from your TLS note — knowing *where* a request came from is not the same as knowing *what* it is).
- Authentication must be fully automatable: no human can type anything at 3am when `mo-notification-service` restarts and needs to call `mo-payment-service`. This is why M2M auth (Topic 5) uses things like signed short-lived tokens, mTLS, or cloud-native identity (GCP service accounts / Workload Identity) instead of anything password-shaped.
- Authorization tends to be coarser and more static ("this service may call these three endpoints") rather than per-resource-ownership.

### 5.3 Devices (mentioned for completeness — lower priority for you right now)

- A device (a specific phone, a specific browser instance) can itself be a principal distinct from the user operating it — this is how "log out of all other devices" or "trust this device" features work.
- Not your immediate concern for this project, but worth knowing it exists as a category so you don't accidentally conflate "user" and "session/device" when designing your token claims later.

### Why this distinction matters for your redesign specifically

You described the current problem as: bad AuthN/AuthZ/RBAC *and* bad M2M. That's not a coincidence — it's very common for a system to bolt "service calls" onto the *user* auth system because it's the only auth system that exists yet (e.g., giving a service a long-lived static "private key" that behaves like a permanent password, which you already found in the frontend — sending a long-lived key directly instead of a short-lived proof). The fix isn't "make the user auth stronger" — it's **recognizing service-to-service calls as a structurally different authentication problem** with its own model, which is exactly what Topic 5 (M2M) will build out.

```
                     ┌─────────────────────────────┐
                     │        Principal types        │
                     ├───────────────┬───────────────┤
                     │  Human user   │ Service (M2M)  │
   Credential shape  │  password/MFA │ signed token / │
                     │  → session    │ mTLS cert /    │
                     │               │ IAM identity   │
   Lifetime          │  minutes–hrs  │ seconds–mins   │
                     │  (short-lived)│ (very short)   │
   Present?           intermittent    always-on code
   Authz shape        role+ownership  scope/allow-list
```

---

## 6. Trust boundaries — why a monolith's assumptions break in microservices

In a monolith, authentication typically happens **once**, at the edge (the login endpoint), and everything downstream — every function call inside the same process — implicitly trusts that the request is legitimate, because it's all one process, one memory space, one deploy.

```
        MONOLITH
┌───────────────────────────────┐
│  [Auth check] → Orders module │
│              → Payments module│
│              → Listings module│
└───────────────────────────────┘
   one process, implicit trust after the edge check
```

The moment you split into microservices, that implicit trust silently disappears — but it's easy to *not notice* it disappeared, because the services still "feel" like they're part of the same system. Each service now runs as its **own process, on its own compute, potentially reachable independently** of the "front door." The authentication that happened at the edge (say, in an API Gateway or the frontend-facing service) does not automatically travel with the request unless you deliberately design it to.

```
        MICROSERVICES
┌────────────┐      ┌──────────────┐      ┌───────────────┐
│  Frontend  │ ───► │ mo-notif-svc │ ───► │ mo-payment-svc│
│  (auth'd)  │      │  (trusts?)   │      │  (trusts?)     │
└────────────┘      └──────────────┘      └───────────────┘
     Each arrow is a NEW trust boundary that needs its own decision.
```

Every arrow in that diagram is a **trust boundary** — a point where a request crosses from one security domain into another, and the receiving side must independently decide whether to trust it. This is precisely the vulnerability class you already found: `mo-payment-service` (or whichever service) receiving a long-lived private key straight from the *browser* means the trust boundary between "internet" and "internal service" was effectively erased — the service was trusting a credential that should never have crossed that boundary at all, and worse, that credential doesn't expire.

### 6.1 Two flawed shortcuts, and why they fail

**Shortcut A — "It's on our internal network / VPC, so it's trusted."**
Network location is not identity. Anyone who compromises *any* service, or gets a foothold inside the VPC, can now call every other service with zero additional proof. This is exactly the "hiding the origin IP doesn't stop someone who already has it" lesson from your TLS note, just one layer up the stack. Internal ≠ trusted.

**Shortcut B — "Pass the user's original token along to every downstream service."**
Sounds convenient — `mo-notif-svc` just forwards the user's JWT to `mo-payment-svc`. Problems:
- `mo-payment-svc` can no longer distinguish "the user called me directly" from "another service called me on the user's behalf" — this matters a lot when the two should have different permissions.
- If `mo-notif-svc` is compromised, the attacker now has a legitimate user token to replay anywhere it's accepted.
- The user's token was scoped/signed for *user-facing* auth, not service-to-service auth — reusing it blurs two principal types that should be modeled separately (§5).

The correct pattern (previewed here, built out fully in Topic 6) is that **each hop across a trust boundary gets its own explicit authentication act** — the calling service proves *its own* identity, and, when relevant, separately asserts "and I'm acting on behalf of user X" as a *claim*, not by literally forwarding the user's raw credential.

### 6.2 Zero Trust, in one sentence

The industry term for "never grant trust based on network location or a prior hop — always verify at every boundary" is **Zero Trust**. You don't need the full Zero Trust architecture playbook for a 3–4 service system, but the *principle* — verify identity at every trust boundary, not just the outermost one — is exactly the mental model your redesign needs, and it will come up again explicitly in Topic 6 and Topic 9.

---

## 7. Putting it together — the full request lifecycle, conceptually

```
1. Client sends request with a credential
        │
        ▼
2. AUTHENTICATION
   "Who is this, really?"
   → verify credential against trusted source
   → produce authenticated context (sub, type, method)
        │
        ▼
3. AUTHORIZATION
   "Is THIS principal allowed to do THIS action
    on THIS resource, right now?"
   → evaluate policy against current data
   → ALLOW or DENY
        │
        ▼
4. If ALLOW → business logic executes
   If DENY  → reject (401 vs 403 — see note below)
```

**A detail worth internalizing now, because it trips people up constantly:** the difference between HTTP `401 Unauthorized` and `403 Forbidden` maps *exactly* onto AuthN vs AuthZ:

| Status | Means | Which stage failed |
|---|---|---|
| `401 Unauthorized` | "I don't know who you are" (missing/invalid/expired credential) | **Authentication** failed |
| `403 Forbidden` | "I know exactly who you are, and the answer is no" | **Authorization** failed |

(`401` is a genuinely confusing name — historically it should have been called "Unauthenticated." Keep the table above as the mental reference.) Getting this distinction right in your API responses isn't cosmetic — it's part of the audit trail (Topic 9), and it's a strong signal in your monitoring for whether you're seeing credential-stuffing attempts (lots of 401s) vs privilege-escalation attempts (lots of 403s from otherwise-valid sessions).

---

## 8. Summary — the vocabulary this whole project is built on

| Term | One-line definition |
|---|---|
| **Identity** | A durable record that an entity exists in the system |
| **Principal** | An identity actively making a request right now |
| **Credential** | Disposable proof used to authenticate as an identity |
| **Authentication (AuthN)** | Proving a principal is who/what it claims to be |
| **Authorization (AuthZ)** | Deciding if an authenticated principal may perform a specific action |
| **Trust boundary** | Any point where a request crosses into a new security domain and must be independently verified |
| **Zero Trust** | Principle: verify at every boundary, never trust by network location or a prior hop alone |

**Where we go next (Topic 2):** now that AuthN is precisely defined, we build out *how* it's actually implemented for human users at scale — sessions vs tokens, JWT internals, access/refresh token mechanics, rotation, storage, and revocation. That's the layer where your prior experience already gives you a head start, and where we'll also directly address the specific frontend vulnerability you found (long-lived private key sent by the browser instead of a short-lived proof) as a concrete case study of what happens when Topic 1's boundaries aren't respected.
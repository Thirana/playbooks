# Topic 2 — Authentication Deep Dive: Sessions, Tokens, and the JWT Machinery

> Scope: how authentication is actually *implemented* once a user has proven who they are once (login). We build up from "how does the server remember you across requests" through session cookies, into token-based auth, into JWT internals, into the access/refresh token pair, rotation and theft detection, storage tradeoffs, and finally revocation — the one problem token-based auth never fully solves cleanly.
>
> This is the layer where your prior access/refresh + RBAC experience already gives you a head start. We're going deep enough that the *why* behind each design decision is airtight, because you'll need to defend these choices in your proposal.

---

## 1. The problem: HTTP forgets you instantly

HTTP is stateless by design. Every request is a fresh, isolated event — the server has no built-in memory that "the person who just logged in" is the same person making the next request three seconds later.

```
Request 1: POST /login  {email, password}   →  200 OK  (who are you? we just checked)
Request 2: GET  /orders                      →  ??? (HTTP has already forgotten)
```

So immediately after solving "how do we authenticate once," we hit a *new* problem: **how does the server recognize the same authenticated principal on every subsequent request, without re-running the full login check (password + MFA) every single time?** That's the actual subject of this whole note. Two families of answers exist: **sessions** and **tokens**.

---

## 2. Family 1 — Session-based authentication

### 2.1 The mechanism

On successful login, the server creates a record of "who is authenticated" and stores it **server-side**, keyed by a random, unguessable ID. That ID — the **session ID** — is handed to the client as a cookie. On every future request, the browser automatically re-sends the cookie, and the server looks the session ID up in its store.

```
Login:
Client ──POST /login {email,pw}──► Server
                                     │ verify credentials
                                     │ create session row: {sid: "a1b2c3...", user_id: 41213, expires: ...}
                                     │ store in Redis/DB
Client ◄── Set-Cookie: sid=a1b2c3...──┘

Next request:
Client ──GET /orders  Cookie: sid=a1b2c3...──► Server
                                     │ look up sid in session store
                                     │ found → user_id 41213, still valid
                                     └── serve /orders for user 41213
```

```
┌─────────────────────────┐
│      session_store        (e.g. Redis)
├──────────┬───────────────┤
│ sid       │ a1b2c3...     │
│ user_id   │ 41213         │
│ created_at│ ...           │
│ expires_at│ ...           │
│ ip / ua   │ ...           │
└──────────┴───────────────┘
```

The session ID itself carries **no information** — it's just an opaque lookup key. All the actual truth ("is this session still valid, who does it belong to") lives server-side, which is the defining property of this whole family.

### 2.2 What this buys you — and what it costs

**Strength:** Revocation is trivial and instant. Delete the row from the session store, and that session is dead everywhere, immediately — no waiting for anything to expire. This single property is *the* reason sessions never fully went away even after token-based auth became dominant.

**Cost — the gap that matters for you specifically:** every single request now requires a lookup against a **shared, centralized store**. In a monolith with one database, that's a non-issue. In a microservices system, this becomes a real architectural tax:

```
        Every service, every request:
┌────────────┐        ┌──────────────┐
│ mo-notif-svc│──────►│ session store│◄──────┐
└────────────┘        │  (shared)     │       │
                       └──────────────┘   ┌────────────┐
                              ▲            │mo-payment  │
                              └────────────│  -svc       │
                                           └────────────┘
```

Every service needs network access to the same session store, on every request, adding latency and a single shared dependency that all services now rely on. It also doesn't naturally extend to **service-to-service calls at all** — there's no "browser" holding a cookie when `mo-notification-service` calls `mo-payment-service`. Sessions solve the human-browser case well; they don't solve the M2M case, and they add a hard coupling between every service and one shared store.

**This is the gap that motivates the next idea.**

---

## 3. Family 2 — Token-based authentication

### 3.1 The core idea

Instead of the server remembering "who's logged in" in a central store, what if the **proof of identity travels *with* the request itself**, in a form the server can verify **without a database lookup**? That's a token — specifically, a **self-contained, cryptographically signed** piece of data.

```
Login:
Client ──POST /login {email,pw}──► Server
                                     │ verify credentials
                                     │ build a signed token containing
                                     │   {sub: 41213, exp: ...}
                                     │ sign it with a secret/private key
Client ◄── { "token": "eyJhbGciOi..." } ─┘

Next request:
Client ──GET /orders  Authorization: Bearer eyJhbGci...──► Server
                                     │ verify the SIGNATURE only
                                     │ (no DB lookup needed)
                                     │ trust the claims inside if valid
                                     └── serve /orders for user 41213
```

The critical shift: verification is now **cryptographic, not a lookup.** Any service holding the right public key (or shared secret) can independently verify the token *without calling anywhere else* — which is exactly what solves the microservices coupling problem from §2.2. This is why token-based auth became the default for distributed/microservices systems.

**The dominant format for this is the JWT (JSON Web Token)**, which we now open up completely.

---

## 4. JWT internals

A JWT is three base64url-encoded segments, separated by dots:

```
eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MTIxMyIsInJvbGUiOiJzZWxsZXIiLCJpYXQiOjE3NTE1MzY0MDAsImV4cCI6MTc1MTUzNzMwMH0.h3nD...signature...
   └───────── HEADER ─────────┘ └──────────────── PAYLOAD ─────────────────┘ └── SIGNATURE ──┘
```

### 4.1 Header — how it's signed

```json
{
  "alg": "RS256",
  "typ": "JWT"
}
```

`alg` tells the verifier which algorithm to use to check the signature. This field being attacker-controlled input is the source of a real, historical vulnerability class (§4.5) — keep that in the back of your mind.

### 4.2 Payload — the claims

```json
{
  "sub": "41213",
  "role": "seller",
  "iat": 1751536400,
  "exp": 1751537300,
  "iss": "https://auth.mo.lk",
  "aud": "mo-marketplace-api"
}
```

| Claim | Meaning | Standard? |
|---|---|---|
| `sub` | Subject — the principal's identity (your `user_id`) | Registered (standard) |
| `iat` | Issued-at timestamp | Registered |
| `exp` | Expiry timestamp — token invalid after this | Registered |
| `iss` | Issuer — who created/signed this token | Registered |
| `aud` | Audience — who this token is intended for | Registered |
| `role`, `type`, etc. | Anything app-specific | **Custom/private claims** |

**Important and easy to get wrong:** the payload is **base64-encoded, not encrypted.** Anyone who intercepts a JWT can decode and read every claim in plain text with zero secrets. Base64 is an encoding, not a cipher — it provides zero confidentiality.

```bash
echo "eyJzdWIiOiI0MTIxMyIsInJvbGUiOiJzZWxsZXIifQ" | base64 -d
# {"sub":"41213","role":"seller"}
```

This means: **never put sensitive data in a JWT payload** (no passwords, no PII beyond what's necessary, no internal secrets). The signature guarantees *integrity/authenticity* ("this wasn't tampered with, and it came from whoever holds the signing key") — it says nothing about *confidentiality*.

### 4.3 Signature — the part that makes it trustworthy

This is the direct continuation of your TLS note's HMAC/signature chain, applied here:

```
signature = Sign( base64(header) + "." + base64(payload),  signing_key )
```

Verification:

```
recomputed_signature = Sign( received_header + "." + received_payload,  verification_key )
if recomputed_signature == received_signature:  VALID
else:  REJECT — tampered or forged
```

### 4.4 Signing algorithm choice — HS256 vs RS256/ES256

This choice matters *specifically* because you're building a microservices system, so it's worth slowing down on.

**HS256 (HMAC + SHA-256) — symmetric:**

```
One shared secret. Whoever can VERIFY can also SIGN (same key does both).
```

```
┌──────────────┐          shared secret            ┌──────────────┐
│  Auth service │ ───────────────────────────────► │ mo-payment-svc│
│  (signs)      │        (must be distributed        │  (verifies)   │
└──────────────┘         to every verifier)         └──────────────┘
```

Problem for a multi-service system: **every service that needs to verify tokens must also possess the secret that can create them.** If any one of your 3–4 services is compromised, the attacker can now *mint valid tokens for any user*, not just read tokens. This directly violates the least-privilege principle — a service that only ever needs to *check* "is this token valid" shouldn't also hold the power to *forge* tokens.

**RS256/ES256 (RSA/ECDSA) — asymmetric:**

```
Private key signs (held ONLY by the auth service).
Public key verifies (freely distributed to every service).
```

```
┌──────────────┐   private key    ┌───────────────────────────────┐
│  Auth service │ ───signs────►   │  token: eyJhbG...              │
└──────────────┘                  └───────────────────────────────┘
                                          │  (public key, safe to share widely)
                    ┌─────────────────────┼─────────────────────┐
                    ▼                     ▼                     ▼
            mo-notif-svc          mo-payment-svc          mo-catalog-svc
            (verify only)         (verify only)            (verify only)
```

This is exactly the asymmetric-crypto idea from your TLS note ("publish the public half freely; only the private half can produce a valid signature") applied to authentication instead of transport. **For a microservices architecture, RS256 (or ES256, which is smaller/faster) is the correct default** — only your central auth/identity service ever touches the private key; every other service only ever needs the public key to verify, and a compromised downstream service can *check* tokens but never *forge* them.

### 4.5 A known attack class worth knowing by name: `alg: none`

Because the header's `alg` field is attacker-controlled (it's just base64 in the token you received), a naive JWT library that trusts the incoming `alg` value can be tricked into accepting a token signed with `alg: "none"` (an unsigned token) as valid, or tricked into verifying an RS256 token's signature *as if it were HS256* using the public key as the HMAC secret (since the public key is, well, public). **The fix:** always explicitly pin the expected algorithm on the verifying side (`verify(token, publicKey, { algorithms: ['RS256'] })`) rather than trusting whatever `alg` the token claims. Every mainstream JWT library supports this; it's a one-line config detail with real consequences if skipped.

**Gap this exposes:** we now have a way to prove identity that's fast, stateless, and verifiable by any service holding a public key. But we haven't decided *how long* this proof should last — and that single decision has massive security implications, which is the next section.

---

## 5. The access/refresh token pair

### 5.1 Why one token isn't enough

There's a direct tension:

- **Short-lived tokens** are safer (if stolen, the attacker's window is tiny) but annoying (the user gets logged out constantly, or you re-run the full login/password check disturbingly often).
- **Long-lived tokens** are convenient but dangerous (if stolen, the attacker has *long-term* access, and — critically — since JWTs are self-verifying, **you can't easily revoke one early** without extra machinery. See §7.)

The resolution the industry converged on: **use two tokens with very different lifetimes and very different jobs.**

| | Access Token | Refresh Token |
|---|---|---|
| **Job** | Sent on every API request, to prove identity for that call | Used *only* to obtain a new access token |
| **Lifetime** | Short — minutes (e.g. 15 min) | Long — days/weeks |
| **Format** | JWT (self-verifying, stateless) | Usually opaque random string, or JWT — but always tracked server-side |
| **Where checked** | By every resource service, statelessly | Only by the auth service itself |
| **Sent on** | Every request | Only to the `/token/refresh` endpoint |
| **If stolen** | Damage capped to its short lifetime | Serious — this is the high-value target, hence extra protections (§6) |

### 5.2 The flow, end to end

```
1) LOGIN
Client ──POST /login {email,pw}──► Auth service
                                     │ verify credentials
                                     │ issue: access_token (15 min, JWT, RS256)
                                     │         refresh_token (14 days, opaque, stored server-side)
Client ◄── {access_token, refresh_token} ──┘

2) NORMAL API CALLS  (repeated many times over 15 min)
Client ──GET /orders  Authorization: Bearer <access_token>──► mo-orders-svc
                                     │ verify signature + exp locally, NO db call
                                     └── 200 OK

3) ACCESS TOKEN EXPIRES (after 15 min)
Client ──GET /orders  Authorization: Bearer <expired access_token>──► mo-orders-svc
                                     └── 401 Unauthorized (exp claim in the past)

4) REFRESH
Client ──POST /token/refresh {refresh_token}──► Auth service
                                     │ look up refresh_token server-side
                                     │ valid? not revoked? not reused?
                                     │ issue NEW access_token (+ optionally new refresh_token, see §6)
Client ◄── {access_token, refresh_token} ──┘

5) Client resumes normal API calls with the new access_token
```

```
        AuthN load over time
Access token:  |--15min--|X   |--15min--|X   |--15min--|X    (expires often, cheap to verify)
Refresh call:            ↓             ↓             ↓
                    (talks to auth service only here — resource services never see it)
```

Notice the architectural win: **only the auth service ever touches the refresh token or the user store.** Every other service in your system only ever deals with the short-lived, self-verifying access token. This cleanly isolates your highest-value secret-verification logic into one place — directly useful for your proposal, since it gives you a clean "here's the one service that owns credential verification" answer.

### 5.3 Database shape for refresh tokens

Unlike access tokens (deliberately stateless), refresh tokens are **always** tracked server-side — this is non-negotiable, because it's the only way you get real revocation and theft detection (§6, §7).

```sql
CREATE TABLE refresh_tokens (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       BIGINT NOT NULL REFERENCES users(id),
  token_hash    TEXT NOT NULL,          -- never store the raw token, hash it (SHA-256)
  family_id     UUID NOT NULL,          -- groups a chain of rotated tokens, see §6
  issued_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ NOT NULL,
  revoked_at    TIMESTAMPTZ,            -- null = still active
  replaced_by   UUID REFERENCES refresh_tokens(id),  -- rotation chain pointer
  user_agent    TEXT,
  ip_address    INET
);

CREATE INDEX idx_refresh_tokens_family ON refresh_tokens(family_id);
CREATE INDEX idx_refresh_tokens_user   ON refresh_tokens(user_id);
```

Store a **hash** of the refresh token, never the raw value — same principle as password storage. If your DB is ever leaked, raw refresh tokens in it would be immediately usable by an attacker; hashed ones aren't.

**Gap this exposes:** a stolen refresh token is now the single highest-value target in the whole system — it's long-lived and it's the thing that mints new access. We need a way to limit the blast radius of theft, and ideally *detect* it happening. That's rotation.

---

## 6. Refresh token rotation and reuse detection

### 6.1 Rotation — never reuse a refresh token

The rule: **every time a refresh token is used, it is immediately invalidated and a brand-new refresh token is issued in its place.** A refresh token is single-use.

```sql
-- On every successful /token/refresh call:
UPDATE refresh_tokens
SET revoked_at = now(), replaced_by = :new_token_id
WHERE id = :old_token_id;

INSERT INTO refresh_tokens (id, user_id, token_hash, family_id, expires_at)
VALUES (:new_token_id, :user_id, :new_hash, :same_family_id, :new_expiry);
```

This creates a **chain** — a `family_id` links every refresh token ever issued from one original login session:

```
Login ──► RT1 (family: F1)
             │ used
             ▼
           RT2 (family: F1, replaces RT1)
             │ used
             ▼
           RT3 (family: F1, replaces RT2)   ← currently active
```

### 6.2 Reuse detection — turning rotation into an alarm

Here's the payoff. Because each refresh token is single-use, **if a revoked (already-used) refresh token is ever presented again, that's not a normal error — it's a strong signal of theft.** Think through why: the *only* way `RT1` gets used a second time is if someone other than the legitimate client got a copy of it — either the legitimate client and an attacker both have it (theft), or something is badly wrong.

```
Legitimate client uses RT1 → gets RT2.  RT1 is now revoked.

...later, an ATTACKER who stole RT1 earlier tries to use RT1...

Server: RT1 is found, but revoked_at IS NOT NULL
        → this is a REUSE of an already-rotated token
        → assume the entire family F1 is compromised
        → revoke EVERY token in family F1 (including the legitimate RT2/RT3!)
        → force full re-login
        → (optionally) alert / log a security event
```

```sql
-- On /token/refresh, if the presented token is found but already revoked:
UPDATE refresh_tokens
SET revoked_at = now()
WHERE family_id = (SELECT family_id FROM refresh_tokens WHERE id = :presented_token_id)
  AND revoked_at IS NULL;
```

Yes — this deliberately logs out the *legitimate* user too, along with the attacker. That's the correct tradeoff: you cannot tell which of the two token-holders is legitimate at that moment, so the safe move is to kill the whole family and make both sides re-authenticate. This single mechanism — rotate + detect reuse + kill the family — is widely considered the standard, industry-grade pattern for refresh tokens today (it's what you'll see described as "refresh token rotation with automatic reuse detection" in OAuth/Auth0/Okta documentation), and it's a strong, concrete thing to put in your proposal as a named, defensible design decision.

---

## 7. Where to store tokens on the client

This is a genuinely contested tradeoff, so it's worth understanding both attack classes it's balancing, not just memorizing "cookies are safer."

| Storage | Vulnerable to | Notes |
|---|---|---|
| `localStorage` / `sessionStorage` | **XSS** — any injected JS can read it directly (`localStorage.getItem(...)`) | Convenient, but if your app has *any* XSS hole, tokens are trivially exfiltrated |
| Regular cookie (JS-readable) | XSS (JS can read `document.cookie`) | Same problem as localStorage, plus CSRF exposure |
| **`httpOnly` cookie** | **CSRF** — browser auto-attaches the cookie to any request to your domain, even ones triggered by a malicious third-party site | JS *cannot* read it, so XSS can't directly steal it — but a malicious page can still trigger a request that carries it |
| In-memory JS variable (never persisted) | Lost on page refresh/tab close (bad UX) | Access token only, not workable for refresh token (need it to survive reload) |

The pattern most production systems converge on:

```
Access token  → kept in memory (JS variable), short-lived enough that XSS exposure window is small
Refresh token → httpOnly, Secure, SameSite=Strict (or Lax) cookie
                — JS can never read it (mitigates XSS theft)
                — SameSite mitigates CSRF (browser won't attach it to cross-site requests)
```

```http
Set-Cookie: refresh_token=<opaque>; HttpOnly; Secure; SameSite=Strict; Path=/token/refresh; Max-Age=1209600
```

Breaking down each flag and exactly what it defends against:
- `HttpOnly` — JavaScript cannot read this cookie at all → defeats XSS token theft for this cookie
- `Secure` — only ever sent over HTTPS → defeats network eavesdropping (this is your TLS note's confidentiality property, applied to cookie transport)
- `SameSite=Strict` — never sent on cross-site requests → defeats CSRF
- `Path=/token/refresh` — scope the cookie so it's *only ever sent to the refresh endpoint*, not to every API call → shrinks the blast radius even further

**This directly names the vulnerability you already found in `mo-marketplace`:** a long-lived private key sent straight from the browser to Cloud Run is, in this framework, the worst possible combination — it behaves like a *refresh-token-equivalent* credential (long-lived, high-value) but is being handled like an access token (sent on every request, presumably readable by JS or embedded in the bundle) with **none** of the storage protections above. Topic 9 (security hardening) will come back to this as a worked remediation, once you've got the full token model in hand.

**Gap this exposes:** storage protections reduce *how easily* a token can be stolen — but they don't address a token that's already valid and already out in the wild (stolen before rotation caught it, or an admin needs to kill a session *right now* for a fired employee). That's revocation — the one problem token-based auth doesn't solve for free.

---

## 8. Revocation — the fundamental tension with stateless tokens

Go back to the entire *point* of JWTs (§3–4): a service can verify a token **without calling anywhere else.** That statelessness is exactly what makes JWTs fast and microservices-friendly — and it's exactly what makes early revocation hard. A JWT is valid *by construction* until its `exp` timestamp, no matter what happens to the user in the meantime. If you disable a compromised account, a JWT issued five minutes earlier is still perfectly "valid" by every cryptographic check for the rest of its `exp` window.

Four real strategies exist, each trading some of the statelessness back for revocation power:

### 8.1 Just wait it out (short expiry)
Keep access tokens genuinely short (5–15 min). Revocation isn't instant, but the exposure window is small. This is *why* access tokens are kept short in the first place — it's not arbitrary, it's the primary defense against un-revocability. Cheapest option, and the refresh-token layer (§6) already gives you real, immediate revocation for anything longer-lived.

### 8.2 Denylist / blocklist for emergencies
Keep a small, fast lookup (Redis, in-memory cache) of token IDs (`jti` claim) that have been explicitly killed early — a fired employee, a confirmed-compromised account. Every verification does one cheap cache check in addition to the signature check.

```json
{ "sub": "41213", "jti": "b7e2-...", "exp": 1751537300 }
```

```
Verify:
  1. signature valid? ✓
  2. exp in the future? ✓
  3. jti IN denylist?  → if yes, REJECT even though 1 & 2 passed
```

This reintroduces a shared lookup (the exact cost sessions had, §2.2) — but only as a rare-case *exception path* for emergency kills, not for every request's primary check, so it stays cheap in practice. This is the realistic middle ground for a system your size.

### 8.3 Short-lived access + token versioning
Add a `token_version` (or `sessions_valid_since`) column on the `users` table. Bump it whenever you want to invalidate *everything* issued before now (e.g. "user changed their password" or "admin force-logout"). Put the version in the JWT payload; each verifying service can optionally check it against a cached/periodically-refreshed copy of that column.

```sql
ALTER TABLE users ADD COLUMN token_version INT NOT NULL DEFAULT 1;
-- "kill all this user's tokens issued before right now":
UPDATE users SET token_version = token_version + 1 WHERE id = 41213;
```

### 8.4 Refresh-layer revocation (the one you already have for free)
This is why the two-tier design in §5 matters so much: **you don't actually need to revoke the access token itself in most cases** — you revoke the *refresh token*, which is already tracked server-side (§5.3). The compromised access token dies naturally within minutes; the attacker can never mint a new one, because refreshing requires the now-dead refresh token. This is the primary revocation mechanism for the large majority of real-world cases ("log out everywhere," "this session looked suspicious," rotation-reuse detection from §6). The denylist (§8.2) is reserved for the rarer case where you need to kill an *already-issued, still-live access token* within its own short window — genuinely urgent, security-incident-grade situations.

**Practical recommendation for your redesign:** access tokens stay short and stateless (§8.1) as the default; refresh tokens are your real revocation lever (§8.4, backed by §5.3's table + §6's rotation); layer in a lightweight denylist (§8.2) only for the emergency "kill this access token right now" case. Token versioning (§8.3) is a reasonable addition later if you find yourself needing bulk "invalidate everything for this user" operations often — good to know it exists, not necessarily v1 scope.

---

## 9. Summary — the full picture

```
┌─────────────────────────────────────────────────────────────────┐
│ LOGIN → auth service verifies credentials                        │
│   issues: access_token (JWT, RS256, ~15min, stateless)            │
│           refresh_token (opaque, ~14days, tracked in DB)          │
├─────────────────────────────────────────────────────────────────┤
│ EVERY API CALL → resource service verifies access_token           │
│   signature check with PUBLIC key only (no DB call, no auth svc)  │
├─────────────────────────────────────────────────────────────────┤
│ ACCESS EXPIRES → client calls /token/refresh with refresh_token   │
│   auth service: rotate (old dies, new issued, same family)        │
│                 detect reuse (old token seen again → kill family) │
├─────────────────────────────────────────────────────────────────┤
│ REVOCATION NEEDED NOW → kill the refresh token (§8.4, primary)    │
│   OR denylist the specific access token jti (§8.2, emergency)     │
└─────────────────────────────────────────────────────────────────┘
```

| Term | One-line definition |
|---|---|
| **Session** | Server-stored proof of identity, looked up by an opaque ID on every request |
| **Token (JWT)** | Self-contained, signed proof of identity, verified cryptographically without a lookup |
| **Access token** | Short-lived JWT sent on every API call |
| **Refresh token** | Long-lived, server-tracked credential used only to mint new access tokens |
| **Rotation** | Every refresh token is single-use; using it issues a new one and kills the old |
| **Reuse detection** | A revoked refresh token being presented again signals theft → kill the whole family |
| **`jti` denylist** | Emergency-only mechanism to kill an already-issued, still-valid access token early |

**Where we go next (Topic 3):** we've now fully answered "how do we know who someone is, and keep proving it cheaply." Topic 3 moves to the other half of Topic 1's split — authorization models: RBAC formalized properly, then ABAC/PBAC, then ReBAC (relevant to marketplace ownership rules like "only the listing's owner can edit it"), and where the actual "allow/deny" decision should live in a multi-service system.
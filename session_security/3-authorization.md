# Topic 3 — Authorization Models: RBAC, ABAC/PBAC, ReBAC

> Scope: Topic 1 defined authorization as "can this authenticated principal do this action on this resource, right now." This note is about the actual **models** used to answer that question — how the rules are represented, stored, and evaluated. We go from the naive approach, to RBAC formalized properly, to ABAC/PBAC, to ReBAC (the Google Zanzibar model), and end with the architectural question of *where* this decision should physically live in a multi-service system. Applying this to your concrete `mo-marketplace` schema and enforcement points is Topic 4.

---

## 1. The naive starting point — and why it collapses immediately

The most direct way to answer "can this user do this?" is to just... write the check inline, wherever it's needed:

```typescript
// listings.controller.ts
@Delete(':id')
async deleteListing(@Param('id') id: string, @Req() req) {
  const listing = await this.listingsService.findOne(id);

  if (req.user.email !== 'admin@mo.lk' && req.user.id !== listing.sellerId) {
    throw new ForbiddenException();
  }
  await this.listingsService.remove(id);
}
```

This works, in the sense that it runs. But it breaks down fast, in ways that compound as a system grows past a handful of endpoints — which is exactly the situation a system with "really bad RBAC" tends to be in:

- **The rule is invisible.** To know "who can delete a listing," someone has to go read this specific controller method. There is no single place to look.
- **The rule is duplicated.** The same "owner or admin" logic gets rewritten slightly differently in `PATCH /listings/:id`, `POST /listings/:id/publish`, etc. — and slight differences between copies are exactly where bugs hide.
- **Hardcoded identity checks** (`req.user.email !== 'admin@mo.lk'`) are a special kind of fragile — what happens when there are two admins, or the admin's email changes?
- **It mixes two concerns that should be independent** (Topic 1's whole point): business logic ("remove this listing from the DB") and security policy ("who is allowed to trigger this") are now welded into the same function, which means you can't audit, test, or change one without touching the other.

**What we actually need:** a way to declare *"who can do what"* as **data**, separately from the code that does the *what*, so it can be looked up, audited, and changed in one place. That's the whole point of every model in this note — they're different answers to "how do we represent 'who can do what' as data instead of as scattered `if` statements."

---

## 2. RBAC — Role-Based Access Control

### 2.1 The core idea

Instead of granting permissions to individual users one by one, introduce an indirection layer: **roles**. A permission is granted *to a role*; a user is granted *a role*. This one indirection is the entire mechanism.

```
User ──assigned──► Role ──granted──► Permission ──applies to──► Resource/Action
```

Why indirection helps: when a new seller joins, you don't hand-pick 40 individual permissions for them — you assign the `seller` role, and they inherit everything that role has. When you decide sellers should also be able to issue partial refunds, you add **one** permission to the `seller` role, and every seller gets it instantly — you never touch a single user record.

### 2.2 Formal schema

```sql
CREATE TABLE roles (
  id    SERIAL PRIMARY KEY,
  name  TEXT UNIQUE NOT NULL          -- 'buyer', 'seller', 'admin', 'support_agent'
);

CREATE TABLE permissions (
  id     SERIAL PRIMARY KEY,
  name   TEXT UNIQUE NOT NULL         -- 'listing:create', 'listing:delete', 'order:refund'
);

CREATE TABLE role_permissions (
  role_id       INT REFERENCES roles(id),
  permission_id INT REFERENCES permissions(id),
  PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE user_roles (
  user_id  BIGINT REFERENCES users(id),
  role_id  INT REFERENCES roles(id),
  PRIMARY KEY (user_id, role_id)      -- a user CAN hold more than one role
);
```

```
users ──┐
        ├──user_roles──► roles ──role_permissions──► permissions
        │
   (many-to-many both sides — this is the whole RBAC data model)
```

**Naming permissions as `resource:action`** (`listing:delete`, `order:refund`) rather than vague names (`can_delete`) is a convention worth adopting from day one — it makes the permission table self-documenting and makes wildcard/grouping logic possible later (e.g. `listing:*`).

### 2.3 The decision, worked as a query

```sql
-- "Can user 41213 perform listing:delete?"
SELECT EXISTS (
  SELECT 1
  FROM user_roles ur
  JOIN role_permissions rp ON rp.role_id = ur.role_id
  JOIN permissions p       ON p.id = rp.permission_id
  WHERE ur.user_id = 41213
    AND p.name = 'listing:delete'
);
```

In practice this query result gets cached (Topic 4 covers exactly how, and the staleness traps to avoid) — but the *query* is the ground truth definition of the decision, and it's one query, one place, fully auditable: "show me everyone who can delete listings" is now a real, answerable question instead of a code-search exercise.

### 2.4 Where RBAC hits its ceiling

RBAC answers *"does this role, in general, have this power"* — it has no concept of **which specific resource instance** the check applies to. Consider:

> "A seller may delete **their own** listings, but not anyone else's."

Pure RBAC cannot express this. `listing:delete` is either granted to the `seller` role or it isn't — there's no slot in this model for "...but only when `listing.sellerId === user.id`." You could try to route around this by creating a role per user (`seller_41213`), but that's role explosion — an unmanageable number of near-duplicate roles, defeating the entire point of the indirection.

```
              RBAC alone:
"seller" role → listing:delete → TRUE for every listing, everywhere
                                   ▲
                          (can't scope this to "only their own")
```

**Gap this exposes:** we need a model that can factor in *facts about the specific resource being acted on* (its owner) and *facts about the current context* (is it still editable, is it past a deadline) — not just "what role does this user have." That's ABAC.

---

## 3. ABAC — Attribute-Based Access Control

### 3.1 The core idea

Instead of asking "what role do you have," ABAC asks a richer question by evaluating a **rule** (a policy) against **attributes** drawn from up to three sources:

| Attribute source | Examples |
|---|---|
| **Subject** (who) | `user.id`, `user.roles`, `user.accountStatus`, `user.trustScore` |
| **Resource** (what's being acted on) | `listing.sellerId`, `listing.status`, `order.amount` |
| **Environment** (context) | current time, request IP, whether it's within a business SLA window |

A policy is a **rule expressed over these attributes**, evaluated at request time:

```
ALLOW listing:delete IF
  user.role == 'admin'
  OR (user.role == 'seller' AND listing.sellerId == user.id)
```

```
ALLOW order:refund IF
  user.role == 'support_agent'
  AND order.amount <= 5000        -- support agents can only refund small orders
  AND order.status == 'delivered'
```

Notice this second example is something **pure RBAC genuinely cannot express at all** — a permission that depends on a *numeric attribute of the resource itself* (order amount). This is exactly the class of rule ABAC was built for.

### 3.2 Where the policy actually lives — from `if` statements to a real policy layer

You could write the ABAC rule above directly as an `if` statement (and plenty of systems do, at small scale) — but that just brings back §1's problem (rules invisible, duplicated, welded to business logic) unless the rule is pulled out into its own explicit, centrally-defined layer. This is where **PBAC** comes in — not a different model from ABAC, but the *engineering discipline* of implementing ABAC-style rules as declared, centrally managed policy rather than scattered conditionals.

A widely used real tool for this is **OPA (Open Policy Agent)**, using its policy language **Rego**:

```rego
package mo.authz

default allow = false

allow {
  input.user.role == "admin"
}

allow {
  input.user.role == "seller"
  input.resource.sellerId == input.user.id
}
```

The service sends a small JSON document describing the decision to make, and gets back `{ "allow": true/false }`:

```json
// Request TO the policy engine
{
  "input": {
    "user":     { "id": 41213, "role": "seller" },
    "action":   "listing:delete",
    "resource": { "sellerId": 41213, "status": "active" }
  }
}
```
```json
// Response FROM the policy engine
{ "result": { "allow": true } }
```

The payoff: policy logic is now **data/config, versionable and reviewable independently of application code**, testable in isolation, and — critically for an audit-heavy domain like a marketplace handling payments — you can point at one file and say "this is the complete, current authorization policy for the system."

**Gap this exposes:** ABAC/PBAC is powerful, but writing a rule like `listing.sellerId == user.id` still means *every single resource type* needs its own hand-written ownership rule, and it doesn't generalize well to **relationships between principals** — e.g., "a user can view an order if they are the buyer, OR the seller of any item in that order, OR a support agent assigned to that order's dispute." That's not really an *attribute* comparison anymore — it's a graph of relationships. That's ReBAC.

---

## 4. ReBAC — Relationship-Based Access Control

### 4.1 The core idea

ReBAC (the model behind Google's internal **Zanzibar** system, which is what Google Drive/Docs sharing runs on) represents authorization as a **graph of relationship tuples**, and answers access questions by asking "is there a path through this graph connecting this user to this resource via an allowed relationship?"

A relationship tuple has the shape:

```
object # relation @ subject
```

```
listing:9981   # owner        @ user:41213
listing:9981   # can_edit     @ user:41213
order:7712     # buyer        @ user:41213
order:7712     # seller       @ user:88820
dispute:331    # assigned_to  @ user:90011      (a support agent)
dispute:331    # concerns     @ order:7712
```

```sql
CREATE TABLE relationship_tuples (
  id            BIGSERIAL PRIMARY KEY,
  object_type   TEXT NOT NULL,   -- 'listing', 'order', 'dispute'
  object_id     TEXT NOT NULL,
  relation      TEXT NOT NULL,   -- 'owner', 'buyer', 'seller', 'assigned_to'
  subject_type  TEXT NOT NULL,   -- 'user', or another object (for graph traversal)
  subject_id    TEXT NOT NULL
);
```

The authorization check becomes: *"does a tuple (or chain of tuples) exist connecting `user:41213` to `listing:9981` via a relation that implies the requested permission?"*

```
Question: can user:41213 edit listing:9981?

  listing:9981 # owner @ user:41213     ← direct tuple exists → ALLOW
```

```
Question: can user:90011 (support agent) view order:7712?

  dispute:331   # assigned_to @ user:90011   ┐
  dispute:331   # concerns    @ order:7712   ┘── chained → ALLOW (2-hop relationship)
```

### 4.2 Why this matters specifically for a marketplace

Marketplaces are *full* of exactly this shape of question — ownership, buyer/seller pairs, shared access, delegated support access — which is precisely the pattern ReBAC was designed for and where ABAC's flat attribute comparisons start to feel forced. You don't need to adopt a full Zanzibar-style system for a 3–4 service project (that's genuinely heavy infrastructure) — but the **relationship-tuple way of thinking** is worth internalizing now, because in Topic 4 we'll design your `listing.sellerId == user.id` ownership checks as a *lightweight, practical form of ReBAC* (a direct foreign-key relationship standing in for a formal tuple), rather than reaching for a full policy-engine or graph-database dependency you don't need yet.

### 4.3 The three models side by side

| | RBAC | ABAC | ReBAC |
|---|---|---|---|
| **Decision based on** | Role membership | Attributes of subject/resource/environment | Relationships/graph between subject and resource |
| **Good at** | Coarse, org-wide capabilities ("sellers can create listings") | Conditional rules with numeric/state logic ("refund ≤ $50, only if delivered") | Ownership, sharing, delegation ("owner", "assigned to", "member of") |
| **Weak at** | Per-resource, per-instance rules | Doesn't model relationship chains naturally | Overkill/heavy if you don't actually have relationship graphs |
| **Storage shape** | Two small join tables | Rules/policy files + attribute lookups | Tuple table (graph-shaped) |
| **Marketplace example** | "Only admins can access the admin dashboard" | "Support agents can only refund orders under $50" | "Only this listing's owner can edit it" |

**These are not mutually exclusive — real systems combine them.** Your practical target (built out fully in Topic 4) is a **hybrid**: RBAC for coarse role-level gates (admin dashboard access, seller-only endpoints) layered with lightweight ownership checks (a ReBAC-flavored direct relationship check) for "is this specifically *their* resource," and a small amount of ABAC-style conditional logic where a rule genuinely depends on a resource attribute (like the refund-amount example). This is, in fact, how most real production systems look — pure single-model implementations are rarer in practice than the clean taxonomy above suggests.

---

## 5. Where should the authorization decision actually be made?

Regardless of which model(s) you use, there's a separate architectural question: **which piece of code in your system is responsible for evaluating the policy and returning allow/deny?** Two ends of a spectrum:

### 5.1 Decentralized — each service enforces its own rules locally

```
┌────────────┐     ┌────────────────────────────┐
│  Request    │────►│  mo-orders-svc              │
└────────────┘     │  [Guard checks role+owner]   │
                    │  → business logic            │
                    └────────────────────────────┘
```

Each service has its own guards/middleware (in NestJS: `@UseGuards(RolesGuard)`) that check roles/ownership directly against data it already has locally.

**Pro:** No extra network hop, no new shared dependency, low latency, simple to reason about per-service.
**Con:** Policy logic is now duplicated across services (the same "is admin" check reimplemented N times); keeping N independent implementations consistent as rules evolve is a real maintenance cost; auditing "what's our complete authorization policy" means reading N codebases.

### 5.2 Centralized — a dedicated policy service/engine makes every decision

```
┌────────────┐    ┌───────────────┐    ┌─────────────────────┐
│  Request    │───►│ mo-orders-svc │───►│  policy engine (OPA)  │
└────────────┘    │ (business only)│◄───│  ALLOW / DENY          │
                    └───────────────┘    └─────────────────────┘
```

Every service, on every protected action, calls out to one central authority that holds *all* the policy logic and returns a decision.

**Pro:** One single source of truth for every rule in the system; change a rule once, it applies everywhere instantly; genuinely strong audit story ("here is the one policy file governing the entire platform").
**Con:** Adds a network hop (and a new critical-path dependency) to *every* authorized request across every service; if the policy engine is slow or down, everything that depends on it degrades too — this is a real operational cost, not a theoretical one.

### 5.3 The practical middle ground for a 3–4 service system

```
┌────────────┐    ┌───────────────────────────────┐
│  Request    │───►│  mo-orders-svc                 │
└────────────┘    │  Guard: role check LOCAL         │
                    │         (roles are in the JWT,   │
                    │          zero extra calls)        │
                    │  Ownership check LOCAL            │
                    │         (compare resource.ownerId │
                    │          to token's sub — data     │
                    │          already being fetched)    │
                    └───────────────────────────────┘
```

For a system your size, a full centralized policy engine is very likely more operational overhead than the problem justifies right now. The pragmatic pattern — and the one Topic 4 will build out concretely — is: **put coarse role information directly in the access token's claims** (so the "is this an admin/seller/buyer" check is a zero-cost local check, no network call, no DB lookup), and do **ownership/attribute checks locally inside each service**, using data the service is already fetching for the request anyway (it already has to load the listing to delete it — checking `listing.sellerId` on that same row costs nothing extra). This gets you the *effect* of RBAC + a ReBAC-style ownership check + a bit of ABAC, without introducing the centralized-engine dependency and its failure mode, while still keeping the actual **rule definitions** (which roles map to which permissions) centrally defined in your database (§2.2) rather than scattered as inline `if` statements — which is the part that actually matters for auditability. A dedicated policy engine becomes worth its operational cost later if you grow well past a handful of services or need externally-auditable, non-engineer-editable policy — worth knowing the option exists, not something to build now.

---

## 6. Summary

```
┌───────────────────────────────────────────────────────────────┐
│  RBAC   → "what role does this user have, in general"           │
│  ABAC   → "+ what attributes does the resource/context have"    │
│  ReBAC  → "+ what relationship connects this user to this thing"│
│                                                                   │
│  Real systems: combine them. Your target = RBAC (roles, in JWT)  │
│                + local ownership check (ReBAC-flavored)          │
│                + occasional attribute rule (ABAC-flavored)       │
└───────────────────────────────────────────────────────────────┘
```

| Term | One-line definition |
|---|---|
| **RBAC** | Permissions granted to roles; users granted roles |
| **Role explosion** | The failure mode of trying to force per-instance rules into RBAC by creating near-duplicate roles |
| **ABAC** | Access decided by evaluating a rule over subject/resource/environment attributes |
| **PBAC** | The practice of centralizing ABAC-style rules into a declared, reviewable policy layer instead of scattered code |
| **ReBAC** | Access decided by traversing a graph of relationship tuples (`object#relation@subject`) |
| **Zanzibar** | Google's production ReBAC system; the reference architecture the model is named after |
| **Centralized decision** | One policy engine/service makes every allow/deny call, at the cost of a network hop everywhere |
| **Decentralized decision** | Each service enforces locally, at the cost of duplicated logic |

**Where we go next (Topic 4):** we take this exact hybrid model and make it concrete for `mo-marketplace` — the actual Postgres schema for roles/permissions, how role claims get embedded into the JWT from Topic 2, how NestJS guards enforce it at each service, how ownership checks get written idiomatically, and how (and how *not*) to cache this data without reintroducing the stale-permission bugs flagged back in Topic 1.
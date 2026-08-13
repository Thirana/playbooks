# Topic 4 — RBAC System Design, Applied to `mo-marketplace`

> Scope: Topic 3 landed on a hybrid model — RBAC for coarse role gates, a lightweight ownership check standing in for ReBAC, occasional attribute rules. This note makes that concrete for your actual system: a proper schema replacing the single `role` column, how roles travel in the JWT, how NestJS guards enforce it, where the enforcement point should physically sit given your real topology, and how to cache the role→permission lookup without reintroducing stale-permission bugs.
>
> Before the schema, we need to map this onto how your system actually talks to itself — because it changes one of the design decisions materially.

---

## 1. Your actual topology, and the one thing in it that matters most here

```
                    ┌──────────────┐
 Mobile App ───┐    │  GCP Load     │
 Admin Panel ──┼───►│  Balancer     │───► BE Server (main API)
                    └──────────────┘           │
                                                 │  (BE → service, sync HTTP)
                                    ┌────────────┼────────────┐
                                    ▼                          ▼
                          Notification Svc              Rewards Svc
                            (Cloud Run)                  (Cloud Run)
                                    ▲                          ▲
                                    │      (async, polled)      │
                                BE ─┴──► RabbitMQ ──────────────┘
                                          (Notification & Rewards
                                           consume via scheduled jobs)

     ⚠ Existing leak: in a few places, Mobile App calls the
       Notification/Rewards Cloud Run URLs DIRECTLY — bypassing BE entirely.
```

Everything in Topics 1–3 about trust boundaries lands directly on that last line. **BE is, in practice, your authorization chokepoint** — almost every user-initiated action flows through it, and it's the one place that has full context (who's logged in, their roles, the resource being touched) to make an RBAC decision. The direct mobile→Cloud Run calls are exactly the "erased trust boundary" pattern from Topic 1 §6: those two services are receiving user-facing traffic **without going through the one place that's actually equipped to authorize it.**

This note focuses on designing RBAC properly for BE, since that's where the real decision-making lives today. The mobile-bypass leak is a genuine finding for your proposal, but *fixing* it is really a Topic 5/6 problem (it needs a proper M2M/service-identity answer, not an RBAC one) — so we name it clearly here, and pick it back up concretely once that machinery exists. For now, one design rule falls out of it immediately: **Notification and Rewards should not need their own RBAC system.** They should either (a) only be reachable via BE, which has already made the authorization decision, or (b) if a genuine direct-from-client endpoint must exist there, it should verify the *same* access token BE would — not invent a separate, weaker check. We'll design towards that.

---

## 2. From a `role` column to a real RBAC schema

### 2.1 What you have vs. what's missing

A single `role` enum column on `users` (`'buyer' | 'seller' | 'admin'`) works exactly like RBAC's role part — but it silently assumes **one role per user**, and it has no `permissions` layer at all; every check downstream has to hardcode "if role === 'admin'" or "if role === 'seller'" directly, which is precisely the scattered-`if`-statement problem from Topic 3 §1.

There's also a modeling question specific to a marketplace, worth deciding deliberately rather than inheriting by accident: **can the same account be both a buyer and a seller?** In most marketplaces (yours included, most likely) — yes: a user browses and buys things, *and* separately lists things for sale, on the same account, often in the same session. If that's true for `mo-marketplace`, a single-role-per-user column is actually a modeling mistake waiting to surface (what happens the day a buyer lists their first item — do they get a *new account*, or does their existing account need a second role?). This is worth confirming against your actual product rules, but the safe, low-cost default is to support **multiple roles per user** from the start — it costs one extra join table and saves you a painful migration later.

### 2.2 The schema

```sql
CREATE TABLE roles (
  id    SERIAL PRIMARY KEY,
  name  TEXT UNIQUE NOT NULL              -- 'buyer', 'seller', 'admin'
);

CREATE TABLE permissions (
  id    SERIAL PRIMARY KEY,
  name  TEXT UNIQUE NOT NULL              -- 'listing:create', 'listing:delete', 'order:refund', ...
);

CREATE TABLE role_permissions (
  role_id       INT REFERENCES roles(id),
  permission_id INT REFERENCES permissions(id),
  PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE user_roles (
  user_id  BIGINT REFERENCES users(id),
  role_id  INT REFERENCES roles(id),
  PRIMARY KEY (user_id, role_id)          -- a user can hold buyer AND seller simultaneously
);
```

A starting permission set mapped to your actual domain (fill in/extend as your resources grow):

| Role | Permissions |
|---|---|
| `buyer` | `order:create`, `order:view_own`, `review:create` |
| `seller` | `listing:create`, `listing:update_own`, `listing:delete_own`, `order:view_as_seller` |
| `admin` | `listing:*`, `order:*`, `user:suspend`, `dispute:resolve` |

(The `resource:*` wildcard for admin is a convenience your `PermissionsService`, §4, can expand — `listing:*` grants every `listing:` prefixed permission — rather than hand-listing every single one for the admin role.)

### 2.3 Migrating without a big-bang cutover

You don't need to rip out the old column in one deploy. A safe sequence:

```sql
-- 1. Add the new tables (above), seed roles + permissions.

-- 2. Backfill from the existing column — every existing user keeps their current role.
INSERT INTO user_roles (user_id, role_id)
SELECT u.id, r.id
FROM users u
JOIN roles r ON r.name = u.role;

-- 3. Run both systems in parallel for a release or two:
--    read from user_roles going forward, but leave `users.role` populated
--    (e.g. via a trigger, or just dual-write in application code) as a
--    safety net until you're confident nothing still reads the old column.

-- 4. Once confirmed unused, drop the column.
ALTER TABLE users DROP COLUMN role;
```

This mirrors the same "don't break what's live, add the new thing alongside, cut over deliberately" discipline you'd want for any production data migration — nothing auth-specific about the caution here, just worth stating explicitly since this table touches every authenticated request.

---

## 3. Getting roles into the token

Recall from Topic 2 §4.2: the JWT payload is readable but tamper-evident, and shouldn't carry anything you don't want any client to be able to read. Role names (`"seller"`) are fine to expose; full permission strings arguably are too, but there's a better reason to leave permissions **out** of the token entirely:

```json
{
  "sub": "41213",
  "roles": ["buyer", "seller"],
  "iat": 1751536400,
  "exp": 1751537300
}
```

**Only role names go in the token — never the expanded permission list.** Here's the reasoning, tying directly back to Topic 2's revocation discussion: access tokens are short-lived (§8.1 of that note) and already self-verifying. If you baked the *full permission list* into the token and later changed what the `seller` role can do (e.g. revoked `listing:delete_own` from sellers pending a policy review), every already-issued token would keep the *old* permission set until it naturally expired — a live security-relevant change wouldn't actually take effect for up to 15 minutes, silently. Keeping only the **role name** in the token, and expanding roles → permissions **server-side, at request time, against current data** (§5), means a permission change takes effect on the very next request — no waiting on token expiry, no reissue needed. Role names change far less often than permission grants, so this split minimizes both token size and staleness risk.

---

## 4. Enforcing it in NestJS

### 4.1 Declaring what a route needs

```typescript
// permissions.decorator.ts
import { SetMetadata } from '@nestjs/common';

export const RequirePermissions = (...permissions: string[]) =>
  SetMetadata('permissions', permissions);
```

```typescript
// listings.controller.ts
@Delete(':id')
@RequirePermissions('listing:delete_own')
@UseGuards(JwtAuthGuard, PermissionsGuard, ListingOwnerGuard)
async deleteListing(@Param('id') id: string, @Req() req) {
  await this.listingsService.remove(id);
}
```

Three guards, three separate jobs — deliberately not merged into one giant guard, so each stays simple and testable on its own:

1. **`JwtAuthGuard`** — Topic 2's work: verify the signature, populate `req.user` from the token claims (`sub`, `roles`).
2. **`PermissionsGuard`** — role → permission expansion (below).
3. **`ListingOwnerGuard`** — the ownership check (Topic 3's ReBAC-flavored piece).

### 4.2 The permissions guard

```typescript
// permissions.guard.ts
@Injectable()
export class PermissionsGuard implements CanActivate {
  constructor(
    private reflector: Reflector,
    private permissionsService: PermissionsService,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const required = this.reflector.get<string[]>('permissions', context.getHandler());
    if (!required || required.length === 0) return true;

    const { user } = context.switchToHttp().getRequest();
    const granted = await this.permissionsService.getPermissionsForRoles(user.roles);

    return required.every((perm) => granted.has(perm));
  }
}
```

### 4.3 The ownership guard

```typescript
// listing-owner.guard.ts
@Injectable()
export class ListingOwnerGuard implements CanActivate {
  constructor(private listingsService: ListingsService) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const req = context.switchToHttp().getRequest();

    if (req.user.roles.includes('admin')) return true;   // admins bypass ownership

    const listing = await this.listingsService.findOne(req.params.id);
    if (!listing) throw new NotFoundException();

    req.listing = listing;   // stash it — the controller needs this row anyway, avoid a second fetch
    return listing.sellerId === req.user.sub;
  }
}
```

### 4.4 The decision, traced end to end

```
DELETE /listings/9981     Authorization: Bearer <access_token, sub=41213, roles=[seller]>

1. JwtAuthGuard        → signature valid, req.user = {sub:'41213', roles:['seller']}
2. PermissionsGuard    → does 'seller' grant 'listing:delete_own'? → yes → pass
3. ListingOwnerGuard   → fetch listing 9981 → sellerId === '41213'? → yes → pass
4. Controller executes → listing deleted
```

```
DELETE /listings/9981     same token, but listing 9981 belongs to seller 88820

1. JwtAuthGuard        → passes (still a valid seller token)
2. PermissionsGuard    → 'seller' has 'listing:delete_own' → passes
3. ListingOwnerGuard   → sellerId (88820) !== sub (41213) → 403 Forbidden
```

Notice steps 2 and 3 are answering genuinely different questions — "can sellers in general delete their own listings" vs "is *this* the seller's *own* listing" — and failing at either produces the same clean `403`, but for auditably different reasons if you log which guard rejected the request (worth doing, see Topic 9).

---

## 5. Caching the role → permission lookup

`PermissionsGuard` needs `role → Set<permission>` on essentially every authorized request. Hitting Postgres for this every time is wasteful — this data changes rarely (an admin tweaking what a role can do is a deliberate, infrequent action) and is small enough to hold entirely in memory.

The trap to avoid (Topic 1 §4 called this out generally; here's the specific version): if you cache this with a long TTL and no invalidation, revoking a permission from a role won't take effect until the cache expires — exactly the stale-permission bug that undermines the whole point of keeping permissions out of the token (§3).

Since you already run Redis, the clean fix is **cache-aside + pub/sub invalidation**, not a bare TTL:

```
┌────────────────────┐
│  BE instance A       │──┐
│  in-memory map:       │  │
│  {seller: {...perms}} │  │  1. Admin updates role_permissions in Postgres
└────────────────────┘  │  2. BE publishes "roles:invalidated" on a Redis channel
                          │
┌────────────────────┐  │
│  BE instance B       │◄─┘  3. Every BE instance (subscribed to that channel)
│  in-memory map:       │       drops its in-memory map and refetches from
│  {seller: {...perms}} │       Postgres on next request
└────────────────────┘
```

```typescript
// permissions.service.ts (sketch)
@Injectable()
export class PermissionsService implements OnModuleInit {
  private cache = new Map<string, Set<string>>();   // role name -> permission set

  async onModuleInit() {
    await this.reload();
    this.redisSubscriber.subscribe('roles:invalidated', () => this.reload());
  }

  private async reload() {
    const rows = await this.db.query(`
      SELECT r.name AS role, p.name AS permission
      FROM role_permissions rp
      JOIN roles r ON r.id = rp.role_id
      JOIN permissions p ON p.id = rp.permission_id
    `);
    const next = new Map<string, Set<string>>();
    for (const { role, permission } of rows) {
      if (!next.has(role)) next.set(role, new Set());
      next.get(role)!.add(permission);
    }
    this.cache = next;
  }

  async getPermissionsForRoles(roles: string[]): Promise<Set<string>> {
    const result = new Set<string>();
    for (const role of roles) {
      for (const perm of this.cache.get(role) ?? []) result.add(perm);
    }
    return result;
  }
}
```

This gets you a **zero-database-hit permission check on every request** (pure in-memory lookup), while permission *changes* propagate to every running BE instance within milliseconds of an admin saving the change — no stale window, no waiting on a TTL. This is a good, concrete "here's how we avoid the classic caching pitfall" point for your proposal.

---

## 6. Static vs. dynamic: what should be code, what should be data

A useful line to draw, and one worth stating explicitly in your proposal since it's a common source of confusion:

- **Permission *names* are static** — declared as constants in code (`'listing:delete_own'`), not invented at runtime. This gives you compile-time safety (a typo in a permission string is a real, easy-to-make bug) and makes every permission grep-able across the codebase.
- **Role → permission *assignments* are dynamic** — pure data, in `role_permissions`, editable by an admin through a UI or a migration, with zero code deploy required. This is the actual point of RBAC: policy changes without shipping code.

```typescript
// permissions.constants.ts — the static, code-defined set
export const PERMISSIONS = {
  LISTING_CREATE: 'listing:create',
  LISTING_DELETE_OWN: 'listing:delete_own',
  ORDER_REFUND: 'order:refund',
  // ...
} as const;
```

Using the constant (`PERMISSIONS.LISTING_DELETE_OWN`) instead of a bare string literal in your `@RequirePermissions(...)` decorators costs nothing and eliminates an entire class of silent typo-bugs where a route is accidentally left unprotected because the permission string didn't match anything in the DB.

---

## 7. Where this leaves the rest of your topology

Tying back to §1: with this design, **BE becomes a genuine, well-defined enforcement point** — every user-initiated action is authenticated (Topic 2) and authorized (this note) in exactly one place, using exactly one source of truth for roles and permissions.

For the async path — BE publishing events to RabbitMQ, Notification/Rewards consuming them on a schedule — no additional RBAC check is needed at consumption time. **The authorization decision was already made** at the moment BE decided to publish the event; Notification/Rewards processing that event later isn't a new access decision, it's fulfilling one that was already granted. The open question there isn't "does this consumer have permission" — it's "how does Notification/Rewards know this event genuinely came from BE and not an attacker who found the RabbitMQ endpoint," which is a trust/identity question between *services*, not a user-permissions question. That's Topic 5.

The direct mobile→Cloud Run leak from §1 is the one piece this note deliberately doesn't fix — because bolting an RBAC check onto Notification/Rewards would just be re-deriving a second, parallel, likely-inconsistent copy of the exact system we just built for BE. The correct fix is architectural (route that traffic through BE, or give those services a real way to verify the same access tokens BE trusts) — worth flagging now as a named finding for your proposal, and we'll design the actual fix once Topic 5 gives us the right M2M/service-identity vocabulary to do it properly.

---

## 8. Summary

```
users ──user_roles──► roles ──role_permissions──► permissions   (Postgres, source of truth)
                          │
                          ▼
              JWT carries roles ONLY (["seller"]) — not expanded permissions
                          │
                          ▼
    PermissionsGuard expands roles → permissions via an in-memory cache
    (Redis pub/sub invalidated the moment an admin changes role_permissions)
                          │
                          ▼
    ListingOwnerGuard checks resource-level ownership (the ReBAC-flavored piece)
                          │
                          ▼
                 ALLOW → business logic  /  DENY → 403
```

| Decision | What we chose, and why |
|---|---|
| Multi-role users | `user_roles` many-to-many — a marketplace account is often both buyer and seller |
| What's in the JWT | Role names only, never expanded permissions — avoids stale-permission windows |
| Permission expansion | Server-side, per-request, against a cached role→permission map |
| Cache invalidation | Redis pub/sub on change, not a bare TTL — no stale window |
| Permission naming | Static constants in code; assignments remain dynamic DB data |
| Enforcement point | BE only, for now — Notification/Rewards should not grow a second RBAC system |
| Mobile→Cloud Run leak | Named as a finding; real fix deferred to Topic 5 (M2M) |

**Where we go next (Topic 5):** machine-to-machine authentication — why BE calling Notification/Rewards (and the mobile-bypass problem we just flagged) needs a completely different authentication model than the user-facing one we just built, covering OAuth2 Client Credentials, mTLS, and the GCP-native options (service accounts, Workload Identity) that map directly onto your Cloud Run services.
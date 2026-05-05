# ABAC/RBAC Permission System — Database States & Request Flows

This document walks through the exact DB and Redis records at each stage, and shows how each field is used during a real request.

---

## Scenario

- Workspace **ws-abc** is created by **Alice** (user id: 1) — she becomes the owner
- **Bob** (user id: 2) is invited as an `editor`
- **Carol** (user id: 3) is invited as a `viewer`
- **Dave** (user id: 4) is a contractor — given a one-off direct grant to `tasks:read` only, no role
- Bob creates task **id: 99**
- Carol tries to delete task 99 → should be rejected
- Dave tries to read task 99 → should be allowed

---

## Stage 1 — System Bootstrap (Seed Data)

These tables are populated once when the application is deployed. They never change unless you add new features.

**`permissions` table** — the atomic building blocks of the system

| id  | name                  | description                   |
| --- | --------------------- | ----------------------------- |
| 1   | `tasks:read`          | View tasks                    |
| 2   | `tasks:create`        | Create new tasks              |
| 3   | `tasks:update`        | Edit existing tasks           |
| 4   | `tasks:delete`        | Delete tasks                  |
| 5   | `tasks:assign`        | Reassign tasks to other users |
| 6   | `projects:read`       | View projects                 |
| 7   | `projects:create`     | Create projects               |
| 8   | `projects:update`     | Edit projects                 |
| 9   | `projects:delete`     | Delete projects               |
| 10  | `members:invite`      | Invite new members            |
| 11  | `members:remove`      | Remove members                |
| 12  | `members:update_role` | Change a member's role        |
| 13  | `workspace:settings`  | Edit workspace settings       |
| 14  | `workspace:billing`   | Manage billing                |

> These are the atoms. Roles are built by combining them. Every `@RequirePermission()` decorator in the codebase references one of these strings.

---

**`roles` table** — named bundles

| id  | workspace_id | name     | is_system |
| --- | ------------ | -------- | --------- |
| 1   | NULL         | `viewer` | true      |
| 2   | NULL         | `editor` | true      |
| 3   | NULL         | `admin`  | true      |
| 4   | NULL         | `owner`  | true      |

> `workspace_id = NULL` means these are global system roles. A workspace can add its own custom roles by inserting rows with their `workspace_id` set (shown in Stage 5).

---

**`role_permissions` table** — maps which permissions each role has

| role_id | permission_id | _(role name)_ | _(permission name)_ |
| ------- | ------------- | ------------- | ------------------- |
| 1       | 1             | viewer        | tasks:read          |
| 1       | 6             | viewer        | projects:read       |
| 2       | 1             | editor        | tasks:read          |
| 2       | 2             | editor        | tasks:create        |
| 2       | 3             | editor        | tasks:update        |
| 2       | 5             | editor        | tasks:assign        |
| 2       | 6             | editor        | projects:read       |
| 3       | 1             | admin         | tasks:read          |
| 3       | 2             | admin         | tasks:create        |
| 3       | 3             | admin         | tasks:update        |
| 3       | 4             | admin         | tasks:delete        |
| 3       | 5             | admin         | tasks:assign        |
| 3       | 6             | admin         | projects:read       |
| 3       | 7             | admin         | projects:create     |
| 3       | 8             | admin         | projects:update     |
| 3       | 9             | admin         | projects:delete     |
| 3       | 10            | admin         | members:invite      |
| 3       | 11            | admin         | members:remove      |
| 4       | 1–14          | owner         | (all permissions)   |

> The `PermissionsService.loadPermissions()` SQL joins across `workspace_members → roles → role_permissions → permissions` to collect this set for a given user. `role_id` here is the join key.

---

## Stage 2 — Workspace Created, Members Invited

Alice creates workspace `ws-abc` and invites Bob and Carol.

**`workspace_members` table**

| id    | workspace_id | user_id   | role_id    | invited_by | joined_at        |
| ----- | ------------ | --------- | ---------- | ---------- | ---------------- |
| mem-1 | ws-abc       | 1 (Alice) | 4 (owner)  | NULL       | 2025-04-20 09:00 |
| mem-2 | ws-abc       | 2 (Bob)   | 2 (editor) | 1          | 2025-04-20 09:05 |
| mem-3 | ws-abc       | 3 (Carol) | 1 (viewer) | 1          | 2025-04-20 09:10 |

> `role_id` is the single field that determines what a member can do. It points to the `roles` table, which fans out to `role_permissions`. Changing `role_id` here is the only thing needed to promote or demote a user.

**`user_permission_grants` table** — empty at this point

| id        | workspace_id | user_id | permission | granted_by | expires_at |
| --------- | ------------ | ------- | ---------- | ---------- | ---------- |
| _(empty)_ |              |         |            |            |            |

---

## Stage 3 — Dave Gets a Direct Permission Grant (No Role)

Dave is a contractor. Alice grants him `tasks:read` only, expiring in 7 days.

```sql
INSERT INTO user_permission_grants (workspace_id, user_id, permission, granted_by, expires_at)
VALUES ('ws-abc', 4, 'tasks:read', 1, NOW() + INTERVAL '7 days');
```

**`workspace_members` table** — Dave has NO row here (he has no role assignment)

| id    | workspace_id | user_id   | role_id    | invited_by | joined_at        |
| ----- | ------------ | --------- | ---------- | ---------- | ---------------- |
| mem-1 | ws-abc       | 1 (Alice) | 4 (owner)  | NULL       | 2025-04-20 09:00 |
| mem-2 | ws-abc       | 2 (Bob)   | 2 (editor) | 1          | 2025-04-20 09:05 |
| mem-3 | ws-abc       | 3 (Carol) | 1 (viewer) | 1          | 2025-04-20 09:10 |

**`user_permission_grants` table** — Dave's direct grant appears here

| id      | workspace_id | user_id  | permission   | granted_by | expires_at       |
| ------- | ------------ | -------- | ------------ | ---------- | ---------------- |
| grant-1 | ws-abc       | 4 (Dave) | `tasks:read` | 1 (Alice)  | 2025-04-27 09:15 |

> The `loadPermissions()` SQL uses `UNION` to merge both sources. Dave has no role rows to join through, but the `UNION` half finds his direct grant. Result: Dave's permission set = `{ "tasks:read" }`.

---

## Stage 4 — Redis Permission Cache State

After each user's first authenticated request, their permission set is computed and cached.

**Redis**

| Key              | Value (Set)                                                                                                                                                                                                                            | TTL   |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| `perms:ws-abc:1` | `{ tasks:read, tasks:create, tasks:update, tasks:delete, tasks:assign, projects:read, projects:create, projects:update, projects:delete, members:invite, members:remove, members:update_role, workspace:settings, workspace:billing }` | 5 min |
| `perms:ws-abc:2` | `{ tasks:read, tasks:create, tasks:update, tasks:assign, projects:read }`                                                                                                                                                              | 5 min |
| `perms:ws-abc:3` | `{ tasks:read, projects:read }`                                                                                                                                                                                                        | 5 min |
| `perms:ws-abc:4` | `{ tasks:read }`                                                                                                                                                                                                                       | 5 min |

> This cache is what makes permission checks fast. The `hasPermission()` method does `permissionSet.has(permission)` — a single Set lookup. The DB query only runs on cache miss or after `invalidatePermissionCache()` is called.

---

## Stage 5 — Requests & Decisions

### Request A — Bob reads all tasks

```
GET /tasks
Authorization: Bearer <Bob's JWT>
```

**JwtAuthGuard** decodes Bob's JWT:

```json
{ "sub": 2, "workspaceId": "ws-abc", ... }
```

**PermissionsGuard** reads route metadata:

```
@RequirePermission(Permission.TASKS_READ)  →  required = ["tasks:read"]
```

Calls `hasPermission(userId: 2, workspaceId: 'ws-abc', 'tasks:read')`:

```
1. Redis GET perms:ws-abc:2  →  cache hit
2. Set.has("tasks:read")     →  true ✓
3. canActivate returns true
```

**Result: 200 OK** — Bob sees all tasks.

---

### Request B — Carol tries to delete task 99

```
DELETE /tasks/99
Authorization: Bearer <Carol's JWT>
```

**PermissionsGuard** reads route metadata:

```
@RequirePermission(Permission.TASKS_DELETE)  →  required = ["tasks:delete"]
```

Calls `hasPermission(userId: 3, workspaceId: 'ws-abc', 'tasks:delete')`:

```
1. Redis GET perms:ws-abc:3  →  cache hit
2. Set = { tasks:read, projects:read }
3. Set.has("tasks:delete")   →  false ✗
4. throw ForbiddenException("Missing required permission: tasks:delete")
```

**Result: 403 Forbidden** — Carol is blocked at the guard, the controller method is never called.

---

### Request C — Dave reads task 99

```
GET /tasks/99
Authorization: Bearer <Dave's JWT>
```

Calls `hasPermission(userId: 4, workspaceId: 'ws-abc', 'tasks:read')`:

```
1. Redis GET perms:ws-abc:4  →  cache miss (first request)
2. Run loadPermissions(4, 'ws-abc'):
   - workspace_members JOIN: no rows (Dave has no role)
   - UNION user_permission_grants: finds grant-1
   - expires_at (2025-04-27) > NOW() → included
   - Result: { "tasks:read" }
3. SET perms:ws-abc:4 = { tasks:read }  TTL=5min
4. Set.has("tasks:read")  →  true ✓
```

**Result: 200 OK** — Dave can read the task.

---

### Request D — Bob tries to delete task 99 (ABAC layer kicks in)

Bob is an `editor`. Editors do NOT have `tasks:delete`. But even if they did, the ABAC rule says only the creator or an admin can delete.

```
DELETE /tasks/99
Authorization: Bearer <Bob's JWT>
```

**PermissionsGuard** — `tasks:delete` not in Bob's set → **403 immediately.**

Bob never reaches the service layer. The ABAC check in `TasksService.deleteTask()` is only reached by users who already passed the permission guard (i.e., admins and owners).

> This is the two-layer model: the guard enforces the role-based boundary (who can even attempt this action), and the service enforces the resource-level boundary (who can act on this specific resource).

---

### Request E — Alice (admin/owner) deletes task 99

```
DELETE /tasks/99
Authorization: Bearer <Alice's JWT>
```

**PermissionsGuard**:

```
Set.has("tasks:delete")  →  true ✓  (Alice is owner, has all permissions)
```

**TasksService.deleteTask()** — ABAC layer:

```
task.createdBy = 2 (Bob)
requestingUserId = 1 (Alice)
task.createdBy !== requestingUserId  →  check admin fallback

hasPermission(1, 'ws-abc', 'tasks:delete')  →  true ✓  (Alice is owner)
→ deletion proceeds
```

**Result: 200 OK** — Alice deletes it via admin override.

---

## Stage 6 — Role Change (Bob Promoted to Admin)

Alice promotes Bob from `editor` to `admin`.

```sql
UPDATE workspace_members SET role_id = 3 WHERE workspace_id = 'ws-abc' AND user_id = 2;
```

Then immediately:

```
Redis: DEL perms:ws-abc:2
```

**`workspace_members` table** — only Bob's `role_id` changes

| id    | workspace_id | user_id   | role_id       | invited_by | joined_at        |
| ----- | ------------ | --------- | ------------- | ---------- | ---------------- |
| mem-1 | ws-abc       | 1 (Alice) | 4 (owner)     | NULL       | 2025-04-20 09:00 |
| mem-2 | ws-abc       | 2 (Bob)   | **3 (admin)** | 1          | 2025-04-20 09:05 |
| mem-3 | ws-abc       | 3 (Carol) | 1 (viewer)    | 1          | 2025-04-20 09:10 |

**Redis** — Bob's cache entry deleted, forcing a fresh DB load on his next request

| Key                  | Value                                   | TTL         |
| -------------------- | --------------------------------------- | ----------- |
| `perms:ws-abc:1`     | `{ ...all... }`                         | 5 min       |
| ~~`perms:ws-abc:2`~~ | ~~`{ tasks:read, tasks:create, ... }`~~ | **deleted** |
| `perms:ws-abc:3`     | `{ tasks:read, projects:read }`         | 5 min       |
| `perms:ws-abc:4`     | `{ tasks:read }`                        | 5 min       |

On Bob's next request, `loadPermissions()` re-runs and builds his new set:

```
{ tasks:read, tasks:create, tasks:update, tasks:delete, tasks:assign,
  projects:read, projects:create, projects:update, projects:delete,
  members:invite, members:remove }
```

> Changing one `role_id` cell + deleting one Redis key = instant permission change, no code deployment needed.

---

## Stage 7 — Custom Role for a Specific Workspace

Alice creates a custom `QA Tester` role in `ws-abc` — can read and update tasks, but cannot create or delete them.

```sql
-- 1. Create the custom role scoped to this workspace
INSERT INTO roles (workspace_id, name, is_system)
VALUES ('ws-abc', 'QA Tester', false);
-- Returns id: 5

-- 2. Assign the desired permissions to it
INSERT INTO role_permissions (role_id, permission_id) VALUES
  (5, 1),  -- tasks:read
  (5, 3),  -- tasks:update
  (5, 6);  -- projects:read
```

**`roles` table** — new row with `workspace_id` set

| id    | workspace_id | name          | is_system |
| ----- | ------------ | ------------- | --------- |
| 1     | NULL         | viewer        | true      |
| 2     | NULL         | editor        | true      |
| 3     | NULL         | admin         | true      |
| 4     | NULL         | owner         | true      |
| **5** | **ws-abc**   | **QA Tester** | **false** |

> `workspace_id` being set means this role is only available within `ws-abc`. Another workspace cannot reference role id 5. System roles (`workspace_id = NULL`) are available everywhere.

---

## Summary — Which Table Does What at Request Time

| Table / Key                 | When it is read                      | What it decides                                                     |
| --------------------------- | ------------------------------------ | ------------------------------------------------------------------- |
| `workspace_members.role_id` | On cache miss in `loadPermissions()` | Which role (and therefore which permissions) the user has           |
| `roles`                     | On cache miss — JOIN target          | Provides the role name and whether it is system or custom           |
| `role_permissions`          | On cache miss — JOIN target          | Which permission IDs belong to the role                             |
| `permissions.name`          | On cache miss — final JOIN           | Resolves permission ID to the string (e.g. `tasks:delete`)          |
| `user_permission_grants`    | On cache miss — UNION branch         | Adds any direct one-off permissions on top of the role set          |
| `Redis perms:{ws}:{user}`   | On every request                     | Short-circuits the DB join; returns the full permission Set in O(1) |
| `task.createdBy`            | In service layer (ABAC)              | Decides if this specific resource allows this specific user to act  |

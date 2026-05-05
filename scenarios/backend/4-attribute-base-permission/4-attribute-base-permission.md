## Question 5

### "Your platform allows users to invite teammates. An invited user should only access the resources they were explicitly granted — not everything in the workspace. How do you design a permission system flexible enough for this without it becoming a maintenance nightmare?"

---

### The Naive Solution

Add a `role` column to the `workspace_members` table with values like `owner`, `admin`, `member`, `viewer`. Check the role in each controller or service method.

```typescript
if (member.role !== "admin") {
  throw new ForbiddenException();
}
```

---

### Problems with the Naive Solution

**Roles are too coarse-grained.** A user might need to edit tasks but not delete them, or view reports but not invite others. A flat role system cannot express this without adding more and more roles — `editor`, `editor-no-delete`, `report-viewer`, etc. This explodes quickly.

**Hardcoded role checks scatter everywhere.** The `if role !== 'admin'` pattern ends up duplicated across dozens of controllers and services. When you need to change what `admin` can do, you hunt through the entire codebase.

**No resource-level granularity.** Roles apply to the entire workspace. You cannot say "user can edit task 42 but not task 43" — you can only say "user can edit all tasks" or "user can edit no tasks."

**Cannot model real-world requirements.** Real teams need things like: "only the person who created the task can delete it", or "contractor can access Project A but not Project B." Flat roles cannot express this cleanly.

---

### Production-Grade Solution

The right model is **RBAC (Role-Based Access Control)** for broad workspace-level permissions combined with **ABAC (Attribute-Based Access Control)** for resource-level rules. In practice this is implemented as a **permissions table with a guard that evaluates rules at request time.**

The design has four layers:

```
Layer 1: Actions          — what can be done (tasks:read, tasks:create, tasks:delete)
Layer 2: Roles            — named bundles of actions (viewer, editor, admin)
Layer 3: Assignments      — which user has which role in which workspace
Layer 4: Resource rules   — extra conditions checked at the resource level
                            ("only owner can delete", "only assignee can close")
```

#### Step 1 — Define Permissions as Granular Action Strings

Every protected operation in the system has a string identifier. These are the atomic units of the permission system.

```typescript
// src/permissions/permissions.enum.ts

export enum Permission {
  // Task permissions
  TASKS_READ = "tasks:read",
  TASKS_CREATE = "tasks:create",
  TASKS_UPDATE = "tasks:update",
  TASKS_DELETE = "tasks:delete",
  TASKS_ASSIGN = "tasks:assign",

  // Project permissions
  PROJECTS_READ = "projects:read",
  PROJECTS_CREATE = "projects:create",
  PROJECTS_UPDATE = "projects:update",
  PROJECTS_DELETE = "projects:delete",

  // Member management
  MEMBERS_INVITE = "members:invite",
  MEMBERS_REMOVE = "members:remove",
  MEMBERS_UPDATE_ROLE = "members:update_role",

  // Workspace settings
  WORKSPACE_SETTINGS = "workspace:settings",
  WORKSPACE_BILLING = "workspace:billing",
}
```

**Why strings instead of booleans per role?** You can add new permissions without changing the role definitions. You can assign individual permissions to users without a full role. You can check permissions programmatically and log exactly which permission was missing.

#### Step 2 — The Database Schema

```sql
-- The master list of permissions in the system
CREATE TABLE permissions (
  id          SERIAL PRIMARY KEY,
  name        VARCHAR(100) UNIQUE NOT NULL,  -- 'tasks:delete'
  description TEXT
);

-- Named roles are bundles of permissions
CREATE TABLE roles (
  id           SERIAL PRIMARY KEY,
  workspace_id UUID REFERENCES workspaces(id) ON DELETE CASCADE,
  -- workspace_id NULL = system-defined role (viewer, editor, admin)
  -- workspace_id set = custom role created by that workspace
  name         VARCHAR(100) NOT NULL,
  is_system    BOOLEAN DEFAULT FALSE
);

-- Many-to-many: each role has many permissions
CREATE TABLE role_permissions (
  role_id       INTEGER REFERENCES roles(id) ON DELETE CASCADE,
  permission_id INTEGER REFERENCES permissions(id) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_id)
);

-- Which user has which role in which workspace
CREATE TABLE workspace_members (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id      INTEGER REFERENCES users(id) ON DELETE CASCADE,
  role_id      INTEGER REFERENCES roles(id),
  invited_by   INTEGER REFERENCES users(id),
  joined_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (workspace_id, user_id)
);

-- Direct permission grants — bypass roles entirely for one-off overrides
-- e.g., "give this contractor access to tasks:read without giving them a full role"
CREATE TABLE user_permission_grants (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID REFERENCES workspaces(id),
  user_id      INTEGER REFERENCES users(id),
  permission   VARCHAR(100) NOT NULL,
  granted_by   INTEGER REFERENCES users(id),
  expires_at   TIMESTAMPTZ,   -- Optional: time-limited access
  UNIQUE (workspace_id, user_id, permission)
);
```

**Default system roles:**

| Role     | Permissions                                                                                    |
| -------- | ---------------------------------------------------------------------------------------------- |
| `viewer` | `tasks:read`, `projects:read`                                                                  |
| `editor` | All viewer permissions + `tasks:create`, `tasks:update`, `tasks:assign`                        |
| `admin`  | All editor permissions + `tasks:delete`, `projects:delete`, `members:invite`, `members:remove` |
| `owner`  | All permissions including `workspace:billing`, `members:update_role`                           |

#### Step 3 — The Permission Service

This service is the single source of truth for "can this user do this thing?" It checks both role-based permissions and direct grants.

```typescript
// src/permissions/permissions.service.ts

@Injectable()
export class PermissionsService {
  constructor(
    @InjectRepository(WorkspaceMember)
    private readonly membersRepo: Repository<WorkspaceMember>,
    @InjectRepository(UserPermissionGrant)
    private readonly grantsRepo: Repository<UserPermissionGrant>,
    @Inject(CACHE_MANAGER)
    private readonly cache: Cache,
  ) {}

  // Core method: does this user have this permission in this workspace?
  async hasPermission(
    userId: number,
    workspaceId: string,
    permission: Permission,
  ): Promise<boolean> {
    // Cache the full permission set per user per workspace.
    // Permission sets change rarely — cache for 5 minutes.
    // Invalidate when role changes or direct grants change.
    const cacheKey = `perms:${workspaceId}:${userId}`;
    let permissionSet = await this.cache.get<Set<string>>(cacheKey);

    if (!permissionSet) {
      permissionSet = await this.loadPermissions(userId, workspaceId);
      await this.cache.set(cacheKey, permissionSet, 5 * 60 * 1000);
    }

    return permissionSet.has(permission);
  }

  private async loadPermissions(
    userId: number,
    workspaceId: string,
  ): Promise<Set<string>> {
    // Single query that joins through workspace_members → roles → role_permissions
    // AND unions direct grants from user_permission_grants
    const results = await this.membersRepo.query(
      `
      SELECT p.name FROM workspace_members wm
      JOIN roles r ON r.id = wm.role_id
      JOIN role_permissions rp ON rp.role_id = r.id
      JOIN permissions p ON p.id = rp.permission_id
      WHERE wm.workspace_id = $1 AND wm.user_id = $2
 
      UNION
 
      SELECT permission AS name FROM user_permission_grants
      WHERE workspace_id = $1
        AND user_id = $2
        AND (expires_at IS NULL OR expires_at > NOW())
    `,
      [workspaceId, userId],
    );

    return new Set(results.map((r: any) => r.name));
  }

  // Invalidate cache when a user's permissions change
  async invalidatePermissionCache(
    userId: number,
    workspaceId: string,
  ): Promise<void> {
    await this.cache.del(`perms:${workspaceId}:${userId}`);
  }
}
```

#### Step 4 — The Permissions Guard

A NestJS guard that reads `@RequirePermission()` metadata from the route and checks it against the permission service.

```typescript
// src/permissions/require-permission.decorator.ts
import { SetMetadata } from "@nestjs/common";
import { Permission } from "./permissions.enum";

export const PERMISSION_KEY = "required_permission";

// Apply this decorator to any route that needs a permission check.
// e.g., @RequirePermission(Permission.TASKS_DELETE)
export const RequirePermission = (...permissions: Permission[]) =>
  SetMetadata(PERMISSION_KEY, permissions);
```

```typescript
// src/permissions/permissions.guard.ts
import {
  CanActivate,
  ExecutionContext,
  Injectable,
  ForbiddenException,
} from "@nestjs/common";
import { Reflector } from "@nestjs/core";
import { PermissionsService } from "./permissions.service";
import { PERMISSION_KEY } from "./require-permission.decorator";
import { Permission } from "./permissions.enum";

@Injectable()
export class PermissionsGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly permissionsService: PermissionsService,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const required = this.reflector.getAllAndOverride<Permission[]>(
      PERMISSION_KEY,
      [context.getHandler(), context.getClass()],
    );

    // If no @RequirePermission() decorator, do not enforce — guard passes
    if (!required || required.length === 0) return true;

    const request = context.switchToHttp().getRequest();
    const { userId, workspaceId } = request.user;
    // workspaceId comes from the JWT payload or a request header/param

    // Check ALL required permissions — user must have every one
    const checks = await Promise.all(
      required.map((permission) =>
        this.permissionsService.hasPermission(userId, workspaceId, permission),
      ),
    );

    if (checks.every(Boolean)) return true;

    // Log the denial for audit purposes — which permission was missing
    throw new ForbiddenException(
      `Missing required permission: ${required.join(", ")}`,
    );
  }
}
```

#### Step 5 — Using the System in Controllers

```typescript
// src/tasks/tasks.controller.ts

@ApiTags('tasks')
@ApiBearerAuth('access-token')
@UseGuards(JwtAuthGuard, PermissionsGuard)  // Both guards — auth first, then permission
@Controller('tasks')
export class TasksController {

  // Any workspace member with tasks:read can list tasks
  @Get()
  @RequirePermission(Permission.TASKS_READ)
  findAll() { ... }

  // Requires tasks:create — viewers cannot POST
  @Post()
  @RequirePermission(Permission.TASKS_CREATE)
  create(@Body() dto: CreateTaskDto) { ... }

  // Requires BOTH update AND assign — must have both to reassign
  @Patch(':id/assign')
  @RequirePermission(Permission.TASKS_UPDATE, Permission.TASKS_ASSIGN)
  assignTask(@Param('id') id: number, @Body() dto: AssignTaskDto) { ... }

  // Requires tasks:delete — only admins and owners
  @Delete(':id')
  @RequirePermission(Permission.TASKS_DELETE)
  remove(@Param('id') id: number) { ... }
}
```

#### Step 6 — Resource-Level Rules (ABAC Layer)

Some rules depend on the specific resource, not just the permission. "Only the task creator can delete it" cannot be expressed in a permission string alone — you need to load the resource and check attributes.

This layer sits in the service, not the guard:

```typescript
// src/tasks/tasks.service.ts

async deleteTask(taskId: number, requestingUserId: number): Promise<void> {
  const task = await this.tasksRepo.findOneBy({ id: taskId });
  if (!task) throw new NotFoundException();

  // ABAC rule: even if the user has tasks:delete permission,
  // only the creator OR an admin can delete.
  // Admin check is already handled by PermissionsGuard.
  // Creator check is a resource-level attribute check.
  if (task.createdBy !== requestingUserId) {
    // Check if they have admin-level permission as a fallback
    const isAdmin = await this.permissionsService.hasPermission(
      requestingUserId,
      task.workspaceId,
      Permission.TASKS_DELETE,
    );
    if (!isAdmin) {
      throw new ForbiddenException('Only the task creator or an admin can delete this task');
    }
  }

  await this.tasksRepo.remove(task);
}
```

#### How Permissions Change Without Code Deployment

Because permissions are rows in a database, workspace admins can:

- Create custom roles via `POST /roles` with any combination of permissions
- Grant individual permissions to specific users via `POST /user-permission-grants`
- Set time-limited access grants with an `expires_at` date
- Revoke access by deleting the grant or changing the role
  None of this requires code changes. The permission system is runtime-configurable.

#### Complete Request Flow

```
POST /tasks/42/assign
    |
    v
JwtAuthGuard
  → verify JWT → req.user = { userId: 7, workspaceId: 'ws-abc' }
    |
    v
PermissionsGuard
  → reads @RequirePermission(TASKS_UPDATE, TASKS_ASSIGN) from route
  → loads permission set from Redis cache (or DB if miss)
    → user 7 in workspace ws-abc has role 'editor'
    → editor has: tasks:read, tasks:create, tasks:update, tasks:assign ✓
  → both permissions present → canActivate returns true
    |
    v
TasksController.assignTask()
    |
    v
TasksService.assignTask()
  → load task → check resource-level rule (is assignee in same workspace?)
  → apply change
```

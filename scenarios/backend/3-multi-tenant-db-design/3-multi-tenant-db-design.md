## Question 4

### "You are designing a multi-tenant SaaS API where tenant A's data must never be accessible to tenant B, even if a developer makes a mistake in a query. How do you enforce tenant isolation at the data layer, not just at the application layer?"

---

### The Naive Solution

Add a `tenantId` column to every table and add `WHERE tenantId = :tenantId` to every query. Trust developers to always include this filter.

---

### Problems with the Naive Solution

**It relies entirely on developer discipline.** If one developer forgets the `WHERE tenantId = ?` clause on a single query — or uses a raw SQL query without it — a tenant's data is exposed. This has happened at major SaaS companies and resulted in significant data breaches.

**It is not enforceable at the database level.** The database has no idea about tenants — it will happily return all rows if you forget the filter.

**It does not scale as a codebase grows.** With dozens of tables and hundreds of queries, every new query is a potential isolation failure.

---

### Production-Grade Solution

Multi-tenant isolation must be enforced at a layer that cannot be bypassed by application code. There are three strategies with increasing levels of isolation.

#### The Three Isolation Models

```
Shared DB, Shared Schema     Shared DB, Separate Schema    Separate Database
        |                              |                           |
  tenantId column              Schema per tenant           DB per tenant
  on every table               (postgres schemas)          (separate RDS instances)
        |                              |                           |
  Low cost                    Medium cost                  High cost
  Lowest isolation            Good isolation               Strongest isolation
  Risk: missed WHERE clause   Enforced by schema context   No shared infrastructure
  Best for: SMB SaaS          Best for: mid-market         Best for: enterprise
```

#### Strategy 1 — Shared Schema with Row-Level Security (PostgreSQL RLS)

This is the most practical approach for most SaaS products. PostgreSQL's Row-Level Security feature enforces tenant isolation at the database engine level — below your application code.

**How RLS works:**

You define a policy on a table that says: "a row is only visible if its `tenant_id` matches a session variable I set." The database enforces this on every SELECT, INSERT, UPDATE, and DELETE — even raw SQL queries that forget the WHERE clause.

**Step 1 — Set up the tenant_id column and enable RLS**

```sql
-- Add tenant_id to every table
ALTER TABLE tasks ADD COLUMN tenant_id UUID NOT NULL;
ALTER TABLE users ADD COLUMN tenant_id UUID NOT NULL;

-- Enable Row-Level Security on each table
ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

-- Force RLS even for table owners (superusers bypass RLS by default — close this gap)
ALTER TABLE tasks FORCE ROW LEVEL SECURITY;
ALTER TABLE users FORCE ROW LEVEL SECURITY;
```

**Step 2 — Create the isolation policy**

```sql
-- This policy allows a row to be read ONLY IF
-- the row's tenant_id matches the current_setting('app.tenant_id')
-- which is a session-level variable your application sets.
CREATE POLICY tenant_isolation_policy ON tasks
  USING (tenant_id = current_setting('app.tenant_id')::UUID);

CREATE POLICY tenant_isolation_policy ON users
  USING (tenant_id = current_setting('app.tenant_id')::UUID);
```

**Step 3 — Set the tenant context at the start of every request**

This is the application-side piece. In a NestJS middleware, you read the tenant from the JWT and set the PostgreSQL session variable before any query runs.

```typescript
// src/tenancy/tenant-context.middleware.ts
import { Injectable, NestMiddleware } from "@nestjs/common";
import { DataSource } from "typeorm";

@Injectable()
export class TenantContextMiddleware implements NestMiddleware {
  constructor(private readonly dataSource: DataSource) {}

  async use(req: Request, res: Response, next: NextFunction) {
    // tenantId comes from the verified JWT — set in JwtStrategy.validate()
    const tenantId = (req as any).user?.tenantId;

    if (!tenantId) {
      return next(); // Public routes — no tenant context needed
    }

    // Set the PostgreSQL session variable.
    // Every subsequent query on this connection sees only this tenant's rows.
    await this.dataSource.query(
      `SET LOCAL app.tenant_id = '${tenantId}'`,
      // SET LOCAL only applies for the current transaction.
      // If connection pooling is used, this is reset when the connection
      // is returned to the pool — no bleed between requests.
    );

    next();
  }
}
```

**Step 4 — The critical connection pool consideration**

`SET LOCAL` scopes the variable to the current transaction. If you use `SET` instead, the variable persists on the connection and could bleed to the next request that reuses the same pooled connection. Always use `SET LOCAL` inside a transaction, or wrap the entire request in a transaction.

```typescript
// TypeORM: wrap every request in a transaction to ensure SET LOCAL works correctly
async findAllTasksForCurrentTenant(): Promise<Task[]> {
  return this.dataSource.transaction(async (manager) => {
    // SET LOCAL is valid here because we are inside a transaction
    await manager.query(`SET LOCAL app.tenant_id = '${this.tenantId}'`);
    // This query has NO WHERE clause for tenant_id — RLS enforces it automatically
    return manager.find(Task);
  });
}
```

**Proof that it works — even without WHERE clause:**

```sql
-- Developer forgets the tenant filter entirely
SELECT * FROM tasks;

-- PostgreSQL RLS silently applies the policy:
-- Equivalent to: SELECT * FROM tasks WHERE tenant_id = current_setting('app.tenant_id')
-- Tenant B's rows are simply invisible — not an error, just absent
```

#### Strategy 2 — Schema-per-Tenant

Each tenant gets their own PostgreSQL schema. The table structure is identical across schemas — only the data is isolated.

```
database: taskflow
  schema: tenant_abc
    tables: tasks, users, labels
  schema: tenant_xyz
    tables: tasks, users, labels
  schema: public
    tables: tenants (master registry)
```

```typescript
// src/tenancy/schema-tenant.middleware.ts

async use(req: Request, res: Response, next: NextFunction) {
  const tenantId = (req as any).user?.tenantId;
  const schemaName = `tenant_${tenantId}`;

  // Set the search_path so all unqualified table references resolve to this tenant's schema
  await this.dataSource.query(`SET LOCAL search_path TO ${schemaName}, public`);

  next();
}
```

```sql
-- With search_path set to 'tenant_abc', this query automatically hits tenant_abc.tasks
SELECT * FROM tasks;
-- Not public.tasks, not tenant_xyz.tasks — only tenant_abc.tasks
```

**Trade-offs of schema-per-tenant:**

- Stronger isolation than RLS — each schema is a hard namespace boundary
- Schema migration complexity: running a migration means running it on every tenant's schema
- PostgreSQL supports thousands of schemas in one database — scales to thousands of tenants
- Cannot accidentally cross-schema with a bug — `SELECT * FROM tasks` is physically a different table per tenant

#### Strategy 3 — Separate Database per Tenant (Enterprise Tier)

The most isolated and the most expensive. Each tenant has their own database instance (e.g., separate RDS instance). Used for enterprise customers with strict compliance requirements (SOC2, HIPAA, financial regulations).

```typescript
// src/tenancy/tenant-datasource.factory.ts

@Injectable()
export class TenantDataSourceFactory {
  private readonly sources = new Map<string, DataSource>();

  async getDataSource(tenantId: string): Promise<DataSource> {
    if (this.sources.has(tenantId)) {
      return this.sources.get(tenantId);
    }

    // Load tenant-specific DB credentials from a secrets manager (never hardcoded)
    const tenantConfig = await this.secretsManager.getTenantDbConfig(tenantId);

    const source = new DataSource({
      type: "postgres",
      host: tenantConfig.host, // tenant-specific RDS endpoint
      database: tenantConfig.dbName,
      username: tenantConfig.user,
      password: tenantConfig.password,
    });

    await source.initialize();
    this.sources.set(tenantId, source);
    return source;
  }
}
```

#### Choosing the Right Strategy

| Factor                 | Shared Schema + RLS | Schema per Tenant | Separate DB         |
| ---------------------- | ------------------- | ----------------- | ------------------- |
| Number of tenants      | Thousands           | Hundreds          | Tens                |
| Compliance requirement | Standard            | Medium            | High (HIPAA, SOC2)  |
| Data isolation risk    | Low (RLS enforces)  | Very low          | Zero                |
| Migration complexity   | Simple              | Complex           | Very complex        |
| Cost                   | Low                 | Low–medium        | High                |
| Query performance      | Shared resources    | Shared resources  | Dedicated resources |

#### Complete Request Flow with RLS

```
Incoming request
    |
    v
JwtStrategy.validate()
    → Decode JWT → extract tenantId: "abc-123"
    → Attach to req.user
    |
    v
TenantContextMiddleware
    → SET LOCAL app.tenant_id = 'abc-123'
    → All subsequent queries on this connection are scoped
    |
    v
TasksService.findAll()
    → this.tasksRepo.find()         ← No tenant filter in code
    → SELECT * FROM tasks           ← PostgreSQL applies RLS policy
    → WHERE tenant_id = 'abc-123'   ← Injected by database engine
    → Returns only tenant abc-123's tasks
    |
    v
Developer forgets the filter:
    → this.tasksRepo.find()         ← Still no tenant filter
    → SELECT * FROM tasks           ← RLS still applies
    → Returns only abc-123's tasks  ← Tenant isolation preserved
```

#### Key Interview Points to Mention

- RLS enforcement is at the database engine level — it cannot be bypassed by application code, ORM bugs, or developer mistakes.
- Always use `SET LOCAL` (not `SET`) to scope the tenant context to a transaction — prevents bleed across pooled connections.
- `FORCE ROW LEVEL SECURITY` closes the superuser bypass gap — without it, database owner connections ignore RLS.
- For a SaaS product launching, start with Shared Schema + RLS. If an enterprise customer requires data isolation, provision them a separate schema or database and abstract the connection selection behind a factory.
- The schema-per-tenant approach makes compliance audits straightforward — you can point to a tenant's schema and say "this is all of their data."

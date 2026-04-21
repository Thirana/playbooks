# NestJS Database Integration Core Concepts
Purpose: This note explains the core TypeORM ideas behind the TaskFlow database setup before the full implementation walkthrough.

## Related Notes
- [2. Full DB Integration Learning Guide](./2_db_integration_learning_guide.md)
- [3. NestJS TypeORM Runtime Flow](./3_nestjs_typeorm_runtime_flow.md)
- [4. DB Integration Revision Cheatsheet](./4_db_integration_revision_cheatsheet.md)

## 1. ORM, TypeORM, and `@nestjs/typeorm`
An ORM maps classes to database tables and objects to rows.

Without an ORM:
```sql
SELECT * FROM users WHERE id = 1;
```

With TypeORM:
```typescript
await usersRepository.findOneBy({ id: 1 });
```

TypeORM gives you:
- entities
- repositories
- relations
- QueryBuilder
- migrations
- transactions

`@nestjs/typeorm` is the NestJS integration layer. It adds:
- `TypeOrmModule.forRoot()` / `forRootAsync()`
- `TypeOrmModule.forFeature()`
- `@InjectRepository()`
- DI-friendly access to `DataSource`

Short rule:
- TypeORM does the database work
- `@nestjs/typeorm` makes it fit NestJS modules and providers

## 2. The main building blocks
### Entity
A class mapped to a table.

Examples:
- `User` -> `users`
- `Task` -> `tasks`
- `Label` -> `labels`

### Repository
A per-entity data-access object.

Examples:
- `Repository<User>`
- `Repository<Task>`

Use it for normal CRUD work.

### DataSource
The configured database connection entry point.

Use it for:
- lower-level DB access
- `QueryRunner` creation
- transaction setup

### EntityManager
A general-purpose API that can work across multiple entities.

Inside transactions, the transaction-bound manager matters because all writes must use the same connection.

### QueryRunner
One dedicated DB connection with explicit transaction control.

Typical lifecycle:
- `connect()`
- `startTransaction()`
- `commitTransaction()` or `rollbackTransaction()`
- `release()`

Fast rule:
- normal CRUD -> repository
- explicit transaction boundary -> `QueryRunner`

## 3. Repository pattern
The repository pattern keeps service code free of raw SQL.

Typical flow:
1. Register entities with `forFeature()`.
2. Inject repositories with `@InjectRepository(Entity)`.
3. Use `find`, `findOne`, `save`, `delete`, or QueryBuilder methods.

This keeps services focused on business logic instead of hand-written query plumbing.

## 4. Relation mental model
### `@OneToOne`
One row maps to one row.

### `@OneToMany`
One row maps to many rows.
Example: one user has many tasks.

### `@ManyToOne`
Many rows map to one row.
Example: many tasks belong to one user.

### `@ManyToMany`
Many rows map to many rows.
Example: tasks and labels.

### Owning side
For `@ManyToOne` / `@OneToMany`, the `@ManyToOne` side owns the foreign key.

For `@ManyToMany`, only one side gets `@JoinTable()`.

Short rule:
- `@ManyToOne` owns the foreign key
- `@JoinTable()` appears on exactly one side

## 5. Why `userId` and `select: false` both matter
Keeping both:
- `user: User`
- `userId: number`

is practical because ownership checks and filtered queries often only need the foreign key.

`select: false` is useful for sensitive fields:
```typescript
@Column({ select: false })
password: string;
```

That means:
- normal queries hide the field
- special queries must explicitly re-select it

Example:
```typescript
createQueryBuilder("user").addSelect("user.password")
```

## 6. `autoLoadEntities`
`autoLoadEntities: true` means entities registered in feature modules are automatically included in the root TypeORM configuration.

This keeps `AppModule` cleaner because you do not have to list every entity manually.

## 7. `synchronize` vs migrations
### `synchronize: true`
TypeORM compares entities to the live schema at startup and changes the database automatically.

Good for:
- quick local experimentation

Dangerous for:
- production

### Migrations
Versioned schema changes with explicit `up()` and `down()` methods.

Good for:
- controlled deploys
- reviewable schema changes
- rollback capability
- production safety

Fast rule:
- local experimentation may use `synchronize`
- production should use migrations

## 8. `findOne()` vs `findOneBy()` and when QueryBuilder is needed
Use `findOneBy()` for simple condition lookups:
```typescript
await usersRepository.findOneBy({ id: 1 });
```

Use `findOne()` when you need richer options such as `relations`:
```typescript
await tasksRepository.findOne({
  where: { id, userId },
  relations: ["labels"],
});
```

Use QueryBuilder when repository helpers are not enough:
- joins
- more complex filters
- dynamic query construction
- SQL-like control

Always parameterize values:
```typescript
.where("task.userId = :userId", { userId })
```

## 9. What a transaction solves
Transactions make multi-step writes atomic.

Example:
- create a task
- create missing labels
- assign labels

If one step fails, none of the changes should remain committed.

That is why the whole workflow belongs inside one transaction.

Important rule:
- use `queryRunner.manager` for all work inside the transaction
- always call `queryRunner.release()` in `finally`

## 10. Why the CLI `DataSource` file exists
The TypeORM CLI runs outside the NestJS DI container, so it needs a standalone `DataSource` file.

Its job is to:
- load env values
- point to entity files
- point to migration files
- power `migration:generate`, `migration:run`, and `migration:revert`

## 11. Concept checkpoints
If you can answer these quickly, the foundation is solid:
- What is the difference between `forRootAsync()` and `forFeature()`?
- Why does `@ManyToOne` own the foreign key?
- Why keep `userId` when `task.user` already exists?
- When do you need QueryBuilder?
- Why is `synchronize: true` risky in production?
- Why must `queryRunner.release()` always run?

If you want the startup and request lifecycle next, use [3. NestJS TypeORM Runtime Flow](./3_nestjs_typeorm_runtime_flow.md).

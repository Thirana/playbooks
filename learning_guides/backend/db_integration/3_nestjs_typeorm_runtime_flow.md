# NestJS TypeORM Runtime Flow
Purpose: This note explains what happens at runtime when NestJS boots TypeORM, injects repositories, loads relations, runs transactions, and uses the migration CLI.

## Related Notes
- [1. DB Integration Core Concepts](./1_db_core_concepts.md)
- [2. Full DB Integration Learning Guide](./2_db_integration_learning_guide.md)
- [4. DB Integration Revision Cheatsheet](./4_db_integration_revision_cheatsheet.md)

## TaskFlow setup used in this note
Assume the app has:
- `User`, `Task`, and `Label` entities
- `TypeOrmModule.forRootAsync()` in the root module
- `TypeOrmModule.forFeature()` in feature modules
- repositories injected into services
- a transaction-based `createWithLabels()` flow
- a CLI `DataSource` for migrations

## 1. High-level lifecycle
```text
Startup
  -> config loads
  -> TypeORM config resolves
  -> entities register
  -> repositories become injectable

Request flow
  -> controller calls service
  -> service uses repository or QueryBuilder
  -> relations load if requested
  -> transaction commits or rolls back

Migration flow
  -> CLI DataSource loads
  -> migration is generated or run
```

## 2. Startup wiring flow
1. NestJS bootstraps the app.
2. `ConfigModule` loads app and database config.
3. `TypeOrmModule.forRootAsync()` injects `ConfigService`.
4. The factory builds the PostgreSQL config.
5. `autoLoadEntities: true` collects entities registered in feature modules.
6. TypeORM initializes the connection pool.

Why this matters:
- credentials are not hardcoded
- entity registration stays modular
- startup can fail early if config is missing

## 3. Repository registration flow
1. `UsersModule` imports `TypeOrmModule.forFeature([User])`.
2. `TasksModule` imports `TypeOrmModule.forFeature([Task, Label])`.
3. Nest registers repository DI tokens.
4. Services can now inject those repositories with `@InjectRepository(...)`.

If `forFeature()` is missing, repository injection fails.

## 4. Normal request-to-repository flow
1. A controller calls a service method.
2. The service uses an injected repository.
3. TypeORM turns the repository call into SQL.
4. PostgreSQL executes it.
5. TypeORM maps rows back into entity-shaped objects.

Example:
```typescript
await usersRepository.findOneBy({ id: 1 });
```

## 5. Relation loading and hidden-column flow
Relations are not loaded unless you ask for them.

Example:
```typescript
await tasksRepository.findOne({
  where: { id, userId },
  relations: ["labels"],
});
```

Use `findOne()` rather than `findOneBy()` when `relations` are needed.

For hidden fields like `password`:
1. `select: false` removes the column from normal queries.
2. A special query must opt back in with `addSelect("user.password")`.

## 6. Transaction flow with `QueryRunner`
1. `createWithLabels()` asks `DataSource` for a `QueryRunner`.
2. `connect()` acquires a connection.
3. `startTransaction()` begins the transaction.
4. The task and labels are created through `queryRunner.manager`.
5. `commitTransaction()` persists all changes on success.
6. `rollbackTransaction()` discards them on failure.
7. `release()` returns the connection to the pool.

Key rule:
- all transaction work must use the transaction-bound manager

## 7. QueryBuilder flow
Use QueryBuilder when repository helpers are too limited.

Typical flow:
1. start with `createQueryBuilder("task")`
2. add joins, filters, and order
3. parameterize values
4. execute and map results

Safe pattern:
```typescript
.where("task.userId = :userId", { userId })
```

## 8. Migration CLI flow
Migration commands run outside NestJS.

Flow:
1. The CLI loads `src/database/data-source.ts`.
2. That file loads env values with `dotenv`.
3. The CLI resolves entities and migration paths.
4. `migration:generate` compares entities with the current schema.
5. `migration:run` applies pending migrations.
6. `migration:revert` rolls back the last one.

## 9. Common failure points
| Symptom | Likely cause |
| --- | --- |
| Nest cannot resolve a repository dependency | entity missing from `forFeature()` |
| Relation data is missing | query did not include `relations` or a join |
| Password is undefined | `select: false` column was not re-selected |
| Transaction partly applies changes | queries escaped `queryRunner.manager` |
| App and schema disagree | migrations were not run or `synchronize` hid drift locally |
| App hangs under load | `queryRunner.release()` was forgotten |

## 10. Debugging checklist
1. Is `forRootAsync()` reading the correct config values?
2. Are entities registered with `forFeature()` in the right modules?
3. Are relation queries using `findOne()` or QueryBuilder instead of `findOneBy()`?
4. Are hidden columns explicitly re-selected when needed?
5. If using a transaction, are all queries going through `queryRunner.manager`?
6. Is `queryRunner.release()` guaranteed in `finally`?
7. Are migrations in sync with the entities?

Use this note for startup and request lifecycle narration. Use [4. DB Integration Revision Cheatsheet](./4_db_integration_revision_cheatsheet.md) when you only need the compressed version.

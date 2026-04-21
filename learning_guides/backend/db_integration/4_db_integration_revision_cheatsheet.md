# DB Integration Revision Cheatsheet: NestJS + TypeORM
Purpose: This is the shortest note in the set. Use it for quick recall, interview prep, and fast implementation review.

## Related Notes
- [1. DB Integration Core Concepts](./1_db_core_concepts.md)
- [2. Full DB Integration Learning Guide](./2_db_integration_learning_guide.md)
- [3. NestJS TypeORM Runtime Flow](./3_nestjs_typeorm_runtime_flow.md)

## Memorize These First
- entities map classes to tables
- `forRootAsync()` sets up the DB connection
- `forFeature()` makes repositories injectable
- `@ManyToOne` owns the foreign key
- `@JoinTable()` appears on only one side of many-to-many
- `select: false` hides sensitive columns by default
- transactions use `QueryRunner`
- production schema changes use migrations, not `synchronize`

## Quick Facts
- TypeORM is the ORM
- `@nestjs/typeorm` is the NestJS integration layer
- repositories handle normal CRUD
- QueryBuilder handles more complex queries
- `DataSource` is the entry point to lower-level DB APIs
- `QueryRunner` gives explicit transaction control on one connection

## Relation Rules
| Relation | Rule to remember |
| --- | --- |
| `@OneToMany` / `@ManyToOne` | `@ManyToOne` owns the foreign key |
| `@ManyToMany` | only one side gets `@JoinTable()` |
| relation + `userId` | keeping both is practical |
| hidden fields | `select: false` means opt back in explicitly |

## Repository Reminders
| Method | Use it when |
| --- | --- |
| `find()` | fetch many rows |
| `findOneBy()` | simple condition lookup |
| `findOne()` | richer lookup, especially with `relations` |
| `create()` | build entity in memory |
| `save()` | insert or update |
| `update()` | direct partial update |
| `remove()` | delete loaded entity |
| `delete()` | direct delete |
| `createQueryBuilder()` | advanced queries |

## Transaction and migration rules
- create `QueryRunner` from `DataSource`
- `connect()`
- `startTransaction()`
- use `queryRunner.manager`
- `commitTransaction()` or `rollbackTransaction()`
- `release()` in `finally`

Commands:
```bash
npm run migration:generate -- migrations/CreateUsersTable
npm run migration:run
npm run migration:revert
```

## Main API surface
| Item | Job |
| --- | --- |
| `TypeOrmModule.forRootAsync()` | root connection setup |
| `TypeOrmModule.forFeature()` | feature-level entity registration |
| `@InjectRepository(Entity)` | repository injection |
| `DataSource` | low-level DB access and QueryRunner creation |
| `QueryRunner` | manual transaction control |
| `createQueryBuilder()` | advanced query construction |

## Common mistakes
- forgetting `forFeature()`
- using `findOneBy()` when relations are needed
- expecting a `select: false` column to appear automatically
- forgetting `queryRunner.release()`
- mixing normal repositories into a transaction instead of using `queryRunner.manager`
- using `synchronize: true` in production
- interpolating raw values into QueryBuilder strings

## Interview flash answers
**`forRootAsync()` vs `forFeature()`**
- `forRootAsync()` sets up the connection
- `forFeature()` registers repositories for one module

**`findOne()` vs `findOneBy()`**
- `findOneBy()` is simpler
- `findOne()` is for richer options like `relations`

**Why use migrations instead of `synchronize` in production?**
- because schema changes must be explicit, reviewable, and safe

## Last-minute recall
- entities define tables
- repositories do normal CRUD
- QueryBuilder handles advanced queries
- `QueryRunner` handles transactions
- migrations change schema safely

# NestJS Caching — Redis and `cache-manager`

Purpose: This is the long-form implementation guide for adding caching to a NestJS application with Redis and `cache-manager`.

## Related Notes

- [1. Cache Core Concepts](./1_cache_core_concepts.md)
- [3. NestJS Cache Runtime Flow](./3_nestjs_cache_runtime_flow.md)
- [4. Cache Revision Cheatsheet](./4_cache_revision_cheatsheet.md)

---

## The Developer Requirement

TaskFlow has three caching problems:

- `GET /tasks` is a frequent heavy read that should not hit PostgreSQL every time
- `GET /users/:id` repeats the same user lookup many times per minute
- task create and update operations must invalidate stale task-list cache immediately

The solution is a cache layer that sits in front of repeated reads and is invalidated when writes change the data.

---

## How To Use This Note

- Read this file for the full implementation walkthrough.
- Use [1. Cache Core Concepts](./1_cache_core_concepts.md) for the mental model first.
- Use [3. NestJS Cache Runtime Flow](./3_nestjs_cache_runtime_flow.md) for lifecycle and debugging.
- Use [4. Cache Revision Cheatsheet](./4_cache_revision_cheatsheet.md) for quick revision.

---

## Part 1: Package setup

### Install dependencies

```bash
npm install --save @nestjs/cache-manager cache-manager
npm install --save @keyv/redis keyv cacheable
```

Why these packages exist:

- `@nestjs/cache-manager` integrates cache support into NestJS
- `cache-manager` provides the cache API surface
- `@keyv/redis` gives a Redis-backed store in the newer Keyv-style setup
- `cacheable` provides the in-memory Keyv store used for L1 caching

### Suggested file layout

```text
src/
  cache/
    http-cache.interceptor.ts
  tasks/
    tasks.controller.ts
    tasks.service.ts
  users/
    users.service.ts
  app.module.ts
```

---

## Part 2: Basic module setup

### Development setup: in-memory only

If you just want caching locally, start with the global in-memory cache.

**`src/app.module.ts`**

```typescript
import { Module } from "@nestjs/common";
import { CacheModule } from "@nestjs/cache-manager";

@Module({
  imports: [
    CacheModule.register({
      isGlobal: true,
      ttl: 5 * 60 * 1000,
    }),
  ],
})
export class AppModule {}
```

Notes:

- `isGlobal: true` means you do not need to import `CacheModule` in every feature module
- TTL here is milliseconds
- this cache is local to one process

### Production setup: L1 memory + L2 Redis

For real deployments, use async registration so Redis config comes from env values.

**`src/app.module.ts`**

```typescript
import { Module } from "@nestjs/common";
import { CacheModule } from "@nestjs/cache-manager";
import { ConfigModule, ConfigService } from "@nestjs/config";
import KeyvRedis from "@keyv/redis";
import { Keyv } from "keyv";
import { KeyvCacheableMemory } from "cacheable";

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    CacheModule.registerAsync({
      isGlobal: true,
      inject: [ConfigService],
      useFactory: async (configService: ConfigService) => {
        const redisUrl = `redis://${configService.get("REDIS_HOST", "localhost")}:${configService.get("REDIS_PORT", 6379)}`;

        return {
          stores: [
            new Keyv({
              store: new KeyvCacheableMemory({
                ttl: 5 * 60 * 1000,
                lruSize: 1000,
              }),
            }),
            new Keyv({
              store: new KeyvRedis(redisUrl),
            }),
          ],
          ttl: 5 * 60 * 1000,
        };
      },
    }),
  ],
})
export class AppModule {}
```

**`.env`**

```text
REDIS_HOST=localhost
REDIS_PORT=6379
```

Why this shape is useful:

- L1 memory handles hottest repeated reads inside one instance
- L2 Redis shares cache across instances
- `registerAsync()` keeps Redis connection details in config instead of hardcoding them

---

## Part 3: Auto-caching with `CacheInterceptor`

Use the interceptor when a `GET` endpoint can safely cache the full HTTP response.

By default:

- only `GET` responses are cached
- the request URL becomes the cache key
- the response is cached after the handler runs

### Route-level example

**`src/tasks/tasks.controller.ts`**

```typescript
import { Controller, Get, UseInterceptors } from "@nestjs/common";
import {
  CacheInterceptor,
  CacheKey,
  CacheTTL,
} from "@nestjs/cache-manager";

@Controller("tasks")
export class TasksController {
  @Get()
  @UseInterceptors(CacheInterceptor)
  async findAll() {
    return this.tasksService.findAll();
  }

  @Get("stats")
  @UseInterceptors(CacheInterceptor)
  @CacheKey("task-stats")
  @CacheTTL(60 * 1000)
  async getStats() {
    return this.tasksService.getStats();
  }
}
```

What these decorators do:

- `@UseInterceptors(CacheInterceptor)` turns on auto-caching for that route
- `@CacheKey()` overrides the default URL-based key
- `@CacheTTL()` overrides the default TTL for that route

### Global interceptor registration

If you want broad response caching for many `GET` endpoints, register the interceptor globally.

**`src/app.module.ts`**

```typescript
import { Module } from "@nestjs/common";
import { APP_INTERCEPTOR } from "@nestjs/core";
import { CacheModule, CacheInterceptor } from "@nestjs/cache-manager";

@Module({
  imports: [CacheModule.register({ isGlobal: true, ttl: 5 * 60 * 1000 })],
  providers: [
    {
      provide: APP_INTERCEPTOR,
      useClass: CacheInterceptor,
    },
  ],
})
export class AppModule {}
```

Global caching is convenient, but you still need to think carefully about keys for authenticated routes.

---

## Part 4: Custom `HttpCacheInterceptor` for per-user keys

The default interceptor key is usually just the URL. That is dangerous for authenticated endpoints.

Problem:

- user 42 requests `GET /tasks`
- user 91 also requests `GET /tasks`
- same URL, different data

Fix:

- override `trackBy()`
- include the user id in the generated cache key

**`src/cache/http-cache.interceptor.ts`**

```typescript
import { CacheInterceptor, CACHE_KEY_METADATA } from "@nestjs/cache-manager";
import { ExecutionContext, Injectable } from "@nestjs/common";

@Injectable()
export class HttpCacheInterceptor extends CacheInterceptor {
  trackBy(context: ExecutionContext): string | undefined {
    const request = context.switchToHttp().getRequest();

    if (request.method !== "GET") {
      return undefined;
    }

    const explicitKey = this.reflector.get(
      CACHE_KEY_METADATA,
      context.getHandler(),
    );

    const userId = request.user?.userId;
    const baseKey = explicitKey || request.url;

    return userId ? `user:${userId}:${baseKey}` : baseKey;
  }
}
```

Examples of generated keys:

- `user:42:/tasks`
- `user:42:/tasks?status=open`
- `task-stats` for a public route with an explicit custom key

Register it globally instead of the default interceptor:

```typescript
{
  provide: APP_INTERCEPTOR,
  useClass: HttpCacheInterceptor,
}
```

This is the correct fix for the cross-user cache leak problem.

---

## Part 5: Manual caching with `CACHE_MANAGER`

Use manual caching when you need cache-aside logic inside the service layer.

### Example: user profile cache

**`src/users/users.service.ts`**

```typescript
import {
  Inject,
  Injectable,
  NotFoundException,
} from "@nestjs/common";
import { CACHE_MANAGER } from "@nestjs/cache-manager";
import { Cache } from "cache-manager";
import { InjectRepository } from "@nestjs/typeorm";
import { Repository } from "typeorm";
import { User } from "./user.entity";

@Injectable()
export class UsersService {
  constructor(
    @InjectRepository(User)
    private readonly usersRepository: Repository<User>,
    @Inject(CACHE_MANAGER)
    private readonly cacheManager: Cache,
  ) {}

  private userCacheKey(userId: number): string {
    return `user:${userId}`;
  }

  async findById(userId: number): Promise<User> {
    const cacheKey = this.userCacheKey(userId);

    const cached = await this.cacheManager.get<User>(cacheKey);
    if (cached) {
      return cached;
    }

    const user = await this.usersRepository.findOneBy({ id: userId });
    if (!user) {
      throw new NotFoundException(`User ${userId} not found`);
    }

    await this.cacheManager.set(cacheKey, user, 10 * 60 * 1000);
    return user;
  }

  async updateAvatar(userId: number, avatarUrl: string): Promise<void> {
    await this.usersRepository.update(userId, { avatarUrl });
    await this.cacheManager.del(this.userCacheKey(userId));
  }
}
```

Why this is cache-aside:

1. try cache first
2. on miss, query database
3. store the fresh value
4. invalidate after writes

### Example: task list cache with invalidation

**`src/tasks/tasks.service.ts`**

```typescript
import { Inject, Injectable } from "@nestjs/common";
import { CACHE_MANAGER } from "@nestjs/cache-manager";
import { Cache } from "cache-manager";
import { InjectRepository } from "@nestjs/typeorm";
import { Repository } from "typeorm";
import { Task } from "./task.entity";

@Injectable()
export class TasksService {
  constructor(
    @InjectRepository(Task)
    private readonly tasksRepository: Repository<Task>,
    @Inject(CACHE_MANAGER)
    private readonly cacheManager: Cache,
  ) {}

  private taskListKey(userId: number): string {
    return `tasks:list:${userId}`;
  }

  private taskDetailKey(taskId: number): string {
    return `tasks:detail:${taskId}`;
  }

  async findAllForUser(userId: number): Promise<Task[]> {
    const cacheKey = this.taskListKey(userId);
    const cached = await this.cacheManager.get<Task[]>(cacheKey);

    if (cached) {
      return cached;
    }

    const tasks = await this.tasksRepository.find({
      where: { userId },
      relations: ["labels"],
      order: { createdAt: "DESC" },
    });

    await this.cacheManager.set(cacheKey, tasks, 5 * 60 * 1000);
    return tasks;
  }

  async createTask(userId: number, data: CreateTaskDto): Promise<Task> {
    const task = this.tasksRepository.create({ ...data, userId });
    const saved = await this.tasksRepository.save(task);

    await this.cacheManager.del(this.taskListKey(userId));
    return saved;
  }

  async updateTask(
    taskId: number,
    userId: number,
    data: Partial<Task>,
  ): Promise<Task> {
    const task = await this.findOne(taskId, userId);
    Object.assign(task, data);

    const saved = await this.tasksRepository.save(task);

    await this.cacheManager.del(this.taskListKey(userId));
    await this.cacheManager.del(this.taskDetailKey(taskId));

    return saved;
  }
}
```

The key idea is not just storing data. The important part is deleting every cache entry that becomes stale after a write.

---

## Part 6: Key design and TTL strategy

### Naming convention

Use a predictable colon-separated scheme:

```text
resource:identifier:variant
```

Examples:

- `user:42`
- `user:42:profile`
- `tasks:list:42`
- `tasks:list:42:open`
- `tasks:detail:17`
- `stats:tasks:global`

### TTL guidance

| Data Type | Suggested TTL | Why |
| --- | --- | --- |
| User profile | 10 minutes | changes infrequently |
| Task list | 5 minutes | frequent reads, invalidate on writes |
| Task detail | 5 minutes | invalidate on update or delete |
| Label list | 60 minutes | rarely changes |
| Dashboard stats | 1 minute | small staleness is acceptable |
| Health check | no cache | must stay live |

Guideline:

- use shorter TTL for volatile data
- combine TTL with invalidation for correctness
- do not use `0` casually

---

## Part 7: Production reminders

- always namespace keys for authenticated routes
- always invalidate affected keys after create, update, and delete
- keep cache key generation centralized in helper methods where possible
- use env-driven Redis config, not hardcoded connection values
- do not cache mutation responses
- do not rely on cache for correctness; the database path must still work
- be careful with routes using `@Res()` because `CacheInterceptor` will not transparently cache them
- prefer explicit TTLs instead of permanent entries

### Common interview questions

**What is the difference between `CacheInterceptor` and `CACHE_MANAGER`?**

- `CacheInterceptor` is declarative and caches whole HTTP responses
- `CACHE_MANAGER` is imperative and is used directly inside services for cache-aside and fine-grained invalidation

**How do you handle cache invalidation?**

- after any write, delete every cache key that may now contain stale data so the next read repopulates the cache

**Why is URL-only caching dangerous for authenticated endpoints?**

- because different users can share the same URL but should never share the same cached response

**What happens if Redis is down?**

- the cache layer should degrade gracefully and the app should fall back to the normal database path

---

## Quick Setup Cheat Sheet

```typescript
// AppModule
CacheModule.registerAsync({
  isGlobal: true,
  useFactory: async () => ({
    ttl: 5 * 60 * 1000,
    stores: [/* L1 memory, L2 Redis */],
  }),
});

// Route caching
@UseInterceptors(CacheInterceptor)
@CacheKey("task-stats")
@CacheTTL(60 * 1000)

// Manual service caching
const cached = await this.cacheManager.get<Type>(key);
if (cached) return cached;

await this.cacheManager.set(key, value, ttl);
await this.cacheManager.del(key);
```

## Quick File Map

| File | Main responsibility |
| --- | --- |
| `app.module.ts` | register cache globally, configure L1 and L2 stores |
| `cache/http-cache.interceptor.ts` | build safe per-user HTTP cache keys |
| `users/users.service.ts` | manual cache-aside for user lookups |
| `tasks/tasks.service.ts` | manual cache-aside plus invalidation on writes |
| `tasks/tasks.controller.ts` | route-level caching decorators |

## Final Revision Anchors

If you are revising quickly, remember this sequence:

1. choose route caching or service caching
2. configure cache store and TTL
3. design stable keys
4. scope authenticated keys per user
5. invalidate related keys after writes

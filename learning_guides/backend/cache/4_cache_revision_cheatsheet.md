# Cache Revision Cheatsheet

Purpose: This is the shortest note in the set. Use it for quick recall, interview prep, and fast implementation review.

## Related Notes

- [1. Cache Core Concepts](./1_cache_core_concepts.md)
- [2. Full Cache Learning Guide](./2_cache_learning_guide.md)
- [3. NestJS Cache Runtime Flow](./3_nestjs_cache_runtime_flow.md)

---

## Memorize These First

- cache stores repeated read results in a faster layer
- Redis is usually the shared production cache
- `CacheInterceptor` caches HTTP `GET` responses
- `CACHE_MANAGER` is for manual cache logic in services
- authenticated cache keys must include user identity
- writes must invalidate stale keys
- TTL balances speed and freshness

---

## Main strategies

| Strategy | Main idea |
| --- | --- |
| Cache-aside | read cache first, fetch and store on miss |
| Write-through | update DB and cache together on write |
| Invalidate on write | delete affected keys after write |

For most NestJS CRUD apps, cache-aside plus invalidation is the default pattern.

---

## Core NestJS API surface

| Item | Use it for |
| --- | --- |
| `CacheModule.register()` | simple cache setup |
| `CacheModule.registerAsync()` | env-driven async setup |
| `CacheInterceptor` | route-level auto-caching |
| `@CacheKey()` | custom cache key |
| `@CacheTTL()` | per-route TTL override |
| `CACHE_MANAGER` | direct cache access in services |
| `cacheManager.get()` | read cached value |
| `cacheManager.set()` | store cached value |
| `cacheManager.del()` | remove stale key |

---

## Key reminders

- use colon-separated keys like `tasks:list:42`
- include `userId` for authenticated endpoints
- centralize key builders in helper methods
- avoid unstable keys that change accidentally

Examples:

- `user:42`
- `tasks:list:42`
- `tasks:detail:17`
- `stats:tasks:global`

---

## TTL reminders

- short TTL = fresher data, fewer hits
- long TTL = more hits, more stale risk
- `0` means never expire
- combine TTL with invalidation for mutable data

---

## Common mistakes

- caching authenticated routes by URL only
- caching writes or mutation responses
- forgetting invalidation after update/delete/create
- using inconsistent key naming
- assuming cache is a correctness layer instead of a performance layer
- relying only on in-memory cache in a multi-instance deployment

---

## Interview flash answers

**Why use Redis instead of only in-memory cache?**

- Redis is shared across instances and is better suited for production cache coordination

**`CacheInterceptor` vs `CACHE_MANAGER`?**

- interceptor is declarative route caching
- `CACHE_MANAGER` is imperative service-level caching

**How do you avoid cross-user cache leaks?**

- generate user-scoped keys, usually by overriding `trackBy()`

**How do you handle stale cache?**

- delete affected keys after writes so the next read repopulates them

---

## Last-minute recall

- choose the right strategy
- design stable keys
- set TTL intentionally
- scope authenticated keys per user
- invalidate on writes
- keep the DB path working even if cache fails

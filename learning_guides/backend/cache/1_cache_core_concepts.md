# NestJS Cache Core Concepts

Purpose: This note explains the caching mental model in NestJS before the full Redis and `cache-manager` implementation walkthrough.

## Related Notes

- [2. Full Cache Learning Guide](./2_cache_learning_guide.md)
- [3. NestJS Cache Runtime Flow](./3_nestjs_cache_runtime_flow.md)
- [4. Cache Revision Cheatsheet](./4_cache_revision_cheatsheet.md)

---

## 1. Why caching exists

Caching stores the result of an expensive read in a faster temporary store so later requests do not repeat the same work.

TaskFlow examples:

- `GET /tasks` runs a heavy query with sorting and relations
- `GET /users/:id` fetches the same profile data repeatedly
- dashboard stats are expensive to recompute on every request

Without cache:

```text
Request -> service -> database -> response
```

With cache:

```text
Request -> cache
           -> hit: return fast
           -> miss: query database -> store result -> return
```

The main tradeoff is freshness. Faster reads usually mean you accept a small chance of stale data.

---

## 2. What Redis is and why it is commonly used

Redis is an in-memory key-value store. It is much faster than a relational database for simple lookups because:

- data is kept in RAM
- lookups happen by key
- TTL expiry is built in

Why Redis is better than process memory alone for production caching:

- it is external to the NestJS process
- multiple app instances can share the same cache
- cache data survives an app restart better than local memory

Important nuance:

- local in-memory cache is still useful as an L1 cache
- Redis is usually the shared L2 cache in production

---

## 3. The three main caching strategies

### Cache-aside

This is the most common pattern in backend apps.

Flow:

1. check cache
2. if hit, return cached value
3. if miss, query database
4. store result in cache
5. return result

Use it when:

- reads are frequent
- writes happen less often
- the app can tolerate short-lived staleness

### Write-through

On every write, update the database and cache together.

Use it when:

- reads are extremely frequent
- stale data is less acceptable

Tradeoff:

- write path becomes more complex

### Invalidate on write

After a create, update, or delete, remove affected cache keys. The next read becomes a miss and repopulates the cache.

Use it when:

- you want simpler write logic than full write-through
- reads should become fresh immediately after the next miss

This is the pattern most NestJS CRUD apps use with Redis.

---

## 4. TTL and freshness

TTL means Time To Live. It is how long a cached entry stays valid before it expires automatically.

Short TTL:

- fresher data
- fewer stale reads
- lower cache hit rate

Long TTL:

- better performance
- higher hit rate
- more stale-read risk

Examples:

- task list: short TTL plus invalidation on write
- user profile: moderate TTL
- label list: long TTL
- health check: no cache

Important reminder:

- in `@nestjs/cache-manager`, `0` means never expire
- that is usually a bad production default unless the data is manually invalidated and tightly controlled

---

## 5. HTTP response caching vs service-level caching

NestJS gives you two broad styles.

### HTTP response caching

Use `CacheInterceptor`.

This is good when:

- the whole `GET` response can be cached
- the cache key can be derived from the request
- you want a declarative route-level approach

### Service-level caching

Inject `CACHE_MANAGER` and call `get`, `set`, and `del` manually.

This is good when:

- you need cache-aside logic inside a service
- you want to cache only part of a response
- you need targeted invalidation on write
- you are caching computed values or external API results

Short rule:

- `CacheInterceptor` caches HTTP responses
- `CACHE_MANAGER` gives you direct cache control in business logic

---

## 6. Where caching sits in the NestJS lifecycle

For route-level caching:

```text
Incoming request
  -> guards
  -> CacheInterceptor pre-check
     -> hit: return cached response
     -> miss: continue
  -> controller
  -> service
  -> database
  -> CacheInterceptor stores response
  -> response
```

For manual service caching:

```text
controller
  -> service method
  -> cacheManager.get()
     -> hit: return cached data
     -> miss: query database
  -> cacheManager.set()
  -> return data
```

That difference matters in interviews and debugging:

- interceptors wrap request handling
- manual caching lives inside service code

---

## 7. Cache key design is part of the architecture

Redis keys are just strings. Bad key design creates bugs and makes invalidation hard.

Good pattern:

```text
resource:identifier:variant
```

Examples:

- `user:42`
- `tasks:list:42`
- `tasks:detail:17`
- `tasks:list:42:open`
- `stats:tasks:global`

Why naming matters:

- keys become predictable
- invalidation becomes reliable
- Redis inspection becomes easier

If keys are inconsistent, you will eventually delete the wrong key or fail to delete the stale one.

---

## 8. Authenticated routes need user-scoped cache keys

This is one of the highest-risk cache mistakes.

Problem:

- `GET /tasks` for user 42 and user 91 has the same URL
- if the cache key is only `/tasks`, both users share one cached response
- that becomes a data leak

Fix:

- include user identity in the key
- for interceptor-based caching, override `trackBy()`

Typical key:

```text
user:42:/tasks
```

Key interview point:

- caching authenticated responses without user scoping is a security bug, not just a performance bug

---

## 9. L1 vs L2 caching

A common production pattern is two-tier caching.

### L1

Local in-memory cache in the NestJS process.

Benefits:

- fastest reads
- useful for repeated hot requests inside one instance

Limitations:

- not shared across instances
- lost when the process restarts

### L2

Redis as the shared external cache.

Benefits:

- shared by all instances
- better consistency across a cluster

Short version:

- L1 is fastest
- L2 is shared
- together they reduce both latency and duplicated work

---

## 10. What not to cache

Do not cache:

- `POST`, `PUT`, `PATCH`, `DELETE` responses
- highly user-specific data without safe keys
- highly volatile data where stale reads are unacceptable
- endpoints using `@Res()` with native response handling, because `CacheInterceptor` cannot transparently wrap them the same way

Also be careful with:

- auth/session-like data whose lifetime must not exceed token lifetime
- very large payloads that waste Redis memory

---

## 11. Graceful degradation matters

Caching must improve performance, not become a hard dependency for correctness.

If Redis is unavailable:

- the app should still work
- the code should fall back to the database
- the app becomes slower, not broken

That is why the non-cached code path must always remain valid.

---

## 12. Concept checkpoints

If you can explain these clearly, you understand the topic well:

- why cache is useful even when the database is already indexed
- the difference between `CacheInterceptor` and `CACHE_MANAGER`
- why TTL and invalidation are both needed
- why authenticated endpoints need user-scoped keys
- why Redis is usually external L2 cache, not the only cache concept in the app
- why stale cache can be worse than no cache

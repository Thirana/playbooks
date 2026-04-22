# NestJS Cache Runtime Flow

Purpose: This note explains what happens at runtime when NestJS checks cache keys, serves cached responses, repopulates misses, and invalidates stale entries.

## Related Notes

- [1. Cache Core Concepts](./1_cache_core_concepts.md)
- [2. Full Cache Learning Guide](./2_cache_learning_guide.md)
- [4. Cache Revision Cheatsheet](./4_cache_revision_cheatsheet.md)

---

## TaskFlow setup used in this note

Assume the app has:

- global cache registration
- Redis as the shared cache store
- optional in-memory L1 cache
- a custom `HttpCacheInterceptor`
- manual service-level cache invalidation for user and task data

---

## 1. High-level lifecycle

```text
GET request
  -> auth guard
  -> HttpCacheInterceptor.trackBy()
  -> cache lookup
     -> hit: return cached response
     -> miss: run controller and service
  -> database query
  -> cache write
  -> response

Write request
  -> controller and service
  -> database write
  -> cacheManager.del(affected keys)
  -> next read becomes miss and repopulates cache
```

---

## 2. Route-level cache hit flow

Example: second `GET /tasks` request from user 42.

1. `JwtAuthGuard` authenticates the request.
2. `req.user.userId` is available.
3. `HttpCacheInterceptor.trackBy()` builds `user:42:/tasks`.
4. Nest checks the cache with that key.
5. A cached response is found.
6. The interceptor returns the cached payload immediately.
7. Controller and service logic do not run.

This is why route-level cache hits are fast.

---

## 3. Route-level cache miss flow

Example: first `GET /tasks` request from user 42.

1. Guard runs and sets `req.user`.
2. Interceptor builds `user:42:/tasks`.
3. Cache lookup returns `null`.
4. The request continues to the controller.
5. The controller calls the service.
6. The service queries the database or its own manual cache layer.
7. The handler returns data.
8. The interceptor stores the HTTP response under the cache key.
9. The client receives the response.

The first miss is slower, but later requests benefit from the stored response.

---

## 4. Manual cache-aside flow inside a service

Example: `UsersService.findById(42)`.

1. Build the key, such as `user:42`.
2. Call `cacheManager.get("user:42")`.
3. If there is a hit, return immediately.
4. If there is a miss, query PostgreSQL.
5. Call `cacheManager.set("user:42", user, ttl)`.
6. Return the user.

This flow happens inside the service, not inside the interceptor.

---

## 5. Invalidation flow after writes

Example: `POST /tasks` or `PATCH /tasks/:id`.

1. Mutation request reaches the service.
2. Service writes the new state to PostgreSQL.
3. Service deletes affected cache keys.
4. Stale entries disappear immediately.
5. The next read is forced to re-fetch fresh data.

Typical invalidations:

- delete `tasks:list:${userId}` after create
- delete `tasks:list:${userId}` and `tasks:detail:${taskId}` after update
- delete `user:${userId}` after avatar/profile change

This is the part people usually miss when they say they have "added caching."

---

## 6. L1 and L2 lookup order

In a two-tier setup:

1. the app checks local in-memory cache first
2. if L1 misses, it checks Redis
3. if Redis misses, it goes to the database
4. the fresh result is written back into cache

Benefits:

- hottest data returns from local memory
- shared Redis still synchronizes cache across instances

---

## 7. Common failure points

| Symptom | Likely cause |
| --- | --- |
| user sees another user's cached data | key does not include user identity |
| cache never hits | unstable key or wrong key generation |
| stale data remains after updates | invalidation logic missed a related key |
| app is fast locally but inconsistent in prod | only local memory cache was used |
| route does not cache | method is not `GET`, or `@Res()` is bypassing the normal response path |

---

## 8. Debugging checklist

1. What exact cache key is being generated?
2. Is the endpoint route-level cached or manually cached in the service?
3. Are authenticated responses safely namespaced per user?
4. After a write, which keys are deleted?
5. Is Redis connected, or is the app silently falling back to the database path?
6. Is TTL too short, making entries expire before they are reused?

Use this note for runtime narration and debugging. Use [4. Cache Revision Cheatsheet](./4_cache_revision_cheatsheet.md) when you only need the compressed version.

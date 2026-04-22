# NestJS Rate Limiting & Security Headers

### Study Notes — Interview Ready

---

## The Developer Requirement

TaskFlow has just launched publicly. Within 24 hours, three security incidents are reported:

**Incident 1 — Brute Force Attack**: A bot is hitting `POST /auth/login` thousands of times per minute, trying different password combinations for known email addresses. The server is slowing down and the logs are filling up.

**Incident 2 — Header Fingerprinting**: A security audit tool scanned the API and flagged that every response includes `X-Powered-By: Express`, which tells attackers exactly what framework and platform the API is built on. The audit also flagged missing security headers that browsers expect to protect against clickjacking and cross-site scripting.

**Incident 3 — Frontend CORS Error**: The React frontend hosted on `https://app.taskflow.com` cannot call the API at `https://api.taskflow.com` because the browser blocks the request. The API is not sending CORS headers.

All three incidents are fixed with three tools that belong in every production NestJS application: `@nestjs/throttler` for rate limiting, `helmet` for security headers, and NestJS's built-in CORS support.

---

## Part 1: Core Concepts

### What is Rate Limiting?

Rate limiting restricts how many requests a single client can make within a given time window. If the limit is exceeded, the server returns `429 Too Many Requests` and the client must wait before trying again.

Rate limiting serves two main purposes:

**Protection against brute force attacks**: A login endpoint without rate limiting can be hammered indefinitely. With a limit of 5 attempts per minute, an attacker would need years to try a meaningful number of passwords.

**Protection against API abuse and DoS**: A single misbehaving client cannot monopolize server resources or drain a paid external service (like an email provider or payment gateway) by making thousands of calls.

### What are Security Headers?

When a browser or HTTP client receives a response, it reads the headers to understand how to behave. Security headers are HTTP response headers that instruct the browser on security policies — which origins can embed the page, whether to allow inline scripts, whether to send the referer, and so on.

By default, Express (which NestJS runs on) sends almost no security headers. Worse, it sends `X-Powered-By: Express`, actively advertising itself to attackers. `helmet` is a middleware that sets a sensible set of security headers automatically.

### What is CORS?

CORS (Cross-Origin Resource Sharing) is a browser security mechanism. When a web page at `https://app.taskflow.com` makes a fetch call to `https://api.taskflow.com`, the browser first checks whether the API explicitly allows requests from that origin. If the API does not send the right CORS headers, the browser blocks the response — even if the request was technically successful on the server.

CORS is a browser enforcement — it does not affect server-to-server calls or tools like Postman. It is purely about protecting users from malicious web pages making unauthorized API calls on their behalf.

### Where Each Tool Fits in the Request Lifecycle

```
Incoming Request
      |
      v
  helmet()          ← Middleware — sets security headers on EVERY response
      |
      v
  CORS middleware   ← Middleware — validates origin, sets CORS headers
      |
      v
  ThrottlerGuard    ← Guard — checks request count against Redis/memory store
      |
      v
  Other Guards, Pipes, Controller...
      |
      v
  Response sent with security headers already set
```

Helmet and CORS are registered as middleware — they run before everything else. The throttler runs as a guard — after middleware but before the route handler.

---

## Part 2: Project Setup

### Install Dependencies

```bash
# Rate limiting
npm install --save @nestjs/throttler

# Security headers
npm install --save helmet

# For Redis-backed throttle storage in production (optional but recommended)
npm install --save @nestjs/throttler ioredis
```

### File Structure

```
src/
  throttler/
    throttler-behind-proxy.guard.ts   # Custom guard for apps behind a load balancer
  app.module.ts
  main.ts
```

---

## Part 3: Rate Limiting with @nestjs/throttler

### Step 3.1 — Basic Global Setup

The simplest setup registers one throttle rule globally. Every endpoint in the app is subject to it.

**`src/app.module.ts`**

```typescript
import { Module } from "@nestjs/common";
import { ThrottlerModule, ThrottlerGuard } from "@nestjs/throttler";
import { APP_GUARD } from "@nestjs/core";

@Module({
  imports: [
    ThrottlerModule.forRoot({
      throttlers: [
        {
          // ttl: time-to-live window in milliseconds
          // This window means: "track requests over the last 60 seconds"
          ttl: 60000, // 60 seconds

          // limit: maximum number of requests allowed within the ttl window
          // A client can make at most 100 requests per 60 seconds
          limit: 100,
        },
      ],
    }),
  ],
  providers: [
    {
      // Registering ThrottlerGuard as APP_GUARD applies it to every route globally.
      // Any route that does NOT have @SkipThrottle() is automatically rate-limited.
      provide: APP_GUARD,
      useClass: ThrottlerGuard,
    },
  ],
})
export class AppModule {}
```

### Step 3.2 — Multiple Named Throttlers (Production Pattern)

A single global rule is too blunt. You want tight limits on sensitive endpoints (login, register) and more generous limits on regular endpoints (fetching tasks). Multiple named throttlers let you define several rules and override them per route.

**`src/app.module.ts`** — updated with multiple throttlers

```typescript
import { Module } from "@nestjs/common";
import { ThrottlerModule, ThrottlerGuard } from "@nestjs/throttler";
import { APP_GUARD } from "@nestjs/core";
import { seconds, minutes } from "@nestjs/throttler"; // Time helper utilities

@Module({
  imports: [
    ThrottlerModule.forRoot({
      throttlers: [
        {
          // 'short': burst protection — no more than 5 requests per second
          // Prevents rapid-fire flooding of any single endpoint
          name: "short",
          ttl: seconds(1), // 1 second window
          limit: 5,
        },
        {
          // 'medium': general API usage — 50 requests per 10 seconds
          name: "medium",
          ttl: seconds(10), // 10 second window
          limit: 50,
        },
        {
          // 'long': hourly cap — 300 requests per hour
          // Catches slow-burn scrapers and bots that stay under short-term limits
          name: "long",
          ttl: minutes(60), // 60 minute window
          limit: 300,
        },
      ],
    }),
  ],
  providers: [
    {
      provide: APP_GUARD,
      useClass: ThrottlerGuard,
    },
  ],
})
export class AppModule {}
```

**Key Interview Point**: `seconds()` and `minutes()` are time helper utilities from `@nestjs/throttler` that convert to milliseconds. They make the configuration readable at a glance — `minutes(60)` is immediately clearer than `3600000`.

### Step 3.3 — Per-Route Throttle Overrides

Now that multiple throttlers are defined globally, you can tighten or skip them on specific routes using decorators.

**`src/auth/auth.controller.ts`** — tighter limits on sensitive endpoints

```typescript
import { Controller, Post, Body, UseGuards } from "@nestjs/common";
import { Throttle, SkipThrottle } from "@nestjs/throttler";

@Controller("auth")
export class AuthController {
  // POST /auth/login — tightest possible limit
  // Override only the 'short' and 'medium' throttlers for this route.
  // A client can only attempt login 5 times per minute — brute force protection.
  @Post("login")
  @Throttle({
    short: { limit: 3, ttl: seconds(60) }, // 3 attempts per minute
    medium: { limit: 5, ttl: minutes(10) }, // 5 attempts per 10 minutes
  })
  async login(@Body() body: any) {
    return this.authService.login(body);
  }

  // POST /auth/register — also tightly limited
  // Rate limiting prevents mass account creation by bots
  @Post("register")
  @Throttle({ short: { limit: 3, ttl: minutes(1) } })
  async register(@Body() body: any) {
    return this.authService.register(body.email, body.password);
  }

  // GET /auth/profile — skip the 'short' throttler only.
  // The user's own profile is safe to fetch frequently.
  // 'long' throttler still applies (can't fetch profile 1000 times an hour).
  @Get("profile")
  @SkipThrottle({ short: true }) // skip by name — only skips 'short', others still apply
  getProfile(@Request() req) {
    return req.user;
  }
}
```

**`src/health/health.controller.ts`** — skip throttling entirely on health check

```typescript
import { SkipThrottle } from "@nestjs/throttler";

// Health check endpoints are called by load balancers every few seconds.
// They must never be throttled — otherwise the load balancer marks the app as down.
@SkipThrottle()
@Controller("health")
export class HealthController {
  @Get()
  check() {
    return { status: "ok" };
  }
}
```

### Step 3.4 — Async Configuration with ConfigService

In production, throttle limits should come from environment variables so they can be tuned without a redeployment.

**`src/app.module.ts`** — async throttler config

```typescript
import { ThrottlerModule } from "@nestjs/throttler";
import { ConfigModule, ConfigService } from "@nestjs/config";

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    ThrottlerModule.forRootAsync({
      // Inject ConfigService to read limits from environment variables
      inject: [ConfigService],
      useFactory: (configService: ConfigService) => ({
        throttlers: [
          {
            name: "short",
            ttl: seconds(1),
            limit: configService.get<number>("THROTTLE_SHORT_LIMIT", 5),
          },
          {
            name: "long",
            ttl: minutes(60),
            limit: configService.get<number>("THROTTLE_LONG_LIMIT", 300),
          },
        ],
      }),
    }),
  ],
})
export class AppModule {}
```

**.env**

```
THROTTLE_SHORT_LIMIT=5
THROTTLE_LONG_LIMIT=300
```

### Step 3.5 — Handling Apps Behind a Proxy (Critical for Production)

In production, your NestJS app almost always runs behind a load balancer, reverse proxy (Nginx), or cloud gateway (AWS ALB). The real client IP is forwarded in the `X-Forwarded-For` header — but `req.ip` reads the proxy's IP instead. This means every client looks like the same IP, and a single legitimate request can trigger the rate limit for everyone.

The fix is two parts: tell Express to trust the proxy, and override `getTracker()` in a custom guard.

**`src/throttler/throttler-behind-proxy.guard.ts`**

```typescript
import { ThrottlerGuard } from "@nestjs/throttler";
import { Injectable } from "@nestjs/common";

@Injectable()
export class ThrottlerBehindProxyGuard extends ThrottlerGuard {
  // Override getTracker() to read the real client IP from X-Forwarded-For.
  // req.ips is an array of IPs populated by Express when trust proxy is enabled.
  // The first IP in the array is the original client IP (before any proxies).
  protected async getTracker(req: Record<string, any>): Promise<string> {
    return req.ips.length ? req.ips[0] : req.ip;
  }
}
```

**`src/main.ts`** — enable trust proxy

```typescript
import { NestExpressApplication } from "@nestjs/platform-express";

async function bootstrap() {
  const app = await NestFactory.create<NestExpressApplication>(AppModule);

  // Tell Express to trust the X-Forwarded-For header from the proxy.
  // 'loopback' trusts only local proxies (safe for development and simple deployments).
  // For cloud load balancers, use 1 (trust one hop) or the proxy's IP range.
  app.set("trust proxy", "loopback");

  await app.listen(3000);
}
```

**Use the custom guard in AppModule:**

```typescript
// Replace ThrottlerGuard with the proxy-aware version
{
  provide: APP_GUARD,
  useClass: ThrottlerBehindProxyGuard, // Use this instead of ThrottlerGuard
},
```

### Step 3.6 — Redis Storage for Multi-Instance Deployments

By default, `@nestjs/throttler` stores request counts in memory. This means each server instance has its own counter — a client hitting three servers in a cluster could make 3x the allowed requests. In production with multiple instances, you need a shared Redis store.

```bash
npm install --save @nestjs-modules/ioredis ioredis
```

**`src/app.module.ts`** — Redis-backed throttler

```typescript
import { ThrottlerStorageRedisService } from '@nest-lab/throttler-storage-redis';

ThrottlerModule.forRootAsync({
  inject: [ConfigService],
  useFactory: (configService: ConfigService) => ({
    throttlers: [
      { name: 'short', ttl: seconds(1), limit: 5 },
      { name: 'long', ttl: minutes(60), limit: 300 },
    ],
    // All instances share the same Redis store — request counts are accurate
    // across the entire cluster, not per-server
    storage: new ThrottlerStorageRedisService({
      host: configService.get('REDIS_HOST', 'localhost'),
      port: configService.get('REDIS_PORT', 6379),
    }),
  }),
}),
```

---

## Part 4: Security Headers with Helmet

### What Helmet Does

Helmet can help protect your app from some well-known web vulnerabilities by setting HTTP headers appropriately. Generally, Helmet is just a collection of smaller middleware functions that set security-related HTTP headers.

Each header it sets protects against a specific class of attack. You do not need to understand every header deeply — knowing what category of attack each one addresses is enough for an interview.

### Step 4.1 — Basic Setup

**`src/main.ts`**

```typescript
import helmet from "helmet";

async function bootstrap() {
  const app = await NestFactory.create(AppModule);

  // app.use(helmet()) must be called BEFORE any route definitions or other middleware.
  // Helmet is an Express middleware — order matters in Express.
  // If you call it after a route is defined, that route will not get the headers.
  app.use(helmet());

  await app.listen(3000);
}
```

That single line adds all of Helmet's default protections. In most cases, the defaults are appropriate and this is all you need.

### Step 4.2 — What the Default Headers Look Like

When you call `helmet()` with no configuration, the following headers are set on every response:

```http
Content-Security-Policy: default-src 'self'; ...
Cross-Origin-Embedder-Policy: require-corp
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Resource-Policy: same-origin
Origin-Agent-Cluster: ?1
Referrer-Policy: no-referrer
Strict-Transport-Security: max-age=15552000; includeSubDomains
X-Content-Type-Options: nosniff
X-DNS-Prefetch-Control: off
X-Download-Options: noopen
X-Frame-Options: SAMEORIGIN
X-Permitted-Cross-Domain-Policies: none
X-XSS-Protection: 0
```

And critically, the `X-Powered-By: Express` header that was advertising the framework is **removed**.

### What Each Key Header Does (Interview-Ready Explanations)

| Header                            | What it prevents                                                                                                                                                                             |
| --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Content-Security-Policy`         | XSS (Cross-Site Scripting) — tells the browser which scripts, styles, and resources are allowed to load. Blocks injected malicious scripts.                                                  |
| `X-Frame-Options: SAMEORIGIN`     | Clickjacking — prevents your page from being embedded in an `<iframe>` on another domain. An attacker cannot overlay a transparent iframe over a button to trick users into clicking it.     |
| `X-Content-Type-Options: nosniff` | MIME sniffing attacks — forces the browser to respect the declared `Content-Type` header and not try to guess the file type. Prevents a text file containing JavaScript from being executed. |
| `Strict-Transport-Security`       | Downgrade attacks — tells the browser to only connect over HTTPS for the next 15 million seconds, even if the user types `http://`. Prevents man-in-the-middle attacks on HTTP connections.  |
| `Referrer-Policy: no-referrer`    | Information leakage — stops the browser from including the current URL in the `Referer` header when navigating away. Prevents internal URLs from appearing in third-party server logs.       |
| Removal of `X-Powered-By`         | Fingerprinting — removes the header that tells attackers "this is an Express app", making targeted framework-specific attacks harder.                                                        |

### Step 4.3 — Customizing Helmet for Specific Needs

The default CSP (Content Security Policy) is strict. If your API serves an embedded Swagger UI or has specific asset loading requirements, you may need to relax it.

**`src/main.ts`** — customized Helmet for an API that serves Swagger UI

```typescript
app.use(
  helmet({
    // Content Security Policy — controls which resources the browser can load.
    contentSecurityPolicy: {
      directives: {
        defaultSrc: ["'self'"], // Only load resources from same origin by default
        scriptSrc: ["'self'", "'unsafe-inline'"], // Allow inline scripts (needed for Swagger UI)
        styleSrc: ["'self'", "'unsafe-inline'"], // Allow inline styles (needed for Swagger UI)
        imgSrc: ["'self'", "data:", "https:"], // Allow images from self, data URIs, and HTTPS
      },
    },

    // Cross-Origin-Embedder-Policy — set to false if your API serves
    // resources that need to be embedded cross-origin (e.g., fonts, images)
    crossOriginEmbedderPolicy: false,
  }),
);
```

**Key Interview Point**: Applying `helmet` as global or registering it must come before other calls to `app.use()` or setup functions that may call `app.use()`. This is due to the way the underlying platform works, where the order that middleware/routes are defined matters. If you use middleware like `helmet` or `cors` after you define a route, then that middleware will not apply to that route.

---

## Part 5: CORS Configuration

### What CORS Is and Is Not

CORS is enforced by the **browser**, not the server. When the browser makes a cross-origin request, it includes an `Origin` header. The server must respond with `Access-Control-Allow-Origin` that either matches the origin or is `*`. If it does not, the browser blocks the response.

This means CORS does not protect your API from server-to-server calls, curl, or Postman. It only protects users from malicious web pages making requests on their behalf.

### Step 5.1 — Simple CORS Enable

**`src/main.ts`** — the simplest setup

```typescript
async function bootstrap() {
  const app = await NestFactory.create(AppModule);

  // app.enableCors() with no arguments allows ALL origins.
  // This is fine for fully public APIs, but too permissive for most apps.
  app.enableCors();

  await app.listen(3000);
}
```

### Step 5.2 — Production CORS Configuration

In production you want to whitelist specific origins rather than allowing all.

**`src/main.ts`** — production CORS

```typescript
async function bootstrap() {
  const app = await NestFactory.create(AppModule);

  const allowedOrigins = [
    "https://app.taskflow.com", // Production frontend
    "https://admin.taskflow.com", // Admin panel
  ];

  // In development, also allow localhost origins
  if (process.env.NODE_ENV !== "production") {
    allowedOrigins.push("http://localhost:3001", "http://localhost:5173");
  }

  app.enableCors({
    // origin can be:
    // - a string: 'https://example.com' — only that origin is allowed
    // - an array: multiple origins are allowed
    // - a RegExp: e.g. /\.taskflow\.com$/ — all subdomains
    // - a function: (origin, callback) => {} — custom logic per request
    origin: allowedOrigins,

    // methods: which HTTP methods are allowed in cross-origin requests
    methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],

    // allowedHeaders: which request headers the browser can include
    allowedHeaders: ["Content-Type", "Authorization"],

    // credentials: true is required if your frontend sends cookies or
    // Authorization headers. When true, origin cannot be '*' — it must be explicit.
    credentials: true,

    // maxAge: how long (in seconds) the browser can cache the preflight response.
    // 86400 = 24 hours — reduces the number of preflight OPTIONS requests.
    maxAge: 86400,
  });

  await app.listen(3000);
}
```

### Step 5.3 — Dynamic CORS with a Callback

When you have many allowed origins or need to read them from a database or config, use the callback form.

**`src/main.ts`** — dynamic origin validation

```typescript
const configService = app.get(ConfigService);
const allowedOrigins = configService.get<string>("ALLOWED_ORIGINS").split(",");
// e.g., ALLOWED_ORIGINS=https://app.taskflow.com,https://admin.taskflow.com

app.enableCors({
  origin: (requestOrigin, callback) => {
    // requestOrigin is undefined for server-to-server requests (no browser involved)
    // Allow them through — CORS only matters for browsers
    if (!requestOrigin) {
      return callback(null, true);
    }

    if (allowedOrigins.includes(requestOrigin)) {
      // Origin is in the whitelist — allow it
      callback(null, true);
    } else {
      // Origin is not allowed — the browser will block the response
      callback(new Error(`CORS: Origin ${requestOrigin} not allowed`), false);
    }
  },
  credentials: true,
});
```

---

## Part 6: The Complete main.ts — Everything Together

Here is the production-ready `main.ts` that applies all three security layers in the correct order.

**`src/main.ts`**

```typescript
import { NestFactory } from "@nestjs/core";
import { NestExpressApplication } from "@nestjs/platform-express";
import { ValidationPipe } from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { WINSTON_MODULE_NEST_PROVIDER } from "nest-winston";
import helmet from "helmet";
import { AppModule } from "./app.module";

async function bootstrap() {
  const app = await NestFactory.create<NestExpressApplication>(AppModule, {
    bufferLogs: true,
  });

  const configService = app.get(ConfigService);
  const nodeEnv = configService.get<string>("NODE_ENV", "development");
  const port = configService.get<number>("PORT", 3000);

  // 1. Logger — replace NestJS built-in logger with Winston (from Logging notes)
  app.useLogger(app.get(WINSTON_MODULE_NEST_PROVIDER));

  // 2. Trust proxy — MUST come before helmet and CORS so req.ips is populated correctly.
  // Required for ThrottlerBehindProxyGuard to read the real client IP.
  app.set("trust proxy", nodeEnv === "production" ? 1 : "loopback");

  // 3. Helmet — MUST come before any route definitions or other app.use() calls.
  // Sets all security headers on every response.
  app.use(
    helmet({
      contentSecurityPolicy: nodeEnv === "production", // Strict CSP only in production
    }),
  );

  // 4. CORS — must come before routes, after helmet
  const allowedOrigins = configService
    .get<string>("ALLOWED_ORIGINS", "http://localhost:3001")
    .split(",");

  app.enableCors({
    origin: allowedOrigins,
    methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allowedHeaders: ["Content-Type", "Authorization"],
    credentials: true,
    maxAge: 86400,
  });

  // 5. Global prefix — all routes are prefixed with /api/v1
  app.setGlobalPrefix("api/v1");

  // 6. ValidationPipe — validates and transforms all incoming request bodies
  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,
      forbidNonWhitelisted: true,
      transform: true,
    }),
  );

  await app.listen(port);
}

bootstrap();
```

---

## Part 7: The Complete Flow (Interview Story)

### Brute Force Login Attack Flow

1. A bot sends `POST /api/v1/auth/login` 1000 times per minute from IP `192.168.1.50`.
2. The request arrives. Helmet has already set security headers on the way out (those are response-time, not request-time).
3. CORS middleware checks the `Origin` header — if it is a browser request from an allowed origin, it proceeds.
4. `ThrottlerBehindProxyGuard` runs. It reads `req.ips[0]` (the real IP from `X-Forwarded-For`, not the proxy IP).
5. It checks the counter for `192.168.1.50` against the `short` throttler: 5 requests per second. The 6th request in the same second returns `429 Too Many Requests` immediately. The bot cannot get through fast enough to attempt a meaningful brute force.
6. The `medium` throttler provides a second layer: even if the bot spaces requests out, it hits the 50-per-10-second cap.

### Normal Request Flow

1. A user's browser at `https://app.taskflow.com` sends `GET /api/v1/tasks`.
2. `Origin: https://app.taskflow.com` is in the allowed list. CORS headers are added to the response: `Access-Control-Allow-Origin: https://app.taskflow.com`.
3. `ThrottlerGuard` checks the counter — within limits. Proceeds.
4. The route handler runs and returns tasks.
5. Helmet headers are in the response: `X-Frame-Options: SAMEORIGIN`, `X-Content-Type-Options: nosniff`, `Strict-Transport-Security`, etc. The `X-Powered-By` header is absent.
6. The browser sees `Access-Control-Allow-Origin` matches its origin and allows the JavaScript code to read the response.

---

## Part 8: Production Checklist & Interview Points

**Best practices:**

- Always place `app.use(helmet())` before any route definitions. Middleware order in Express is significant — headers are only set for routes defined after the middleware.
- Never use `origin: '*'` with `credentials: true` in CORS. The browser will reject it. When credentials are involved, you must explicitly list allowed origins.
- Always use `trust proxy` in production environments behind a load balancer, and use the proxy-aware `ThrottlerBehindProxyGuard`. Without this, all clients look like the same IP and a single user can trigger the limit for everyone.
- Use Redis storage for `@nestjs/throttler` in multi-instance deployments. In-memory storage is per-process — request counts are not shared across instances.
- Read throttle limits from environment variables using `forRootAsync` with `ConfigService`. This lets you tune limits without redeploying.
- Always apply tighter `@Throttle()` overrides on authentication endpoints (`/login`, `/register`, `/forgot-password`). These are the most abused endpoints in any public API.
- Always use `@SkipThrottle()` on health check endpoints. Load balancers poll these every few seconds and will fail health checks if they are rate-limited.

**Common interview questions:**

Q: What is the difference between `@SkipThrottle()` and `@Throttle()`?

A: `@SkipThrottle()` completely disables rate limiting for a route or controller. It can also accept an object like `@SkipThrottle({ short: true })` to skip only specific named throttlers while leaving others active. `@Throttle()` does not skip — it overrides the global limits with different values, either tighter (for sensitive endpoints like login) or looser (for high-frequency endpoints like polling).

Q: Why does rate limiting by IP fail silently behind a load balancer without `trust proxy`?

A: When your app is behind a load balancer or reverse proxy, `req.ip` contains the proxy's IP address, not the client's. Every single client looks like the same IP — the proxy. This means all traffic counts toward a single rate limit bucket, and the very first real client to use the API in a new window triggers the limit for everyone. Enabling `trust proxy` causes Express to read the real client IP from the `X-Forwarded-For` header, and overriding `getTracker()` in a custom `ThrottlerGuard` subclass ensures the throttler uses that real IP.

Q: What does `helmet()` actually do and why is it applied as middleware?

A: Helmet is a collection of small middleware functions, each setting one security-related HTTP response header. Calling `helmet()` applies all of them at once with sensible defaults. It is applied as Express middleware (via `app.use()`) because it needs to run on every request and set headers before the response is sent. Being middleware means it runs in the normal Express request pipeline, early enough to affect all routes.

Q: What is a CORS preflight request?

A: Before a browser sends a cross-origin request that uses non-simple methods (PUT, PATCH, DELETE) or custom headers (like `Authorization`), it first sends an `OPTIONS` request to the same URL. This is the preflight. The server responds with CORS headers indicating which methods and headers are allowed. If the preflight succeeds, the browser sends the actual request. The `maxAge` option caches the preflight result so the browser does not send an `OPTIONS` request on every API call — set it to `86400` (24 hours) in production.

Q: What is the difference between `origin: '*'` and specifying an array of origins in CORS?

A: `origin: '*'` allows any website to make requests to your API — it is fully open. This is appropriate for truly public APIs (like a public weather API) but not for authenticated APIs. When `credentials: true` is set (for cookies or Authorization headers), `origin: '*'` is actually rejected by the browser spec — you must explicitly list allowed origins. An array of origins gives you fine-grained control, allowing only known frontends to call the API while blocking any other website from accessing it.

---

## Quick Reference: File Summary

| File                                            | Purpose                                                                                       |
| ----------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `src/main.ts`                                   | `helmet()`, `enableCors()`, `trust proxy`, and `setGlobalPrefix()` — all in the correct order |
| `src/app.module.ts`                             | `ThrottlerModule.forRootAsync()` with named throttlers and `APP_GUARD` registration           |
| `src/throttler/throttler-behind-proxy.guard.ts` | Custom guard overriding `getTracker()` to read real IP from `X-Forwarded-For`                 |
| `.env`                                          | `THROTTLE_SHORT_LIMIT`, `THROTTLE_LONG_LIMIT`, `ALLOWED_ORIGINS`, `REDIS_HOST`                |

## Quick Reference: Throttler Decorator Cheat Sheet

| Usage                                            | Decorator                                        |
| ------------------------------------------------ | ------------------------------------------------ |
| Skip all throttlers on a route                   | `@SkipThrottle()`                                |
| Skip one named throttler only                    | `@SkipThrottle({ short: true })`                 |
| Re-enable throttling inside a skipped controller | `@SkipThrottle({ default: false })`              |
| Override limits on a route                       | `@Throttle({ short: { limit: 3, ttl: 60000 } })` |

---

_Sources: NestJS Official Documentation — [Rate Limiting](https://docs.nestjs.com/security/rate-limiting), [Helmet](https://docs.nestjs.com/security/helmet), and [CORS](https://docs.nestjs.com/security/cors)_

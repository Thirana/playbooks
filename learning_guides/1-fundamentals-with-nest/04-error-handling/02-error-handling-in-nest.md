# Error Handling in NestJS (Lesson — Framework)

> How NestJS turns an error that escapes your code into an HTTP response — built up from the request lifecycle, with a full worked MO example (the OTP/SMS flow). Assumes the language-level model in `error-handling-a-js-ts.md`. Distilled reference: `error-handling-js-ts-nestjs.md`.

---

## The mental model: NestJS wraps every request in a try/catch it owns

A request runs through a pipeline of stages. Conceptually, that entire pipeline sits inside **one big `try/catch` the framework provides** — you never write it. So when an error escapes *your* code and you didn't catch it, it doesn't crash the process like a raw Node uncaught exception. It lands in NestJS's built-in catch block, whose job is to decide the HTTP response. That decision-maker is the **exception filter**.

This is why an unhandled error in a controller still produces a clean JSON error response with a status code, instead of a dead server. The only question is *which* status and message — and that's entirely the filter's logic.

## The request lifecycle: where errors come from

NestJS runs these stages in order. Any of them can throw, and **an error thrown at any stage is funneled to the exception filters** — the single place every failure becomes a response.

```
Request
  → Middleware          raw HTTP setup
  → Guards              authn/authz            → can throw (e.g. Unauthorized)
  → Interceptors (pre)
  → Pipes               validation/transform   → can throw (e.g. validation 400)
  → ROUTE HANDLER       your controller        → calls services → can throw
  → Interceptors (post)
  → Exception filters   ← everything that threw above lands here
Response
```

Two practical implications for MO:

- A **validation error** (bad OTP request body) is thrown by a *pipe*, before your handler ever runs. You don't write that try/catch — the pipe throws a `BadRequestException`, and the filter turns it into a 400.
- A **service failure** (SMS provider rejects) is thrown deep in a provider, bubbles up through the handler (which `await`s it), and reaches the filter. Whether it becomes a *useful* response depends entirely on whether it was translated on the way up.

## `HttpException`: the framework's error language

NestJS defines `HttpException`, whose whole job is to bundle a **status code** + a **message/body**. Its subclasses each carry their correct status *inside themselves*:

```ts
throw new NotFoundException('order not found');   // this object KNOWS it is a 404
```

| Throw | Status | Typical MO use |
|-------|--------|----------------|
| `BadRequestException` | 400 | invalid input the pipe didn't catch |
| `UnauthorizedException` | 401 | missing/invalid token |
| `ForbiddenException` | 403 | authenticated but not allowed |
| `NotFoundException` | 404 | order/user not found |
| `ConflictException` | 409 | duplicate registration, OTP already used |
| `UnprocessableEntityException` | 422 | semantically invalid request |
| `BadGatewayException` | 502 | upstream (reward/SMS) returned a bad response |
| `ServiceUnavailableException` | 503 | upstream down / can't complete now |

The property that matters: **the filter can ask an `HttpException` for its status and get the right one.** A plain `Error` (or an `AxiosError`) has no such status — which is why the filter has to guess, and guesses 500.

## The filter's logic, and a real `AllExceptionsFilter`

The default rule: **`HttpException` → honor its status; anything else → 500.** That default is *correct* — if an unrecognized error escaped, the framework genuinely can't know the right status, so it assumes an unexpected server failure. **500 means "an error I don't understand escaped your code."**

Here's a production-shaped global filter for MO — it applies the rule, logs once with correlation context, and returns a consistent JSON shape:

```ts
import {
  ArgumentsHost, Catch, ExceptionFilter, HttpException, HttpStatus, Logger,
} from '@nestjs/common';
import { Request, Response } from 'express';
import { als } from '../context';   // the ALS store from the DI/pipeline topics

@Catch()   // catch EVERYTHING
export class AllExceptionsFilter implements ExceptionFilter {
  private readonly logger = new Logger(AllExceptionsFilter.name);

  catch(exception: unknown, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const res = ctx.getResponse<Response>();
    const req = ctx.getRequest<Request>();

    // 1. status: HttpException knows its own; everything else is an unknown → 500
    const status =
      exception instanceof HttpException
        ? exception.getStatus()
        : HttpStatus.INTERNAL_SERVER_ERROR;

    // 2. client-facing message (never leak internals on a 500)
    const clientMessage =
      exception instanceof HttpException
        ? exception.getResponse()
        : 'Internal server error';

    // 3. log ONCE, here, with full detail + correlation id — the last-resort record
    const store = als.getStore();
    const logPayload = {
      requestId: store?.requestId,
      method: req.method,
      path: req.url,
      status,
      err: exception,                       // full error incl. cause chain, for the log store only
    };
    if (status >= 500) {
      this.logger.error(logPayload, 'unhandled error');      // a human may need to act
    } else {
      this.logger.warn(logPayload, 'request rejected');       // expected 4xx, handled
    }

    // 4. consistent response shape
    res.status(status).json({
      statusCode: status,
      message: clientMessage,
      requestId: store?.requestId,          // let clients quote it in support tickets
      timestamp: new Date().toISOString(),
    });
  }
}
```

Bind it globally *and* keep it injectable via the `APP_FILTER` token:

```ts
@Module({ providers: [{ provide: APP_FILTER, useClass: AllExceptionsFilter }] })
export class AppModule {}
```

Note the split of responsibilities: **the filter's job is to *format and log*, not to *interpret*.** It does not know what an `AxiosError` is, and shouldn't. Interpretation happens at the boundary (below).

## The worked example: the OTP/SMS flow, done wrong then right

This is the real MO chain — `AuthController.mobileVerification` → `OtpService.sendOtpToUserBySms` → `SmsService.sendSms` → notify.lk over Axios.

### The DTO + pipe (errors handled *before* your code runs)

```ts
// dto/mobile-verification.dto.ts
export class MobileVerificationDto {
  @IsString() @Matches(/^0\d{9}$/, { message: 'mobileNumber must be a 10-digit local number' })
  mobileNumber: string;

  @IsIn(['register', 'login']) type: 'register' | 'login';
  @IsEmail() email: string;
  @IsString() @Length(1, 60) displayName: string;
  @IsOptional() @IsString() referralCode?: string;
}
```

```ts
// main.ts — one global pipe validates every DTO
app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }));
```

With this, a malformed body never reaches your handler — the pipe throws, the filter returns a clean 400. Your handler code contains **zero** validation logic.

### ❌ The bug: raw error leaks to the filter → misleading 500

```ts
// sms.service.ts — ❌
@Injectable()
export class SmsService {
  async sendSms(to: string, message: string) {
    const params = new URLSearchParams({ /* ...notify.lk params... */ });
    try {
      const res = await axios.post(this.apiUrl, params.toString(), { headers: {/*...*/} });
      return res.data;
    } catch (error) {
      console.error('Error sending SMS:', error);   // logs a blob; drops error.response.data
      throw error;                                   // re-throws the raw AxiosError
    }
  }
}

// otp.service.ts — ❌ no try/catch; passes the AxiosError straight through
@Injectable()
export class OtpService {
  constructor(private readonly sms: SmsService) {}
  async sendOtpToUserBySms(user: User) {
    const code = generateOtp();
    await this.sms.sendSms(user.mobile, `Your code is ${code}`);   // AxiosError bubbles up
    return code;
  }
}

// auth.controller.ts — ❌ no try/catch around the OTP call
@Controller('auth')
export class AuthController {
  constructor(private readonly otp: OtpService) {}

  @Post('mobile-verification-otp')
  async mobileVerification(@Body() dto: MobileVerificationDto) {
    const user = await this.users.upsert(dto);
    await this.otp.sendOtpToUserBySms(user);   // raw AxiosError reaches the filter
    return { status: 'otp_sent' };
  }
}
```

**Trace it:** notify.lk returns 400 → Axios throws an `AxiosError` → `sendSms` re-throws it raw → `OtpService` and the controller `await` and pass it up → it reaches `AllExceptionsFilter` → `instanceof HttpException` is **false** → status defaults to **500**, message becomes Axios's generic `"Request failed with status code 400"`. The real reason (in `error.response.data`) was never logged. **The filter is working correctly on an error nobody translated.**

### ✅ The fix: translate at the boundary that understands the error

`SmsService` is the only layer that knows "this is an SMS-provider call, and a failure means the OTP couldn't be sent." It has the context to choose the right status — 503, "our upstream dependency failed" (not 400/500).

```ts
// sms.service.ts — ✅ translate + log the real reason once
@Injectable()
export class SmsService {
  private readonly logger = new Logger(SmsService.name);

  async sendSms(to: string, message: string) {
    const params = new URLSearchParams({ /* ... */ });
    try {
      const res = await axios.post(this.apiUrl, params.toString(), {
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        signal: AbortSignal.timeout(3000),   // async note: every outbound call gets a bound
      });
      return res.data;
    } catch (error) {
      if (axios.isAxiosError(error)) {
        this.logger.error(
          { event: 'sms.send.failed', upstreamStatus: error.response?.status, data: error.response?.data },
          'notify.lk rejected the SMS',      // the reason that was dropped before — logged ONCE, here
        );
      }
      throw new ServiceUnavailableException('Failed to send verification code', { cause: error });
    }
  }
}
```

`OtpService` needs no try/catch now — the error it receives is already an `HttpException`, so it can propagate cleanly, and the filter will honor the 503. The controller likewise stays clean; if you want a friendlier client message you can wrap at the controller, but you don't *have* to:

```ts
// auth.controller.ts — optional friendlier wrap; still an HttpException either way
@Post('mobile-verification-otp')
async mobileVerification(@Body() dto: MobileVerificationDto) {
  const user = await this.users.upsert(dto);
  try {
    await this.otp.sendOtpToUserBySms(user);
  } catch (error) {
    // already a 503 from the service; rewrap only to add a user-facing message
    throw new ServiceUnavailableException(
      'We could not send your verification code right now. Please try again shortly.',
      { cause: error },
    );
  }
  return { status: 'otp_sent' };
}
```

Now the outcome is: client gets a truthful **503** with an actionable message, the log has the **real** notify.lk reason with a `requestId`, and the `cause` chain is intact for debugging — all without the global filter knowing a thing about Axios.

## Why the fix does NOT go in the filter

Tempting wrong fix — teach `AllExceptionsFilter` about Axios:

```ts
// ❌ leaking a library's concepts into generic infrastructure
catch(exception: unknown, host: ArgumentsHost) {
  if (axios.isAxiosError(exception)) {
    status = exception.response?.status ?? 502;   // next month: the DB driver's error type too…
  }                                               // …the filter becomes a special-case dumping ground
}
```

The filter is **generic infrastructure** — the whole-app safety net. Each error should be translated where it's *first understood* (the service with context), not centrally where all context is lost. Division of labor:

- **Service boundaries** → translate specific low-level errors into meaningful `HttpException`s.
- **Global filter** → format + log everything, and treat the *genuinely* unanticipated as 500.

## Custom exception classes (when to bother)

For domain errors that recur, a small custom `HttpException` subclass keeps controllers clean and consistent:

```ts
export class OtpAlreadyUsedException extends ConflictException {   // 409
  constructor(cause?: unknown) {
    super('This verification code has already been used', { cause });
  }
}

// in the service:
if (otp.used) throw new OtpAlreadyUsedException();
```

The filter already handles it correctly (it's an `HttpException` → 409), and the intent reads clearly at the throw site. Reach for these when the same domain error appears in multiple places; don't over-engineer one-offs.

## Filters vs try/catch — the division

| Tool | Scope | Use for |
|------|-------|---------|
| `try/catch` at a service/controller boundary | one operation | translating an error you have local context to understand (the SMS case) |
| Exception filter | whole app | consistent response shape, logging every failure, catching the unanticipated |

They're complementary: boundaries translate; the filter formats and backstops. MO already has both — the filter exists, and some methods (`emailVerification`) translate at their boundary. The bug was one method (`mobileVerification`) missing its boundary.

---

## The build, in order

**framework try/catch** (you don't write it) → **the lifecycle** (every stage's error funnels to the filter) → **`HttpException`** (the language, subclasses carry status) → **the filter's rule** (`HttpException` → its status; else 500) + a real logging/shaping filter → **worked OTP example** (wrong: raw leak → 500; right: translate at `SmsService` → truthful 503) → **why not in the filter** → **custom exceptions** → **filters vs try/catch**. The language-level foundation is `error-handling-a-js-ts.md`; common wrong/right patterns for review are in `error-handling-nestjs-review-examples.md`.
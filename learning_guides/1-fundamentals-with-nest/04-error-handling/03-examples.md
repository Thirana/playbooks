# NestJS Error Handling — Wrong vs Right Patterns

> Real, review-ready examples: each shows a wrong approach you might see in a diff, why it's wrong, and the corrected version. Companion to `error-handling-b-nestjs.md` (the concepts). Examples are shaped around the MO backend (auth/OTP, reward, orders).

---

## 1. Re-throwing a raw library error from a service

A service catches an `AxiosError` (or a DB-driver error) and re-throws it unchanged. It isn't an `HttpException`, so the global filter can't read a status from it and defaults to **500** — with a message that describes the *upstream's* status, not yours.

```ts
// ❌ raw AxiosError leaks past the boundary
@Injectable()
export class RewardService {
  async grant(userId: string, points: number) {
    try {
      const res = await axios.post(`${this.baseUrl}/grant`, { userId, points });
      return res.data;
    } catch (error) {
      throw error;   // AxiosError → filter sees a plain Error → 500 "Request failed with status code 400"
    }
  }
}
```

```ts
// ✅ translate at the boundary into an HttpException that carries a truthful status
@Injectable()
export class RewardService {
  private readonly logger = new Logger(RewardService.name);

  async grant(userId: string, points: number) {
    try {
      const res = await axios.post(`${this.baseUrl}/grant`, { userId, points }, {
        signal: AbortSignal.timeout(2000),
      });
      return res.data;
    } catch (error) {
      if (axios.isAxiosError(error)) {
        this.logger.error(
          { event: 'reward.grant.failed', userId, upstreamStatus: error.response?.status, data: error.response?.data },
          'reward service rejected the grant',
        );
      }
      // our dependency failed → 502/503, not a mislabeled 500
      throw new ServiceUnavailableException('Could not grant reward', { cause: error });
    }
  }
}
```

---

## 2. `console.error(e); throw e` inside a provider

This drops the real reason (`error.response.data`), logs without a correlation ID, and — because it re-throws raw — usually gets logged *again* at every layer above. One failure becomes five uncorrelated log lines, none authoritative, and still a 500.

```ts
// ❌ logs a blob, drops the reason, re-throws raw
@Injectable()
export class SmsService {
  async sendSms(to: string, message: string) {
    try {
      return await axios.post(this.apiUrl, this.buildParams(to, message));
    } catch (error) {
      console.error('Error sending SMS:', error);   // no reason, no requestId
      throw error;                                   // and every caller may log it again
    }
  }
}
```

```ts
// ✅ log once, structured, with the real reason — then translate
@Injectable()
export class SmsService {
  private readonly logger = new Logger(SmsService.name);

  async sendSms(to: string, message: string) {
    try {
      return await axios.post(this.apiUrl, this.buildParams(to, message), {
        signal: AbortSignal.timeout(3000),
      });
    } catch (error) {
      if (axios.isAxiosError(error)) {
        this.logger.error(
          { event: 'sms.send.failed', upstreamStatus: error.response?.status, data: error.response?.data },
          'notify.lk rejected the SMS',
        );
      }
      throw new ServiceUnavailableException('Failed to send verification code', { cause: error });
    }
  }
}
```

The callers above `SmsService` now add **no** logging — the error is already recorded at the boundary that understood it, and it arrives upstream as a clean `HttpException`.

---

## 3. Teaching the global filter about library errors

Putting `instanceof AxiosError` logic inside `AllExceptionsFilter` leaks a specific library's concepts into generic infrastructure. Next month it needs to know the DB driver's error type, then the message-broker's, and the filter becomes a special-case dumping ground.

```ts
// ❌ the global filter now knows about Axios (and will grow to know every library)
@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  catch(exception: unknown, host: ArgumentsHost) {
    let status = HttpStatus.INTERNAL_SERVER_ERROR;
    if (exception instanceof HttpException) status = exception.getStatus();
    else if (axios.isAxiosError(exception)) status = exception.response?.status ?? 502;  // leak
    // ...
  }
}
```

```ts
// ✅ filter stays generic; the AxiosError was already translated in the service (see #1)
@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  catch(exception: unknown, host: ArgumentsHost) {
    const status =
      exception instanceof HttpException
        ? exception.getStatus()
        : HttpStatus.INTERNAL_SERVER_ERROR;   // unknown = genuinely unanticipated
    // ...format + log...
  }
}
```

The filter's job is to *format and log*, never to *interpret* specific libraries. Interpretation belongs at the service boundary.

---

## 4. Re-throwing an upstream 4xx as the client's status

When a dependency returns a `400`, that's *your dependency* refusing — it is not evidence the *client* sent a bad request. Passing it through as a `400` blames the caller for something they didn't do.

```ts
// ❌ mirrors the upstream's 400 back to the client
async grant(userId: string, points: number) {
  try {
    return await axios.post(`${this.baseUrl}/grant`, { userId, points });
  } catch (error) {
    if (axios.isAxiosError(error)) {
      throw new BadRequestException('reward failed');   // 400 — wrongly blames the client
    }
    throw error;
  }
}
```

```ts
// ✅ your dependency failing is a 502/503, not a client error
async grant(userId: string, points: number) {
  try {
    return await axios.post(`${this.baseUrl}/grant`, { userId, points });
  } catch (error) {
    // if the upstream 4xx means WE sent a bad request, that's a bug to fix, not to forward.
    // for a dependency failure, surface it as "upstream problem":
    throw new BadGatewayException('reward service rejected the request', { cause: error });
  }
}
```

(If an upstream `4xx` genuinely reflects bad input the *client* gave you, the right fix is to validate that input at your own edge with a DTO — see #5 — so it never reaches the upstream.)

---

## 5. Hand-rolling validation in the handler

Manual `if` checks in a controller reinvent validation, are inconsistent across endpoints, and mix input-checking into business logic. Validation belongs at the pipe stage.

```ts
// ❌ manual, inconsistent, clutters the handler
@Post('mobile-verification-otp')
async mobileVerification(@Body() body: any) {
  if (!body.mobileNumber || !/^0\d{9}$/.test(body.mobileNumber)) {
    throw new BadRequestException('invalid mobile number');
  }
  if (!body.email) throw new BadRequestException('email required');
  // ...actual logic buried below the plumbing...
}
```

```ts
// ✅ a DTO + global ValidationPipe rejects bad input before the handler runs
export class MobileVerificationDto {
  @IsString() @Matches(/^0\d{9}$/, { message: 'mobileNumber must be a 10-digit local number' })
  mobileNumber: string;

  @IsIn(['register', 'login']) type: 'register' | 'login';
  @IsEmail() email: string;
  @IsString() @Length(1, 60) displayName: string;
  @IsOptional() @IsString() referralCode?: string;
}

@Post('mobile-verification-otp')
async mobileVerification(@Body() dto: MobileVerificationDto) {
  // dto is guaranteed valid and typed here — handler is pure business logic
  const user = await this.users.upsert(dto);
  await this.otp.sendOtpToUserBySms(user);
  return { status: 'otp_sent' };
}
```

```ts
// main.ts — one global pipe enforces every DTO
app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }));
```

---

## 6. Leaking internal detail to the client on a 500

Returning `exception.message` (or worse, the stack) on an unexpected error exposes internals — file paths, driver messages, sometimes secrets — to whoever called the API. Detail belongs in the logs, not the response.

```ts
// ❌ whatever threw, its raw message goes to the client
res.status(status).json({ statusCode: status, message: (exception as Error).message });
```

```ts
// ✅ honor HttpException messages (they're intended for clients); generic text for 5xx
catch(exception: unknown, host: ArgumentsHost) {
  const status =
    exception instanceof HttpException ? exception.getStatus() : HttpStatus.INTERNAL_SERVER_ERROR;

  const clientMessage =
    exception instanceof HttpException ? exception.getResponse() : 'Internal server error';

  const store = als.getStore();
  this.logger.error(
    { requestId: store?.requestId, status, err: exception },   // full detail → logs only
    'unhandled error',
  );

  res.status(status).json({
    statusCode: status,
    message: clientMessage,                 // safe: either an intended HttpException message or generic
    requestId: store?.requestId,
    timestamp: new Date().toISOString(),
  });
}
```

---

## 7. A global filter (or guard/interceptor) built with `new` that needs dependencies

Registering a global component with `new` means it can't participate in DI — it can't inject a logger, config, or anything else. Use the `APP_*` provider token instead.

```ts
// ❌ built with `new` → cannot inject ConfigService/Logger/etc.
async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  app.useGlobalFilters(new AllExceptionsFilter());   // no DI
}
```

```ts
// ✅ registered as a provider → global AND injectable
@Module({
  providers: [
    { provide: APP_FILTER, useClass: AllExceptionsFilter },
  ],
})
export class AppModule {}

@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  constructor(private readonly config: ConfigService) {}   // DI works now
  // ...
}
```

---

## 8. Swallowing an upstream failure to return success

Catching a downstream failure and returning `200` (or an empty result) makes the client believe the operation succeeded. The reward never lands, the notification never sends, and nobody finds out until a user complains.

```ts
// ❌ failure hidden behind a success response
@Post('complete')
async complete(@Body() dto: CompleteOrderDto) {
  const order = await this.orders.finalize(dto);
  try {
    await this.reward.grant(order.userId, order.points);
  } catch {
    // swallowed — client is told everything worked
  }
  return { status: 'completed' };
}
```

```ts
// ✅ let the translated HttpException propagate so the outcome is truthful
@Post('complete')
async complete(@Body() dto: CompleteOrderDto) {
  const order = await this.orders.finalize(dto);
  await this.reward.grant(order.userId, order.points);   // throws a 502/503 if reward fails
  return { status: 'completed' };
}
```

If the reward genuinely *should* be best-effort (the order completes regardless), that's a deliberate design choice — and it should be explicit: record the failure and signal partial success, don't silently drop it.

```ts
// ✅ deliberate best-effort: explicit, logged, and visible in the response
const order = await this.orders.finalize(dto);
let rewardGranted = true;
try {
  await this.reward.grant(order.userId, order.points);
} catch (error) {
  rewardGranted = false;
  this.logger.warn({ event: 'reward.grant.deferred', orderId: order.id, err: error }, 'reward failed; order still completed');
  // optionally enqueue a retry
}
return { status: 'completed', rewardGranted };
```

---

## The boundary test

For any `catch` in a service or controller, ask:

> *"If this error reaches the global filter exactly as I'm about to re-throw it, will the filter produce a truthful status and a safe message?"*

If the thing you're re-throwing is a raw library error (`AxiosError`, a driver error, a broker error), the answer is no — it becomes a mislabeled 500. Translate it into an `HttpException` with the right status and a `cause` first.
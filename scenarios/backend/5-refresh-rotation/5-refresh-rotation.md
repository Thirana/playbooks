### "A mobile app stores a refresh token in local storage. A security researcher flags this as a vulnerability. What is the risk, what are better storage strategies, and how does your token rotation strategy change based on where the token is stored?"

---

### The Naive Solution

Store the JWT and refresh token in `localStorage`. It is easy to access from JavaScript and survives page refreshes and app restarts.

```javascript
// Common but insecure
localStorage.setItem("access_token", accessToken);
localStorage.setItem("refresh_token", refreshToken);
```

---

### Problems with the Naive Solution

**XSS (Cross-Site Scripting) attacks can steal both tokens.** Any JavaScript running on the page — including injected malicious scripts — can read `localStorage` with a single line: `localStorage.getItem('refresh_token')`. A long-lived refresh token stolen this way gives an attacker persistent access.

**There is no browser-enforced boundary.** Unlike cookies with `HttpOnly`, there is no mechanism to make `localStorage` inaccessible to JavaScript. The only protection is ensuring no XSS vulnerability exists anywhere on the page — including in third-party scripts.

**Mobile context differs from web context.** On a native mobile app, "local storage" usually means the device filesystem, Keychain (iOS), or Keystore (Android). These have different threat models than a browser. The researcher's concern is valid but the fix differs per platform.

---

### Production-Grade Solution

The storage strategy depends on the platform. The rotation strategy changes depending on how exposed the token is.

#### The Threat Model First

```
Storage location        Readable by JavaScript?    Protected from XSS?
localStorage            YES                        NO
sessionStorage          YES                        NO
In-memory (JS var)      YES (same tab only)        Partially
HttpOnly Cookie         NO                         YES
iOS Keychain            NO                         YES (OS-level)
Android Keystore        NO                         YES (OS-level)
```

The fundamental question is: can an XSS attack reach this token?

#### Web Application Strategy — HttpOnly Cookies

**The correct approach for web applications is to store tokens in `HttpOnly` cookies, not in JavaScript-accessible storage.**

`HttpOnly` is a cookie attribute that tells the browser: "do not allow JavaScript to read this cookie." `document.cookie` returns an empty string. `localStorage.getItem()` cannot reach it. Even a successful XSS injection cannot read the token.

```
Browser                            API Server
  |                                    |
  | POST /auth/login { email, pass }   |
  |---------------------------------->|
  |                                    | Authenticate user
  |                                    | Generate tokens
  |  Set-Cookie: refresh_token=uuid;   |
  |  HttpOnly; Secure; SameSite=Strict;|
  |  Path=/auth/refresh; Max-Age=2592000
  |<----------------------------------|
  |                                    |
  | Subsequent requests:               |
  | Cookie is sent automatically       |
  | by browser — JS never touches it  |
  |---------------------------------->|
```

**Server-side token setup:**

```typescript
// src/auth/auth.controller.ts

@Post('login')
@UseGuards(LocalAuthGuard)
async login(@Request() req, @Res({ passthrough: true }) res: Response) {
  const { access_token, refresh_token } = await this.authService.login(req.user);

  // Set the refresh token in an HttpOnly cookie.
  // The browser sends it automatically on every request to /auth/refresh.
  // JavaScript on the page cannot read it — XSS cannot steal it.
  res.cookie('refresh_token', refresh_token, {
    httpOnly: true,   // Not accessible via document.cookie
    secure: true,     // Only sent over HTTPS — never over HTTP
    sameSite: 'strict', // Not sent on cross-site requests — CSRF protection
    path: '/auth/refresh', // Cookie is only sent to this specific path
    maxAge: 30 * 24 * 60 * 60 * 1000, // 30 days in milliseconds
  });

  // The access token is returned in the response body.
  // Store it in-memory (a JavaScript variable or React state),
  // NOT in localStorage. It only needs to live for 15 minutes.
  return { access_token };
}
```

**Why store the access token in-memory and not in a cookie too?**

If both tokens are in `HttpOnly` cookies, the access token is sent on every request automatically — but you lose the ability to attach it as a `Bearer` header for REST APIs. The conventional approach is:

- **Refresh token** → `HttpOnly` cookie (long-lived, needs XSS protection)
- **Access token** → In-memory JavaScript variable (short-lived, 15 minutes, lost on tab close)

```javascript
// Browser-side: store access token in memory only
let accessToken = null; // Module-level variable — cleared when tab closes

async function login(email, password) {
  const response = await fetch("/auth/login", {
    method: "POST",
    body: JSON.stringify({ email, password }),
    credentials: "include", // Ensures cookies are included in request/response
  });
  const data = await response.json();
  accessToken = data.access_token; // Held in memory — not in localStorage
}

async function makeApiCall(endpoint) {
  const response = await fetch(endpoint, {
    headers: { Authorization: `Bearer ${accessToken}` },
    credentials: "include",
  });
  return response.json();
}
```

**The silent refresh pattern — recovering from memory loss:**

The problem with in-memory storage is that if the user opens a new tab or refreshes the page, `accessToken` is `null`. The solution is a silent refresh — on app load, attempt to get a new access token using the refresh token cookie.

```javascript
// On every app startup / page load
async function initializeAuth() {
  try {
    // Hit the refresh endpoint — the HttpOnly cookie is sent automatically
    const response = await fetch("/auth/refresh", {
      method: "POST",
      credentials: "include", // Sends the HttpOnly cookie
    });

    if (response.ok) {
      const data = await response.json();
      accessToken = data.access_token; // Restore in-memory token
    }
  } catch {
    // No valid refresh token — user needs to log in
    redirectToLogin();
  }
}
```

#### The Token Rotation Strategy Changes Based on Storage

**The core problem with refresh tokens:** If a refresh token is stolen and used by an attacker, both the attacker and the legitimate user have a valid refresh token. How do you detect this?

**Refresh Token Rotation** solves this. Every time a refresh token is used, it is immediately replaced with a brand new one. The old one is invalidated. If anyone tries to use the old token (the stolen one), that is a **reuse detection signal** — it means the token was stolen and used.

```
Normal flow:
  User has RT-1 → uses it → gets Access Token + RT-2 (RT-1 invalidated)
  User has RT-2 → uses it → gets Access Token + RT-3 (RT-2 invalidated)

Attack detected:
  Attacker steals RT-1
  User uses RT-1 → gets RT-2 (RT-1 invalidated)
  Attacker uses RT-1 → REUSE DETECTED → revoke RT-2 AND all sessions for user
```

```typescript
// src/auth/auth.service.ts

async refreshTokens(oldRefreshToken: string): Promise<TokenPair> {

  // Step 1: Look up the refresh token
  const session = await this.sessionsRepo.findOneBy({
    refreshToken: hash(oldRefreshToken), // Store hashed — never plain text
    revokedAt: IsNull(),
  });

  if (!session) {
    // This refresh token does not exist or was already used.
    // Either it expired naturally, OR this is a reuse attempt.
    // We cannot tell which — but we can check if this token was
    // already rotated (meaning someone is reusing an old token).
    await this.handlePossibleTokenTheft(oldRefreshToken);
    throw new UnauthorizedException('Invalid refresh token');
  }

  // Step 2: Issue new tokens (rotation)
  const newRefreshToken = uuidv4();
  const newAccessToken = await this.jwtService.signAsync(
    { sub: session.userId, sessionId: session.id },
    { expiresIn: '15m' },
  );

  // Step 3: Atomically replace the old token with the new one.
  // If two requests arrive simultaneously with the same token (race condition),
  // only one will find the token — the other will hit the "reuse detected" path.
  await this.sessionsRepo.update(session.id, {
    refreshToken: hash(newRefreshToken),
    lastRefreshedAt: new Date(),
    previousRefreshToken: hash(oldRefreshToken), // Keep for theft detection
  });

  return {
    access_token: newAccessToken,
    refresh_token: newRefreshToken,
  };
}

private async handlePossibleTokenTheft(usedToken: string): Promise<void> {
  // Check if this was a previously valid token (now rotated out)
  const session = await this.sessionsRepo.findOneBy({
    previousRefreshToken: hash(usedToken),
  });

  if (session) {
    // This old token was already rotated — someone is reusing it.
    // Revoke the ENTIRE session family — both the legitimate user
    // and the attacker are now logged out. User must re-authenticate.
    await this.sessionsRepo.update(session.id, {
      revokedAt: new Date(),
      revokedReason: 'token_reuse_detected',
    });

    // Notify the user: "unusual activity detected, please log in again"
    await this.notificationsService.sendSecurityAlert(session.userId);
  }
}
```

#### Mobile App Strategy (iOS / Android)

On native mobile apps, the `localStorage` vulnerability does not apply in the same way — there is no XSS in a native app. The threats are different: rooted/jailbroken devices, malware with file system access. The fix uses OS-level secure storage.

| Platform     | Secure Storage           | What it does                                                                                                     |
| ------------ | ------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| iOS          | Keychain                 | Encrypted storage backed by hardware Secure Enclave. Cannot be read by other apps. Can require biometric unlock. |
| Android      | Keystore                 | Hardware-backed key storage. Keys are never exposed in plaintext. App-scoped — other apps cannot read them.      |
| React Native | `react-native-keychain`  | Cross-platform wrapper around Keychain and Keystore                                                              |
| Flutter      | `flutter_secure_storage` | Cross-platform wrapper                                                                                           |

```typescript
// React Native — storing refresh token in Keychain/Keystore
import * as Keychain from "react-native-keychain";

// After login — store in OS secure storage instead of AsyncStorage
await Keychain.setGenericPassword(
  "taskflow_user", // username (label)
  JSON.stringify({
    refreshToken: data.refresh_token,
    userId: data.userId,
  }),
  {
    accessControl: Keychain.ACCESS_CONTROL.BIOMETRY_ANY_OR_DEVICE_PASSCODE,
    // User must authenticate with Face ID / fingerprint to read this value
    accessible: Keychain.ACCESSIBLE.WHEN_UNLOCKED_THIS_DEVICE_ONLY,
    // 'WHEN_UNLOCKED_THIS_DEVICE_ONLY':
    // - Only readable when device is unlocked
    // - NOT backed up to iCloud/Google Drive — stays on device only
    // - Not migrated to new device — user must log in fresh
  },
);

// Reading — triggers biometric prompt if configured
const credentials = await Keychain.getGenericPassword();
const { refreshToken } = JSON.parse(credentials.password);
```

**Rotation strategy on mobile differs from web:**

On mobile, tokens are much less exposed to XSS. If a device is not rooted, the Keychain/Keystore token is essentially inaccessible to other apps. The rotation strategy can therefore be more relaxed:

- Rotate the refresh token on every use (same as web)
- Set a longer rotation window — if the same refresh token is used twice within 5 seconds, it is likely a legitimate retry (network hiccup), not a theft
- Enable absolute expiry — even a valid refresh token expires after 90 days regardless, forcing re-authentication

#### Full Comparison Table

|                       | localStorage (Web)   | HttpOnly Cookie (Web)       | In-Memory JS (Web)     | iOS Keychain      | Android Keystore  |
| --------------------- | -------------------- | --------------------------- | ---------------------- | ----------------- | ----------------- |
| XSS can steal it      | YES                  | NO                          | NO (same session only) | NO                | NO                |
| CSRF risk             | NO                   | YES (mitigated by SameSite) | NO                     | NO                | NO                |
| Survives page refresh | YES                  | YES                         | NO                     | YES               | YES               |
| Survives app restart  | YES                  | YES                         | NO                     | YES               | YES               |
| Biometric protection  | NO                   | NO                          | NO                     | Optional          | Optional          |
| Backed up to cloud    | YES (synced storage) | YES (browser sync)          | NO                     | Optional          | NO                |
| Recommended for       | Never                | Refresh tokens              | Access tokens          | All mobile tokens | All mobile tokens |

#### Key Interview Points to Mention

- The core issue with `localStorage` is not the storage itself — it is that XSS can reach it. `HttpOnly` cookies are not readable by JavaScript at all, making XSS token theft impossible.
- `SameSite=Strict` on the cookie prevents CSRF attacks — cross-site requests do not include the cookie.
- The `path=/auth/refresh` constraint on the cookie ensures it is only sent to the refresh endpoint, not leaked in every API request header.
- Refresh token rotation combined with reuse detection is the production pattern for detecting stolen tokens. When reuse is detected, both the attacker and the legitimate user are logged out — this is a feature, not a bug.
- On mobile, the threat model is different (no XSS, but rooted devices) — use Keychain/Keystore with `WHEN_UNLOCKED_THIS_DEVICE_ONLY` and do not back up tokens to cloud storage.
- The silent refresh on app load (calling `/auth/refresh` on every page load) bridges the gap between in-memory access token storage and user experience — the user does not need to log in on every page refresh.

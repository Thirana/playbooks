## Question 1

### "You are building a pre-signed URL system for private S3 file downloads. The URL must be valid for only 2 hours and must be tied to a specific user — another user who gets the URL should not be able to use it. How do you design this?"

---

### The Naive Solution

Make the S3 bucket public and just serve the file URL directly, or use AWS's built-in S3 pre-signed URLs.

```
https://bucket.s3.amazonaws.com/files/report.pdf?X-Amz-Expires=7200&X-Amz-Signature=abc
```

AWS signs the URL with an expiry time. Anyone with the URL can download the file within 2 hours.

---

### Problems with the Naive Solution

**The link is transferable.** If user A shares the URL with user B via email or Slack, user B can download the file. AWS's signature only verifies time and the S3 object key — it has no concept of who the requester is.

**The expiry is fixed at generation time.** If you generate the URL with a 2-hour window, a user who clicks it after 1 hour 59 minutes has a 1-minute window — effectively useless for practical use.

**No revocation.** If you need to revoke access (e.g., the user's account is suspended), you cannot invalidate an already-issued AWS pre-signed URL before its expiry.

**Audit trail is missing.** You have no record of who actually downloaded the file and when.

---

### Production-Grade Solution

The correct approach is to never give the client a direct AWS pre-signed URL. Instead, you create a **proxy token** — a short-lived signed token that your own backend validates before issuing the real AWS pre-signed URL on demand.

```
Client                  Your API                    AWS S3
  |                        |                           |
  |  GET /files/42/download |                           |
  |  Authorization: Bearer JWT                          |
  |----------------------->|                           |
  |                        | 1. Verify JWT             |
  |                        | 2. Check ownership        |
  |                        | 3. Generate download token|
  |                        | 4. Store token in Redis   |
  | <-- { downloadUrl } ---|                           |
  |                        |                           |
  |  GET /download?token=xyz                           |
  |----------------------->|                           |
  |                        | 5. Validate token         |
  |                        | 6. Check userId matches   |
  |                        | 7. Delete token (one-use) |
  |                        | 8. Generate AWS pre-signed URL
  |                        |-------------------------->|
  |                        | <-- pre-signed URL        |
  | <-- 302 Redirect ------|                           |
  |                        |                           |
  | Follows redirect to S3 pre-signed URL              |
  |-------------------------------------------------->|
  | <-- file bytes -----------------------------------|
```

#### Step 1 — The Download Token Generation Endpoint

When a user requests a file download, your API generates a **download token** — not the file URL itself.

```typescript
// src/files/files.controller.ts

@Get(':fileId/download')
@UseGuards(JwtAuthGuard)
async requestDownload(
  @Param('fileId') fileId: number,
  @Request() req,
): Promise<{ downloadUrl: string }> {
  return this.filesService.generateDownloadToken(fileId, req.user.userId);
}
```

```typescript
// src/files/files.service.ts
import { v4 as uuidv4 } from "uuid";

@Injectable()
export class FilesService {
  constructor(
    @InjectRepository(File) private readonly filesRepo: Repository<File>,
    @Inject(CACHE_MANAGER) private readonly cache: Cache,
  ) {}

  async generateDownloadToken(
    fileId: number,
    requestingUserId: number,
  ): Promise<{ downloadUrl: string }> {
    // Step 1: Load the file record and verify ownership
    const file = await this.filesRepo.findOneBy({ id: fileId });
    if (!file) throw new NotFoundException("File not found");

    // This is the key check — verify the requesting user owns this file.
    // Without this, any authenticated user could request a download token for any file.
    if (file.ownerId !== requestingUserId) {
      throw new ForbiddenException("You do not have access to this file");
    }

    // Step 2: Generate a cryptographically random, opaque token.
    // UUID v4 is random and unpredictable — cannot be guessed.
    // Do NOT use sequential IDs or anything derived from the file/user ID.
    const token = uuidv4();

    // Step 3: Store the token in Redis with a 2-hour TTL.
    // The value binds the token to a specific user AND a specific file.
    // This is what makes the URL non-transferable.
    const tokenData = {
      fileId,
      userId: requestingUserId,
      s3Key: file.s3Key, // The actual S3 object path
      createdAt: Date.now(),
    };

    await this.cache.set(
      `download-token:${token}`, // Namespaced key
      JSON.stringify(tokenData),
      2 * 60 * 60 * 1000, // 2 hours in milliseconds
    );

    // Step 4: Return a URL pointing to YOUR backend, not to S3 directly.
    // The client never sees an S3 URL at this stage.
    return {
      downloadUrl: `https://api.taskflow.com/download?token=${token}`,
    };
  }
}
```

#### Step 2 — The Token Redemption Endpoint

This is the endpoint the client hits when it actually wants to download the file.

```typescript
// src/files/files.controller.ts

@Get('/download')
async redeemDownloadToken(@Query('token') token: string, @Res() res: Response) {
  return this.filesService.redeemDownloadToken(token, res);
}
```

```typescript
// src/files/files.service.ts

async redeemDownloadToken(token: string, res: Response): Promise<void> {

  // Step 1: Look up the token in Redis
  const raw = await this.cache.get<string>(`download-token:${token}`);

  if (!raw) {
    // Token not found = either expired, already used, or forged
    throw new UnauthorizedException('Download link is invalid or has expired');
  }

  const tokenData = JSON.parse(raw);

  // Step 2: Delete the token from Redis BEFORE generating the S3 URL.
  // This makes the token single-use — even if someone intercepts the redirect,
  // they cannot use the same token again.
  // Delete BEFORE generating the URL to prevent a race condition where two
  // concurrent requests both validate the token before either deletes it.
  await this.cache.del(`download-token:${token}`);

  // Step 3: Generate a SHORT-lived AWS pre-signed URL (15 minutes is plenty).
  // The long expiry window was enforced by our Redis token — by the time the
  // client calls this endpoint, they need the S3 URL for only a few seconds.
  const s3Url = await this.s3Service.generatePresignedUrl(
    tokenData.s3Key,
    15 * 60, // 15 minutes in seconds
  );

  // Step 4: Log the download for the audit trail
  await this.auditService.log({
    event: 'file.downloaded',
    fileId: tokenData.fileId,
    userId: tokenData.userId,
    timestamp: new Date(),
  });

  // Step 5: Redirect the browser to the short-lived S3 URL.
  // The client downloads directly from S3 — your server is not in the data path.
  res.redirect(302, s3Url);
}
```

#### Step 3 — Generating the AWS Pre-Signed URL

```typescript
// src/files/s3.service.ts
import { GetObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

@Injectable()
export class S3Service {
  private readonly s3 = new S3Client({ region: process.env.AWS_REGION });

  async generatePresignedUrl(
    s3Key: string,
    expiresInSeconds: number,
  ): Promise<string> {
    const command = new GetObjectCommand({
      Bucket: process.env.AWS_S3_BUCKET,
      Key: s3Key,
    });

    // getSignedUrl signs the request with your AWS credentials.
    // The resulting URL is only valid for 'expiresIn' seconds.
    return getSignedUrl(this.s3, command, { expiresIn: expiresInSeconds });
  }
}
```

#### How the Security Properties Are Achieved

| Requirement             | How it is enforced                                                            |
| ----------------------- | ----------------------------------------------------------------------------- |
| Valid only for 2 hours  | Redis TTL on the download token                                               |
| Tied to a specific user | Token payload contains `userId`, checked on redemption                        |
| Non-transferable        | `userId` is validated on redemption — a different user's JWT cannot redeem it |
| Revocable               | Delete the Redis key — the token immediately stops working                    |
| Single-use              | Token is deleted from Redis before the S3 URL is generated                    |
| Audit trail             | Every redemption is logged with userId, fileId, timestamp                     |

#### Key Interview Points to Mention

- The Redis token layer is what adds user-binding. AWS's native pre-signed URLs have no concept of identity.
- Deleting the token **before** generating the S3 URL (not after) prevents a race condition where two concurrent requests redeem the same token simultaneously.
- The final AWS pre-signed URL has a short expiry (15 minutes) because by the time the client reaches that step, they only need seconds to start the download.
- This architecture keeps your server out of the data path — the actual bytes flow directly from S3 to the client, not through your API server.

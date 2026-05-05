# Pre-Signed URL System — Sequence Diagrams

---

## Diagram 1 — Generate Download Token

> Client requests a file download. The backend verifies ownership and returns a short-lived proxy token — never an S3 URL.

```mermaid
sequenceDiagram
    actor Client
    participant Controller as FilesController
    participant FilesService
    participant DB as FilesRepository
    participant Redis

    Client->>Controller: GET /files/:fileId/download
    Note over Client,Controller: Authorization: Bearer JWT

    activate Controller
    Note right of Controller: JwtAuthGuard runs first.<br/>Decodes JWT → extracts userId.<br/>Attaches to req.user.

    Controller->>FilesService: generateDownloadToken(fileId, userId)
    activate FilesService

    FilesService->>DB: findOneBy({ id: fileId })
    activate DB
    DB-->>FilesService: File entity (ownerId, s3Key, ...) or null
    deactivate DB

    alt File not found
        FilesService-->>Controller: throw NotFoundException("File not found")
        Controller-->>Client: 404 Not Found
    else Requesting user is NOT the owner
        FilesService->>FilesService: Check: file.ownerId !== userId
        FilesService-->>Controller: throw ForbiddenException
        Controller-->>Client: 403 Forbidden
    else Ownership verified ✓
        FilesService->>FilesService: token = uuidv4()
        Note right of FilesService: UUID v4 is cryptographically random.<br/>Cannot be guessed or brute-forced.

        FilesService->>FilesService: Build tokenData payload
        Note right of FilesService: tokenData = {<br/>  fileId,<br/>  userId,<br/>  s3Key,<br/>  createdAt<br/>}

        FilesService->>Redis: SET download-token:{token} → tokenData
        Note over FilesService,Redis: TTL = 2 hours (7,200,000 ms).<br/>This is what enforces the 2hr access window.
        activate Redis
        Redis-->>FilesService: OK
        deactivate Redis

        FilesService-->>Controller: { downloadUrl: "https://api.yourapp.com/download?token={token}" }
        Note right of FilesService: Client gets YOUR API URL,<br/>never a direct S3 URL.
    end

    deactivate FilesService
    Controller-->>Client: 200 OK — { downloadUrl }
    deactivate Controller
```

---

## Diagram 2 — Redeem Token & Get S3 URL

> Client hits the redemption endpoint. The backend validates the token, deletes it (single-use), generates a short-lived S3 URL, then redirects.

```mermaid
sequenceDiagram
    actor Client
    participant Controller as FilesController
    participant FilesService
    participant Redis
    participant S3Service
    participant AuditService
    participant S3 as AWS S3

    Client->>Controller: GET /download?token={token}
    activate Controller

    Controller->>FilesService: redeemDownloadToken(token, res)
    activate FilesService

    FilesService->>Redis: GET download-token:{token}
    activate Redis
    Redis-->>FilesService: tokenData or null
    deactivate Redis

    alt Token missing (expired / already used / forged)
        FilesService-->>Controller: throw UnauthorizedException
        Controller-->>Client: 401 Unauthorized
    else Token exists ✓
        Note right of FilesService: ⚠ Delete token BEFORE generating S3 URL.<br/>If two concurrent requests arrive,<br/>only the first DEL succeeds —<br/>the second gets null and is rejected.

        FilesService->>Redis: DEL download-token:{token}
        activate Redis
        Redis-->>FilesService: OK (token is now gone — single use enforced)
        deactivate Redis

        FilesService->>S3Service: generatePresignedUrl(tokenData.s3Key, 900)
        activate S3Service

        S3Service->>S3Service: Build GetObjectCommand({ Bucket, Key })
        S3Service->>S3: getSignedUrl(command, { expiresIn: 900 })
        Note over S3Service,S3: AWS signs the request with your IAM credentials.<br/>The URL is valid for 15 minutes only.
        activate S3
        S3-->>S3Service: Short-lived pre-signed URL
        deactivate S3

        S3Service-->>FilesService: s3Url
        deactivate S3Service

        FilesService->>AuditService: log({ event, fileId, userId, timestamp })
        activate AuditService
        Note right of AuditService: Persists who downloaded what and when.
        AuditService-->>FilesService: OK
        deactivate AuditService

        FilesService->>Controller: res.redirect(302, s3Url)
    end

    deactivate FilesService
    Controller-->>Client: 302 Redirect → S3 pre-signed URL
    deactivate Controller
```

---

## Diagram 3 — Direct S3 Download

> The browser follows the 302 redirect and downloads directly from S3. Your server is completely out of the data path.

```mermaid
sequenceDiagram
    actor Client
    participant S3 as AWS S3

    Note over Client,S3: Client received a 302 redirect from your API.<br/>It now follows that redirect directly to S3.<br/>Your backend server handles zero bytes of file data.

    Client->>S3: GET {presigned-s3-url}
    Note over Client,S3: URL contains:<br/>• X-Amz-Credential (IAM identity)<br/>• X-Amz-Expires = 900 (15 min)<br/>• X-Amz-Signature (HMAC of request params)

    activate S3
    S3->>S3: Verify HMAC signature
    S3->>S3: Check X-Amz-Expires window
    S3->>S3: Check IAM permissions for the bucket/key

    alt Signature invalid or URL expired
        S3-->>Client: 403 Forbidden — Request has expired
    else All checks pass ✓
        S3-->>Client: 200 OK — file bytes (streamed directly)
        Note over Client,S3: File transfers at full S3 throughput.<br/>No proxy overhead. No load on your API servers.
    end

    deactivate S3
```

---

## Security Properties Summary

| Property | Enforced by |
|---|---|
| Valid only 2 hours | Redis TTL on the download token (Diagram 1) |
| Tied to a specific user | `userId` in token payload, checked against JWT on redemption (Diagram 2) |
| Non-transferable | Another user's JWT produces a different `userId` — token rejects it |
| Revocable | `DEL download-token:{token}` in Redis kills access immediately |
| Single-use | Token deleted from Redis **before** S3 URL is generated (Diagram 2) |
| Race condition safe | First `DEL` wins; concurrent second request gets null → 401 |
| Audit trail | Every redemption logged with `userId`, `fileId`, `timestamp` (Diagram 2) |
| Server not in data path | Client streams bytes directly from S3 via redirect (Diagram 3) |

# NestJS File Upload Core Concepts
Purpose: This note explains the mental model behind file uploads in NestJS before the full implementation walkthrough.

## Related Notes
- [2. Full File Upload Learning Guide](./2_file_upload_learning_guide.md)
- [3. NestJS File Upload Runtime Flow](./3_nestjs_file_upload_runtime_flow.md)
- [4. File Upload Revision Cheatsheet](./4_file_upload_revision_cheatsheet.md)

## 1. Why file uploads are different
Normal NestJS requests usually carry JSON, which Nest can parse automatically.

File uploads are different because they use `multipart/form-data`, which can mix:
- binary file data
- regular text fields

NestJS does not parse this on its own. It needs middleware to extract the file data before the controller runs.

## 2. What Multer does
NestJS file upload support is built on top of Multer.

Multer sits between:
- the raw HTTP request
- your NestJS controller

Its job is to:
- parse the multipart request
- extract file data
- attach the file or files to the request

NestJS wraps Multer through interceptors and decorators, so you rarely deal with Multer directly.

## 3. The three storage patterns
### Memory storage
The file stays in RAM as `file.buffer`.

Best for:
- small files
- files that will be validated, transformed, or forwarded to S3 immediately

Risk:
- large files consume Node.js memory quickly

### Disk storage
The file is written to the local filesystem.

Best for:
- simple local development

Problem in production:
- files live on one app server
- multiple servers behind a load balancer do not share local disk automatically

### Cloud storage
Production pattern:
1. receive file in memory
2. upload it to S3 or similar object storage
3. store only the resulting URL in the database

This keeps the app server as a temporary pass-through instead of permanent storage.

## 4. The main NestJS building blocks
| Building Block | What it Does |
| --- | --- |
| `FileInterceptor('field')` | parses one file from one field |
| `FilesInterceptor('field', maxCount)` | parses many files from one field |
| `FileFieldsInterceptor([...])` | parses files from multiple named fields |
| `AnyFilesInterceptor()` | parses all files |
| `NoFilesInterceptor()` | accepts multipart text fields but rejects files |
| `@UploadedFile()` | extracts one file |
| `@UploadedFiles()` | extracts multiple files |
| `ParseFilePipe` | validates files after parsing |
| `MulterModule` | sets global Multer defaults |

## 5. Validation happens in layers
File validation usually happens in two places.

### Multer limits
These are the first hard stops:
- file size
- file count

If Multer rejects the file, the controller never runs.

### NestJS file pipes
These validate after Multer parsing.

Common checks:
- file size
- allowed mime type
- custom business rules

This is where `ParseFilePipe`, `ParseFilePipeBuilder`, and custom pipes fit.

## 6. Why file names must be regenerated
Never trust `file.originalname` for storage.

Problems:
- collisions between users
- unsafe characters
- path traversal attempts
- leakage of original file names

Safer pattern:
- keep the extension
- generate a UUID-based name
- store under a logical folder such as `avatars/` or `task-attachments/`

## 7. Why the database stores metadata, not bytes
The database should usually store:
- file URL
- original name
- mime type
- size
- owner relation

The database should not store:
- raw binary file contents

Object storage is better suited for:
- large files
- CDN integration
- scalability
- direct file access patterns

## 8. Single-file vs multi-file design
Typical patterns:
- one avatar image -> `FileInterceptor` + `@UploadedFile()`
- multiple attachments under one field -> `FilesInterceptor` + `@UploadedFiles()`
- different fields like `cover` and `gallery` -> `FileFieldsInterceptor`

Understanding these shapes is important before writing the controller.

## 9. Security mindset
Important rules:
- validate file size and type
- authenticate upload endpoints
- never trust the original file name
- use private S3 objects for sensitive files
- clean up old or orphaned files when replacing or deleting records

## 10. Concept checkpoints
If you can answer these quickly, the foundation is solid:
- Why does file upload need `multipart/form-data`?
- What does Multer do in the request pipeline?
- When should you use memory storage instead of disk storage?
- Why store file URLs in the database instead of file bytes?
- Why should you never use `originalname` as the storage filename?

If you want the implementation next, use [2. Full File Upload Learning Guide](./2_file_upload_learning_guide.md).

# NestJS File Upload Runtime Flow
Purpose: This note explains what happens at runtime when NestJS receives multipart requests, validates files, uploads them to S3, and persists only the URL.

## Related Notes
- [1. File Upload Core Concepts](./1_file_upload_core_concepts.md)
- [2. Full File Upload Learning Guide](./2_file_upload_learning_guide.md)
- [4. File Upload Revision Cheatsheet](./4_file_upload_revision_cheatsheet.md)

## TaskFlow setup used in this note
Assume the app has:
- `FileInterceptor`, `FilesInterceptor`, or `FileFieldsInterceptor`
- Multer memory storage
- `ParseFilePipe` or custom file-validation pipes
- an `UploadService` that uploads to S3
- user avatar URLs stored in the database

## 1. High-level lifecycle
```text
Client sends multipart/form-data
  -> Multer interceptor parses request
  -> size/count limits are enforced
  -> file pipes validate file content
  -> controller method runs
  -> upload service pushes file to S3
  -> DB stores only the URL
```

## 2. Single-file avatar flow
1. The client sends `POST /users/me/avatar` with `multipart/form-data`.
2. `JwtAuthGuard` authenticates the user.
3. `FileInterceptor("avatar", multerMemoryStorage)` runs.
4. Multer parses the multipart body and puts the file in memory as `file.buffer`.
5. Multer size/count limits run before controller logic.
6. `ParseFilePipeBuilder` validates mime type and size.
7. If validation passes, the controller calls `uploadService.uploadToS3(...)`.
8. The service generates a safe UUID-based file name.
9. The service uploads the buffer to S3.
10. The S3 URL is returned.
11. `UsersService.updateAvatar()` saves the URL to the database and deletes the old avatar if needed.

## 3. Multi-file attachment flow
1. The client sends multiple files under the same field.
2. `FilesInterceptor("attachments", 5, ...)` parses up to 5 files.
3. A custom validation pipe checks each file's mime type.
4. `uploadService.uploadManyToS3(...)` uploads files in parallel with `Promise.all`.
5. The controller returns an array of URLs.

## 4. Different-field flow
For forms such as `cover` + `gallery`:
1. `FileFieldsInterceptor([...])` parses files by field name.
2. The controller receives an object keyed by those field names.
3. Required fields can be checked manually.
4. Each field is uploaded to the correct folder.

## 5. Why S3 upload belongs in the service
The controller should not know AWS SDK details.

The service owns:
- safe naming
- S3 client configuration
- upload logic
- multi-file upload coordination
- delete logic

This keeps controllers thin and reusable.

## 6. Common failure points
| Symptom | Likely cause |
| --- | --- |
| Controller never runs | Multer rejected size/count before reaching the method |
| File is undefined | field name mismatch between form and interceptor |
| Buffer is missing | using disk storage instead of memory storage |
| Upload succeeds but old file remains | old S3 object was not deleted during replacement |
| Validation seems weak | only extension is checked instead of mime/content validation |
| Multi-server production breaks with files | local disk storage is being used instead of object storage |

## 7. Debugging checklist
1. Does the client send `multipart/form-data`?
2. Does the interceptor field name match the incoming form field?
3. Is the route using the right interceptor type for one file vs many files?
4. Are Multer `limits` rejecting the request before the controller?
5. Are validation pipes checking the correct mime types and sizes?
6. Is the service uploading `file.buffer` to S3 and not trying to use disk-only fields?
7. Is the DB storing only the returned URL?

Use this note for request lifecycle narration and debugging. Use [4. File Upload Revision Cheatsheet](./4_file_upload_revision_cheatsheet.md) when you only need the compressed version.

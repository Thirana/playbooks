# File Upload Revision Cheatsheet
Purpose: This is the shortest note in the set. Use it for quick recall, interview prep, and fast implementation review.

## Related Notes
- [1. File Upload Core Concepts](./1_file_upload_core_concepts.md)
- [2. Full File Upload Learning Guide](./2_file_upload_learning_guide.md)
- [3. NestJS File Upload Runtime Flow](./3_nestjs_file_upload_runtime_flow.md)

## Memorize These First
- file uploads use `multipart/form-data`
- Multer parses the multipart request
- `memoryStorage` is the usual pass-through pattern for S3
- validate type and size before uploading
- generate safe UUID-based file names
- store file URLs in the database, not raw bytes

## Main NestJS building blocks
| Tool | Use it for |
| --- | --- |
| `FileInterceptor('field')` | one file |
| `FilesInterceptor('field', maxCount)` | many files under one field |
| `FileFieldsInterceptor([...])` | files from multiple field names |
| `AnyFilesInterceptor()` | any files |
| `NoFilesInterceptor()` | multipart text fields only |
| `@UploadedFile()` | extract one file |
| `@UploadedFiles()` | extract many files |
| `ParseFilePipe` | validate parsed files |

## Validation reminders
- Multer `limits` are the first hard stop
- `ParseFilePipe` or `ParseFilePipeBuilder` handles common validation
- custom pipes are useful for file arrays or richer rules

## `Express.Multer.File` reminders
- `buffer` exists with `memoryStorage`
- `destination`, `filename`, and `path` are disk-storage-oriented
- `originalname` is untrusted input
- `mimetype` and `size` are common validation fields

## Interceptor quick reference
| Scenario | Interceptor | Decorator |
| --- | --- | --- |
| One file, one field | `FileInterceptor('field')` | `@UploadedFile()` |
| Many files, same field | `FilesInterceptor('field', maxCount)` | `@UploadedFiles()` |
| Many files, different fields | `FileFieldsInterceptor([{ name, maxCount }])` | `@UploadedFiles()` |
| Any files | `AnyFilesInterceptor()` | `@UploadedFiles()` |
| Multipart body, no files | `NoFilesInterceptor()` | `@Body()` |

## Common mistakes
- wrong field name between form and interceptor
- using local disk in a multi-server production setup
- trusting `originalname`
- storing binary files in the relational database
- skipping size limits
- leaving old S3 files behind when replacing records

## Interview flash answers
**Why is `multipart/form-data` needed?**
- because binary files cannot be handled like normal JSON request bodies

**`memoryStorage` vs `diskStorage`?**
- memory keeps the file in RAM for pass-through processing
- disk writes the file to local server storage

**Why not use `originalname`?**
- it is client-controlled and unsafe for real storage naming

## Last-minute recall
- Multer parses
- pipes validate
- service uploads
- DB stores URL

# NestJS File Upload
Purpose: This is the long-form implementation guide for handling file uploads in NestJS with Multer and S3.

## Related Notes
- [1. File Upload Core Concepts](./1_file_upload_core_concepts.md)
- [3. NestJS File Upload Runtime Flow](./3_nestjs_file_upload_runtime_flow.md)
- [4. File Upload Revision Cheatsheet](./4_file_upload_revision_cheatsheet.md)

## The User Story
TaskFlow needs two upload features:

- users can upload a profile avatar; only JPEG/PNG up to 2MB
- users can upload up to 5 task attachments; each file up to 10MB

The files should go to S3, not local disk, and the database should store only the resulting URLs.

## How To Use This Note
- Read this file for the full implementation walkthrough.
- Use [1. File Upload Core Concepts](./1_file_upload_core_concepts.md) for the ideas first.
- Use [3. NestJS File Upload Runtime Flow](./3_nestjs_file_upload_runtime_flow.md) for lifecycle and debugging.
- Use [4. File Upload Revision Cheatsheet](./4_file_upload_revision_cheatsheet.md) for quick revision.

## Part 1: Project setup
### Install dependencies
```bash
npm install --save-dev @types/multer
npm install --save @aws-sdk/client-s3 @aws-sdk/lib-storage
npm install --save uuid
npm install --save-dev @types/uuid
```

### File structure
```text
src/
  upload/
    upload.module.ts
    upload.controller.ts
    upload.service.ts
    storage/
      multer-memory.storage.ts
    pipes/
      file-type-validation.pipe.ts
    dto/
      upload-response.dto.ts
  users/
    users.controller.ts
  tasks/
    tasks.controller.ts
```

## Part 2: Multer storage configuration
For the S3 pattern, use memory storage so the file is available in RAM and can be uploaded immediately.

**`src/upload/storage/multer-memory.storage.ts`**
```typescript
import { MulterOptions } from "@nestjs/platform-express/multer/interfaces/multer-options.interface";
import { memoryStorage } from "multer";

export const multerMemoryStorage: MulterOptions = {
  storage: memoryStorage(),
  limits: {
    fileSize: 10 * 1024 * 1024,
    files: 5,
  },
};
```

Key points:
- `memoryStorage()` gives you `file.buffer`
- `limits` are enforced before controller logic runs
- this is the first defense against oversized uploads

## Part 3: Upload service with S3
The service handles:
- safe file naming
- S3 upload
- multi-file upload
- file deletion

**`src/upload/upload.service.ts`**
```typescript
import {
  Injectable,
  InternalServerErrorException,
  Logger,
} from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { DeleteObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { Upload } from "@aws-sdk/lib-storage";
import * as path from "path";
import { v4 as uuidv4 } from "uuid";

@Injectable()
export class UploadService {
  private readonly logger = new Logger(UploadService.name);
  private readonly s3Client: S3Client;
  private readonly bucketName: string;

  constructor(private readonly configService: ConfigService) {
    this.s3Client = new S3Client({
      region: this.configService.get<string>("AWS_REGION"),
      credentials: {
        accessKeyId: this.configService.get<string>("AWS_ACCESS_KEY_ID"),
        secretAccessKey: this.configService.get<string>("AWS_SECRET_ACCESS_KEY"),
      },
    });

    this.bucketName = this.configService.get<string>("AWS_S3_BUCKET");
  }

  async uploadToS3(
    file: Express.Multer.File,
    folder: string,
  ): Promise<string> {
    const ext = path.extname(file.originalname).toLowerCase();
    const safeFileName = `${folder}/${uuidv4()}${ext}`;

    try {
      const upload = new Upload({
        client: this.s3Client,
        params: {
          Bucket: this.bucketName,
          Key: safeFileName,
          Body: file.buffer,
          ContentType: file.mimetype,
          ACL: "public-read",
        },
      });

      await upload.done();
      const fileUrl = `https://${this.bucketName}.s3.amazonaws.com/${safeFileName}`;
      this.logger.log(`File uploaded to S3: ${safeFileName}`);
      return fileUrl;
    } catch (error) {
      this.logger.error("S3 upload failed", error.stack);
      throw new InternalServerErrorException("File upload failed");
    }
  }

  async uploadManyToS3(
    files: Express.Multer.File[],
    folder: string,
  ): Promise<string[]> {
    return Promise.all(files.map((file) => this.uploadToS3(file, folder)));
  }

  async deleteFromS3(fileUrl: string): Promise<void> {
    const key = fileUrl.split(".amazonaws.com/")[1];
    if (!key) return;

    try {
      await this.s3Client.send(
        new DeleteObjectCommand({
          Bucket: this.bucketName,
          Key: key,
        }),
      );
      this.logger.log(`File deleted from S3: ${key}`);
    } catch (error) {
      this.logger.error(`Failed to delete S3 file: ${key}`, error.stack);
    }
  }
}
```

Important rules:
- never store with `originalname`
- generate a UUID-based name
- upload service owns S3 logic, not controllers

## Part 4: File validation
### Built-in validation with `ParseFilePipe`
For a single avatar upload:

```typescript
@UploadedFile(
  new ParseFilePipeBuilder()
    .addFileTypeValidator({ fileType: /image\/(jpeg|png)/ })
    .addMaxSizeValidator({ maxSize: 2 * 1024 * 1024 })
    .build({ errorHttpStatusCode: HttpStatus.UNPROCESSABLE_ENTITY }),
)
file: Express.Multer.File
```

This validates:
- mime type
- max file size

### Custom validation pipe for file arrays
**`src/upload/pipes/file-type-validation.pipe.ts`**
```typescript
import {
  Injectable,
  PipeTransform,
  UnprocessableEntityException,
} from "@nestjs/common";

@Injectable()
export class FilesTypeValidationPipe implements PipeTransform {
  constructor(private readonly allowedMimeTypes: RegExp) {}

  transform(files: Express.Multer.File[]): Express.Multer.File[] {
    if (!files || files.length === 0) {
      throw new UnprocessableEntityException("No files provided");
    }

    for (const file of files) {
      if (!this.allowedMimeTypes.test(file.mimetype)) {
        throw new UnprocessableEntityException(
          `File type not allowed: ${file.mimetype}`,
        );
      }
    }

    return files;
  }
}
```

Use a custom pipe when the built-in validators are not enough, especially for file arrays or more specialized rules.

## Part 5: Upload controller patterns
**`src/upload/upload.controller.ts`**
```typescript
import {
  BadRequestException,
  Body,
  Controller,
  HttpStatus,
  Post,
  UploadedFile,
  UploadedFiles,
  UseGuards,
  UseInterceptors,
  ParseFilePipeBuilder,
} from "@nestjs/common";
import {
  FileFieldsInterceptor,
  FileInterceptor,
  FilesInterceptor,
  NoFilesInterceptor,
} from "@nestjs/platform-express";
import { JwtAuthGuard } from "../auth/jwt-auth.guard";
import { FilesTypeValidationPipe } from "./pipes/file-type-validation.pipe";
import { multerMemoryStorage } from "./storage/multer-memory.storage";
import { UploadService } from "./upload.service";

@UseGuards(JwtAuthGuard)
@Controller("upload")
export class UploadController {
  constructor(private readonly uploadService: UploadService) {}

  @Post("avatar")
  @UseInterceptors(FileInterceptor("avatar", multerMemoryStorage))
  async uploadAvatar(
    @UploadedFile(
      new ParseFilePipeBuilder()
        .addFileTypeValidator({ fileType: /image\/(jpeg|png)/ })
        .addMaxSizeValidator({ maxSize: 2 * 1024 * 1024 })
        .build({ errorHttpStatusCode: HttpStatus.UNPROCESSABLE_ENTITY }),
    )
    file: Express.Multer.File,
  ) {
    const url = await this.uploadService.uploadToS3(file, "avatars");
    return { url };
  }

  @Post("attachments")
  @UseInterceptors(FilesInterceptor("attachments", 5, multerMemoryStorage))
  async uploadAttachments(
    @UploadedFiles(
      new FilesTypeValidationPipe(
        /image\/(jpeg|png)|application\/(pdf|msword)/,
      ),
    )
    files: Express.Multer.File[],
  ) {
    const urls = await this.uploadService.uploadManyToS3(
      files,
      "task-attachments",
    );
    return { urls };
  }

  @Post("product-images")
  @UseInterceptors(
    FileFieldsInterceptor(
      [
        { name: "cover", maxCount: 1 },
        { name: "gallery", maxCount: 4 },
      ],
      multerMemoryStorage,
    ),
  )
  async uploadProductImages(
    @UploadedFiles()
    files: {
      cover?: Express.Multer.File[];
      gallery?: Express.Multer.File[];
    },
  ) {
    if (!files.cover?.[0]) {
      throw new BadRequestException("Cover image is required");
    }

    const coverUrl = await this.uploadService.uploadToS3(
      files.cover[0],
      "covers",
    );
    const galleryUrls = files.gallery
      ? await this.uploadService.uploadManyToS3(files.gallery, "gallery")
      : [];

    return { coverUrl, galleryUrls };
  }

  @Post("metadata-only")
  @UseInterceptors(NoFilesInterceptor())
  async uploadMetadata(@Body() body: { title: string; description: string }) {
    return { received: body };
  }
}
```

This covers the main controller patterns:
- one file
- many files under one field
- many files under different fields
- multipart body without files

## Part 6: Integrate avatar upload into users flow
The generic upload endpoint is useful, but real apps often save the returned URL into a user record.

**`src/users/users.controller.ts`**
```typescript
import {
  Controller,
  HttpStatus,
  ParseFilePipeBuilder,
  Post,
  Request,
  UploadedFile,
  UseGuards,
  UseInterceptors,
} from "@nestjs/common";
import { FileInterceptor } from "@nestjs/platform-express";
import { JwtAuthGuard } from "../auth/jwt-auth.guard";
import { multerMemoryStorage } from "../upload/storage/multer-memory.storage";
import { UploadService } from "../upload/upload.service";
import { UsersService } from "./users.service";

@UseGuards(JwtAuthGuard)
@Controller("users")
export class UsersController {
  constructor(
    private readonly uploadService: UploadService,
    private readonly usersService: UsersService,
  ) {}

  @Post("me/avatar")
  @UseInterceptors(FileInterceptor("avatar", multerMemoryStorage))
  async uploadAvatar(
    @Request() req,
    @UploadedFile(
      new ParseFilePipeBuilder()
        .addFileTypeValidator({ fileType: /image\/(jpeg|png)/ })
        .addMaxSizeValidator({ maxSize: 2 * 1024 * 1024 })
        .build({ errorHttpStatusCode: HttpStatus.UNPROCESSABLE_ENTITY }),
    )
    file: Express.Multer.File,
  ) {
    const avatarUrl = await this.uploadService.uploadToS3(file, "avatars");
    await this.usersService.updateAvatar(req.user.userId, avatarUrl);
    return { avatarUrl };
  }
}
```

**`src/users/users.service.ts`**
```typescript
async updateAvatar(userId: number, avatarUrl: string): Promise<void> {
  const user = await this.findById(userId);

  if (user.avatarUrl) {
    await this.uploadService.deleteFromS3(user.avatarUrl);
  }

  await this.usersRepository.update(userId, { avatarUrl });
}
```

Important rule:
- the database stores the URL
- S3 stores the actual file

## Part 7: Global Multer defaults
If many routes use the same basic settings, configure Multer globally.

**`src/app.module.ts`**
```typescript
import { Module } from "@nestjs/common";
import { ConfigModule, ConfigService } from "@nestjs/config";
import { MulterModule } from "@nestjs/platform-express";
import { memoryStorage } from "multer";

@Module({
  imports: [
    MulterModule.registerAsync({
      imports: [ConfigModule],
      inject: [ConfigService],
      useFactory: (configService: ConfigService) => ({
        storage: memoryStorage(),
        limits: {
          fileSize: configService.get<number>(
            "UPLOAD_MAX_SIZE",
            10 * 1024 * 1024,
          ),
        },
      }),
    }),
  ],
})
export class AppModule {}
```

Route-level interceptors can still override these defaults.

## Part 8: The `Express.Multer.File` object
Typical shape:
```typescript
{
  fieldname: "avatar",
  originalname: "my-photo.jpg",
  encoding: "7bit",
  mimetype: "image/jpeg",
  buffer: Buffer<...>,
  size: 204800,
  destination: "./uploads",
  filename: "abc123.jpg",
  path: "./uploads/abc123.jpg",
}
```

Important details:
- `buffer` exists with `memoryStorage`
- `destination`, `filename`, and `path` are disk-storage-oriented
- `originalname` should never be trusted for final storage naming

## Part 9: Production reminders
- never use `originalname` as the final file name
- validate both file size and type
- store URLs in the database, not file bytes
- use private S3 objects for sensitive files
- authenticate upload endpoints
- clean up old S3 objects when replacing files
- set Multer size limits to avoid memory abuse

## Quick File Map
| File | Purpose |
| --- | --- |
| `upload/storage/multer-memory.storage.ts` | Multer memory config with limits |
| `upload/upload.service.ts` | S3 upload, multi-upload, delete logic |
| `upload/upload.controller.ts` | common upload controller patterns |
| `upload/pipes/file-type-validation.pipe.ts` | custom validation for file arrays |
| `users/users.controller.ts` | avatar upload endpoint |
| `users/users.service.ts` | saves avatar URL and deletes old S3 object |
| `app.module.ts` | optional global Multer defaults |

## Final Revision Anchors
- Multer parses `multipart/form-data`
- `memoryStorage` is the usual pass-through for S3 uploads
- validate before uploading
- generate safe file names
- store file URLs in the database, not raw bytes

For the runtime story, go to [3. NestJS File Upload Runtime Flow](./3_nestjs_file_upload_runtime_flow.md). For quick recall, go to [4. File Upload Revision Cheatsheet](./4_file_upload_revision_cheatsheet.md).

# NestJS Database Integration with TypeORM
Purpose: This is the long-form implementation guide for integrating PostgreSQL into a NestJS application with TypeORM.

## Related Notes
- [1. DB Integration Core Concepts](./1_db_core_concepts.md)
- [3. NestJS TypeORM Runtime Flow](./3_nestjs_typeorm_runtime_flow.md)
- [4. DB Integration Revision Cheatsheet](./4_db_integration_revision_cheatsheet.md)

## The User Story
TaskFlow currently stores users and tasks in memory. Data disappears on restart and there is no real relational model behind the app.

The new requirements are:
- users must persist in `users`
- tasks must persist in `tasks`
- each task belongs to one user
- tasks support labels through many-to-many
- creating a task with labels must be atomic
- production schema changes must use migrations

## How To Use This Note
- Read this file for the full implementation walkthrough.
- Use [1. DB Integration Core Concepts](./1_db_core_concepts.md) for the ideas first.
- Use [3. NestJS TypeORM Runtime Flow](./3_nestjs_typeorm_runtime_flow.md) for startup, repository, and transaction flow.
- Use [4. DB Integration Revision Cheatsheet](./4_db_integration_revision_cheatsheet.md) for quick revision.

## Part 1: Setup
### Install dependencies
```bash
npm install --save @nestjs/typeorm typeorm pg
npm install --save-dev ts-node tsconfig-paths
```

### File structure
```text
src/
  database/
    data-source.ts
  users/
    user.entity.ts
    users.module.ts
    users.service.ts
  tasks/
    task.entity.ts
    label.entity.ts
    tasks.module.ts
    tasks.service.ts
  config/
    app.config.ts
    database.config.ts
  app.module.ts
migrations/
  1714000000000-CreateUsersTable.ts
```

## Part 2: Wire TypeORM into `AppModule`
Use `forRootAsync()` so DB credentials come from config, not source code.

**`src/app.module.ts`**
```typescript
import { Module } from "@nestjs/common";
import { ConfigModule, ConfigService } from "@nestjs/config";
import { TypeOrmModule } from "@nestjs/typeorm";
import appConfig from "./config/app.config";
import databaseConfig from "./config/database.config";

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      load: [appConfig, databaseConfig],
    }),
    TypeOrmModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (configService: ConfigService) => ({
        type: "postgres",
        host: configService.getOrThrow<string>("database.host"),
        port: configService.getOrThrow<number>("database.port"),
        username: configService.getOrThrow<string>("database.user"),
        password: configService.getOrThrow<string>("database.password"),
        database: configService.getOrThrow<string>("database.name"),
        autoLoadEntities: true,
        synchronize:
          configService.getOrThrow<string>("app.nodeEnv") !== "production",
      }),
    }),
  ],
})
export class AppModule {}
```

Key points:
- `forRootAsync()` keeps credentials out of source code
- `autoLoadEntities: true` removes root-module entity clutter
- production should not use `synchronize`

## Part 3: Define the entities
### User entity
**`src/users/user.entity.ts`**
```typescript
import {
  Column,
  CreateDateColumn,
  Entity,
  OneToMany,
  PrimaryGeneratedColumn,
  UpdateDateColumn,
} from "typeorm";
import { Task } from "../tasks/task.entity";

@Entity("users")
export class User {
  @PrimaryGeneratedColumn()
  id: number;

  @Column({ unique: true })
  email: string;

  @Column({ select: false })
  password: string;

  @Column({ default: "user" })
  role: string;

  @Column({ default: true })
  isActive: boolean;

  @CreateDateColumn()
  createdAt: Date;

  @UpdateDateColumn()
  updatedAt: Date;

  @OneToMany(() => Task, (task) => task.user)
  tasks: Task[];
}
```

### Label entity
**`src/tasks/label.entity.ts`**
```typescript
import { Column, Entity, ManyToMany, PrimaryGeneratedColumn } from "typeorm";
import { Task } from "./task.entity";

@Entity("labels")
export class Label {
  @PrimaryGeneratedColumn()
  id: number;

  @Column({ unique: true })
  name: string;

  @ManyToMany(() => Task, (task) => task.labels)
  tasks: Task[];
}
```

### Task entity
**`src/tasks/task.entity.ts`**
```typescript
import {
  Column,
  CreateDateColumn,
  Entity,
  JoinColumn,
  JoinTable,
  ManyToMany,
  ManyToOne,
  PrimaryGeneratedColumn,
  UpdateDateColumn,
} from "typeorm";
import { User } from "../users/user.entity";
import { Label } from "./label.entity";

export enum TaskStatus {
  OPEN = "open",
  IN_PROGRESS = "in_progress",
  DONE = "done",
}

@Entity("tasks")
export class Task {
  @PrimaryGeneratedColumn()
  id: number;

  @Column()
  title: string;

  @Column({ nullable: true })
  description: string;

  @Column({ type: "enum", enum: TaskStatus, default: TaskStatus.OPEN })
  status: TaskStatus;

  @CreateDateColumn()
  createdAt: Date;

  @UpdateDateColumn()
  updatedAt: Date;

  @ManyToOne(() => User, (user) => user.tasks, {
    onDelete: "CASCADE",
    eager: false,
  })
  @JoinColumn({ name: "userId" })
  user: User;

  @Column()
  userId: number;

  @ManyToMany(() => Label, (label) => label.tasks, { cascade: true })
  @JoinTable({
    name: "tasks_labels",
    joinColumn: { name: "taskId", referencedColumnName: "id" },
    inverseJoinColumn: { name: "labelId", referencedColumnName: "id" },
  })
  labels: Label[];
}
```

Keep `userId` alongside `user` because owner checks and filters often only need the foreign key.

## Part 4: Register entities in feature modules
**`src/users/users.module.ts`**
```typescript
import { Module } from "@nestjs/common";
import { TypeOrmModule } from "@nestjs/typeorm";
import { User } from "./user.entity";
import { UsersService } from "./users.service";

@Module({
  imports: [TypeOrmModule.forFeature([User])],
  providers: [UsersService],
  exports: [UsersService],
})
export class UsersModule {}
```

**`src/tasks/tasks.module.ts`**
```typescript
import { Module } from "@nestjs/common";
import { TypeOrmModule } from "@nestjs/typeorm";
import { Label } from "./label.entity";
import { Task } from "./task.entity";
import { TasksService } from "./tasks.service";

@Module({
  imports: [TypeOrmModule.forFeature([Task, Label])],
  providers: [TasksService],
})
export class TasksModule {}
```

`forFeature()` is what makes those repositories injectable.

## Part 5: Use repositories in services
### UsersService
**`src/users/users.service.ts`**
```typescript
import {
  ConflictException,
  Injectable,
  NotFoundException,
} from "@nestjs/common";
import { InjectRepository } from "@nestjs/typeorm";
import { Repository } from "typeorm";
import * as bcrypt from "bcrypt";
import { User } from "./user.entity";

@Injectable()
export class UsersService {
  constructor(
    @InjectRepository(User)
    private readonly usersRepository: Repository<User>,
  ) {}

  async create(email: string, password: string): Promise<User> {
    const existing = await this.usersRepository.findOneBy({ email });
    if (existing) {
      throw new ConflictException("Email already in use");
    }

    const hashed = await bcrypt.hash(password, 10);
    const user = this.usersRepository.create({ email, password: hashed });
    return this.usersRepository.save(user);
  }

  async findByEmail(email: string): Promise<User | null> {
    return this.usersRepository
      .createQueryBuilder("user")
      .addSelect("user.password")
      .where("user.email = :email", { email })
      .getOne();
  }

  async findById(id: number): Promise<User> {
    const user = await this.usersRepository.findOneBy({ id });
    if (!user) {
      throw new NotFoundException(`User ${id} not found`);
    }
    return user;
  }
}
```

### TasksService
**`src/tasks/tasks.service.ts`**
```typescript
import { Injectable, NotFoundException } from "@nestjs/common";
import { InjectRepository } from "@nestjs/typeorm";
import { DataSource, Repository } from "typeorm";
import { Label } from "./label.entity";
import { Task, TaskStatus } from "./task.entity";

@Injectable()
export class TasksService {
  constructor(
    @InjectRepository(Task)
    private readonly tasksRepository: Repository<Task>,
    @InjectRepository(Label)
    private readonly labelsRepository: Repository<Label>,
    private readonly dataSource: DataSource,
  ) {}

  async findAllForUser(userId: number): Promise<Task[]> {
    return this.tasksRepository.find({
      where: { userId },
      relations: ["labels"],
      order: { createdAt: "DESC" },
    });
  }

  async findOne(id: number, userId: number): Promise<Task> {
    const task = await this.tasksRepository.findOne({
      where: { id, userId },
      relations: ["labels"],
    });
    if (!task) {
      throw new NotFoundException(`Task ${id} not found`);
    }
    return task;
  }

  async createWithLabels(
    userId: number,
    title: string,
    description: string,
    labelNames: string[],
  ): Promise<Task> {
    const queryRunner = this.dataSource.createQueryRunner();
    await queryRunner.connect();
    await queryRunner.startTransaction();

    try {
      const task = queryRunner.manager.create(Task, {
        title,
        description,
        userId,
        status: TaskStatus.OPEN,
      });
      const savedTask = await queryRunner.manager.save(task);

      const labels: Label[] = [];
      for (const name of labelNames) {
        let label = await queryRunner.manager.findOneBy(Label, { name });
        if (!label) {
          label = queryRunner.manager.create(Label, { name });
          label = await queryRunner.manager.save(label);
        }
        labels.push(label);
      }

      savedTask.labels = labels;
      const result = await queryRunner.manager.save(savedTask);
      await queryRunner.commitTransaction();
      return result;
    } catch (error) {
      await queryRunner.rollbackTransaction();
      throw error;
    } finally {
      await queryRunner.release();
    }
  }
}
```

Key points:
- `create()` builds an entity in memory
- `save()` persists it
- `findOne()` is useful when `relations` are needed
- all transaction queries must use `queryRunner.manager`

## Part 6: QueryBuilder when `find()` is not enough
**`src/tasks/tasks.service.ts`**
```typescript
async findByStatusWithLabels(
  userId: number,
  status: TaskStatus,
): Promise<Task[]> {
  return this.tasksRepository
    .createQueryBuilder("task")
    .leftJoinAndSelect("task.labels", "label")
    .where("task.userId = :userId", { userId })
    .andWhere("task.status = :status", { status })
    .orderBy("task.createdAt", "DESC")
    .getMany();
}

async searchByTitle(userId: number, keyword: string): Promise<Task[]> {
  return this.tasksRepository
    .createQueryBuilder("task")
    .where("task.userId = :userId", { userId })
    .andWhere("LOWER(task.title) LIKE LOWER(:keyword)", {
      keyword: `%${keyword}%`,
    })
    .getMany();
}
```

Always use parameters, not string interpolation.

## Part 7: Migrations
### CLI `DataSource`
**`src/database/data-source.ts`**
```typescript
import * as dotenv from "dotenv";
import { DataSource } from "typeorm";

dotenv.config();

export const AppDataSource = new DataSource({
  type: "postgres",
  host: process.env.DATABASE_HOST,
  port: parseInt(process.env.DATABASE_PORT ?? "5432", 10),
  username: process.env.DATABASE_USER,
  password: process.env.DATABASE_PASSWORD,
  database: process.env.DATABASE_NAME,
  entities: ["src/**/*.entity.ts"],
  migrations: ["migrations/*.ts"],
  synchronize: false,
});
```

This file exists because the TypeORM CLI runs outside NestJS DI.

### `package.json` scripts
```json
{
  "scripts": {
    "typeorm": "ts-node -r tsconfig-paths/register ./node_modules/typeorm/cli.js --dataSource src/database/data-source.ts",
    "migration:generate": "npm run typeorm -- migration:generate",
    "migration:run": "npm run typeorm -- migration:run",
    "migration:revert": "npm run typeorm -- migration:revert"
  }
}
```

### Main commands
```bash
npm run migration:generate -- migrations/CreateUsersTable
npm run migration:run
npm run migration:revert
```

## Part 8: Repository quick reference
```typescript
await repo.find();
await repo.findOneBy({ id: 1 });
await repo.findOne({ where: { id: 1 }, relations: ["labels"] });

const entity = repo.create({ title: "My Task" });
await repo.save(entity);

await repo.update(1, { status: "done" });
await repo.delete(1);

const loaded = await repo.findOneBy({ id: 1 });
await repo.remove(loaded);

await repo.count({ where: { userId: 5 } });
await repo.existsBy({ email: "test@test.com" });
```

Fast comparison:
- `save()` -> insert or update with entity semantics
- `update()` -> direct partial update
- `remove()` -> entity-based delete
- `delete()` -> direct delete
- `findOneBy()` -> simpler lookup
- `findOne()` -> richer options like `relations`

## Part 9: Production reminders
- use `synchronize: false` in production
- use migrations for schema changes
- keep `select: false` on sensitive columns
- load relations intentionally
- use transactions for multi-step writes
- always release `QueryRunner`

## Quick File Map
| File | Purpose |
| --- | --- |
| `users/user.entity.ts` | user entity and one-to-many side |
| `tasks/task.entity.ts` | task entity, foreign key owner, join-table owner |
| `tasks/label.entity.ts` | label entity, inverse many-to-many side |
| `database/data-source.ts` | CLI-only DataSource for migrations |
| `users/users.service.ts` | user persistence via repository |
| `tasks/tasks.service.ts` | task persistence, relations, transactions |
| `app.module.ts` | root TypeORM connection wiring |
| `migrations/*.ts` | versioned schema changes |

## Final Revision Anchors
- `forRootAsync()` sets up the database connection
- `forFeature()` makes repositories injectable
- `@ManyToOne` owns the foreign key
- `findOne()` is useful when `relations` are needed
- transactions use `QueryRunner`
- production uses migrations, not `synchronize`

For the lifecycle story, go to [3. NestJS TypeORM Runtime Flow](./3_nestjs_typeorm_runtime_flow.md). For quick recall, go to [4. DB Integration Revision Cheatsheet](./4_db_integration_revision_cheatsheet.md).

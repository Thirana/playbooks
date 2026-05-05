### "Two users try to book the last seat on a flight at exactly the same moment. Both requests read the available seat count as 1, both decrement it, and both get a confirmation. How do you prevent this double-booking?"

---

### The Naive Solution

Read the seat count, check if it is greater than zero, decrement it, and confirm the booking.

```typescript
// Naive — BROKEN under concurrent load
async bookSeat(flightId: number, userId: number): Promise<Booking> {
  const flight = await this.flightsRepo.findOneBy({ id: flightId });

  if (flight.availableSeats <= 0) {
    throw new BadRequestException('No seats available');
  }

  // DANGER ZONE: between the read above and the write below,
  // another request can read the same value
  await this.flightsRepo.update(flightId, {
    availableSeats: flight.availableSeats - 1,
  });

  return this.bookingsRepo.save({ flightId, userId, status: 'confirmed' });
}
```

---

### Problems with the Naive Solution

This is the classic **check-then-act race condition**, also called a **TOCTOU (Time Of Check To Time Of Use)** bug.

```
Time →    T1                    T2
User A:   READ seats = 1
User B:                         READ seats = 1
User A:   CHECK 1 > 0 → true
User B:                         CHECK 1 > 0 → true
User A:   UPDATE seats = 0
User B:                         UPDATE seats = 0  ← overwrites A's write
User A:   INSERT booking (confirmed)
User B:                         INSERT booking (confirmed) ← double booking
```

Both users read `1`, both pass the check, both write `0`, both get confirmed — the seat is sold twice.

This is not a theoretical edge case. Under any meaningful load, two requests will overlap within the same millisecond window. The bug is guaranteed to appear in production.

---

### Production-Grade Solution

There are four approaches, each solving the problem at a different layer. A good interview answer presents all four and explains when to use each.

#### Approach 1 — Pessimistic Locking (SELECT FOR UPDATE)

Lock the row at read time. Any other transaction that tries to read the same row is blocked until the first transaction completes.

```
User A reads → acquires row lock
User B reads → BLOCKS (waiting for lock)
User A decrements, confirms, commits → releases lock
User B unblocks → reads the updated value (0) → no seats → rejects
```

```typescript
// src/flights/flights.service.ts

async bookSeat(flightId: number, userId: number): Promise<Booking> {
  return this.dataSource.transaction(async (manager) => {

    // SELECT ... FOR UPDATE acquires an exclusive row-level lock.
    // Any other transaction trying to SELECT FOR UPDATE on this row
    // will BLOCK until this transaction commits or rolls back.
    // Regular SELECTs (without FOR UPDATE) still read the pre-lock value
    // depending on isolation level — use REPEATABLE READ to prevent that.
    const flight = await manager
      .createQueryBuilder(Flight, 'flight')
      .where('flight.id = :flightId', { flightId })
      .setLock('pessimistic_write')  // TypeORM translates to FOR UPDATE
      .getOne();

    if (!flight) throw new NotFoundException('Flight not found');

    if (flight.availableSeats <= 0) {
      throw new ConflictException('No seats available');
    }

    // At this point, we hold the lock. No other transaction can
    // read-for-update or modify this row until we commit.
    await manager.update(Flight, flightId, {
      availableSeats: flight.availableSeats - 1,
    });

    const booking = manager.create(Booking, {
      flightId,
      userId,
      seatNumber: await this.assignSeat(flightId, manager),
      status: 'confirmed',
    });

    return manager.save(booking);
    // Transaction commits here → lock is released → next waiter unblocks
  });
}
```

**When to use pessimistic locking:**

- High contention on individual rows (many users competing for the same resource)
- Operations that take multiple steps before the final write
- When you need to read the current value before deciding what to write
  **Trade-offs:**
- Transactions queue up — high throughput scenarios create a bottleneck
- Long-running transactions under high load can cause lock waits to pile up
- Risk of deadlock if two transactions acquire locks in different orders (mitigated by consistent lock ordering)

#### Approach 2 — Optimistic Locking (Version Counter)

Do not lock at read time. Instead, include a version number in the update. If the version has changed since you read it, someone else modified the row — fail and retry.

```
User A reads → flight.version = 5, seats = 1
User B reads → flight.version = 5, seats = 1

User A updates → WHERE id = X AND version = 5 → SET seats = 0, version = 6
                → 1 row affected → success

User B updates → WHERE id = X AND version = 5 → SET seats = 0, version = 6
                → 0 rows affected → version is now 6, not 5 → CONFLICT → retry or fail
```

```typescript
// The Flight entity with a version column
@Entity("flights")
export class Flight {
  @PrimaryGeneratedColumn()
  id: number;

  @Column()
  availableSeats: number;

  // TypeORM manages this automatically — increments on every UPDATE
  // and checks it on every save() call
  @VersionColumn()
  version: number;
}
```

```typescript
// src/flights/flights.service.ts

async bookSeat(flightId: number, userId: number): Promise<Booking> {
  const MAX_RETRIES = 3;

  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
    try {
      return await this.attemptBooking(flightId, userId);
    } catch (error) {
      // OptimisticLockVersionMismatchError means another transaction
      // committed between our read and our write — retry with fresh data
      if (error instanceof OptimisticLockVersionMismatchError) {
        if (attempt === MAX_RETRIES) {
          throw new ConflictException(
            'Could not complete booking due to high demand. Please try again.',
          );
        }
        // Brief random delay before retry — avoids thundering herd
        // where all retries fire at exactly the same moment
        await sleep(Math.random() * 100 * attempt);
        continue;
      }
      throw error; // Re-throw non-optimistic-lock errors
    }
  }
}

private async attemptBooking(flightId: number, userId: number): Promise<Booking> {
  return this.dataSource.transaction(async (manager) => {
    const flight = await manager.findOneBy(Flight, { id: flightId });

    if (flight.availableSeats <= 0) {
      throw new ConflictException('No seats available');
    }

    flight.availableSeats -= 1;

    // TypeORM's save() with @VersionColumn automatically adds:
    // WHERE id = ? AND version = <old_version>
    // If the version changed, save() throws OptimisticLockVersionMismatchError
    await manager.save(flight);

    return manager.save(Booking, { flightId, userId, status: 'confirmed' });
  });
}
```

**When to use optimistic locking:**

- Low-to-medium contention — conflicts are the exception, not the rule
- Short read-modify-write cycles
- When you want to avoid the throughput penalty of blocking locks
  **Trade-offs:**
- High contention makes retries frequent — in a flash sale scenario this is worse than pessimistic locking
- Retry logic adds complexity and must have a maximum retry count and backoff

#### Approach 3 — Atomic SQL UPDATE with Conditional Check (Best for Most Cases)

Skip the read entirely. Write the decrement as a single atomic SQL statement that checks the condition and applies the change in one operation. If the condition is not met, zero rows are affected.

```sql
-- Atomic: check and decrement happen in the same database operation.
-- No window between read and write — race condition is impossible.
UPDATE flights
SET available_seats = available_seats - 1
WHERE id = $1
  AND available_seats > 0   -- condition checked at write time
RETURNING available_seats;  -- returns the new value
```

```typescript
// src/flights/flights.service.ts

async bookSeat(flightId: number, userId: number): Promise<Booking> {
  return this.dataSource.transaction(async (manager) => {

    // Atomic decrement — the check (> 0) and the write (- 1) happen
    // in a single SQL statement. The database engine makes this atomic.
    // No other transaction can sneak in between the check and the write.
    const result = await manager.query(`
      UPDATE flights
      SET available_seats = available_seats - 1
      WHERE id = $1
        AND available_seats > 0
      RETURNING id, available_seats
    `, [flightId]);

    if (result.length === 0) {
      // Zero rows affected = condition was not met = no seats available
      // OR flight does not exist — check which:
      const flight = await manager.findOneBy(Flight, { id: flightId });
      if (!flight) throw new NotFoundException('Flight not found');
      throw new ConflictException('No seats available');
    }

    // Row was updated — booking is guaranteed unique
    return manager.save(Booking, {
      flightId,
      userId,
      status: 'confirmed',
    });
  });
}
```

**Why this works:**
PostgreSQL executes the entire `UPDATE` statement atomically. The `WHERE available_seats > 0` check and the `available_seats - 1` write cannot be interleaved with another transaction. If two requests run this simultaneously:

- One will successfully update and get 1 row back
- The other will find `available_seats = 0` (already decremented) and get 0 rows back
  **This is the recommended approach for most booking scenarios.** It is simpler than optimistic locking and avoids the throughput penalty of pessimistic locking.

#### Approach 4 — Database Constraint as the Final Safety Net (Always Add This)

Regardless of which approach you use above, add a database-level constraint that makes it structurally impossible for `available_seats` to go negative. This is your last line of defence.

```sql
-- Constraint enforced by the database engine — cannot be bypassed by any
-- application code, ORM bug, or raw query that forgets the WHERE clause
ALTER TABLE flights
ADD CONSTRAINT seats_non_negative
CHECK (available_seats >= 0);
```

If somehow two transactions both pass the application-level check and both try to set `available_seats = -1`, one of them will hit this constraint and be rolled back with an error. The other succeeds. The booking is always safe.

```typescript
// Catch the constraint violation at the service layer
try {
  return await this.attemptBooking(flightId, userId);
} catch (error) {
  // PostgreSQL error code 23514 = check_violation
  if (error.code === "23514") {
    throw new ConflictException("No seats available");
  }
  throw error;
}
```

#### Approach 5 — Individual Seat Rows (The Real-World Model)

In reality, booking systems do not decrement a counter — they assign specific seats. This naturally prevents double-booking because each seat row is unique.

```sql
CREATE TABLE seats (
  id          UUID PRIMARY KEY,
  flight_id   INTEGER REFERENCES flights(id),
  seat_number VARCHAR(10),  -- '12A', '12B'
  status      VARCHAR(20) DEFAULT 'available', -- 'available', 'held', 'booked'
  held_by     INTEGER REFERENCES users(id),
  held_until  TIMESTAMPTZ,   -- Temporary hold expires (e.g., 10 minutes to complete payment)
  booked_by   INTEGER REFERENCES users(id),
  booked_at   TIMESTAMPTZ,
  UNIQUE (flight_id, seat_number)
);
```

```sql
-- Claim a specific seat atomically — only succeeds if status is 'available'
UPDATE seats
SET status = 'held',
    held_by = $1,
    held_until = NOW() + INTERVAL '10 minutes'
WHERE flight_id = $2
  AND status = 'available'
  AND seat_number = $3
RETURNING id;
```

This is how airline booking systems actually work. The `UNIQUE (flight_id, seat_number)` constraint plus the conditional update makes it impossible for two users to book the same seat.

#### The Complete Recommendation

```
For a seat booking system:
  Use individual seat rows + atomic UPDATE WHERE status = 'available'

For a generic inventory system (items, not seats):
  Use atomic UPDATE WHERE quantity > 0 + CHECK constraint (quantity >= 0)

For complex multi-step operations that read before deciding what to write:
  Use pessimistic locking (SELECT FOR UPDATE) inside a transaction

For low-contention resources with occasional conflicts:
  Use optimistic locking with retry

Always add a CHECK constraint as the final safety net regardless of approach.
```

#### Key Interview Points to Mention

- The root cause is the **TOCTOU race condition** — time passes between the read and the write, allowing another transaction to invalidate the read.
- **Atomic SQL** (single UPDATE with condition) is the cleanest solution — the check and write happen in one indivisible operation.
- **Pessimistic locking** is right for high-contention scenarios but creates a throughput bottleneck — requests queue behind the lock.
- **Optimistic locking** is right for low-contention but creates retry overhead — wrong choice for a flash sale.
- Always add a **CHECK constraint** as a database-level last resort, independent of application logic.
- In real booking systems, **individual seat rows** replace counter-based inventory — the `UNIQUE` constraint on `(flight_id, seat_number)` makes structural double-booking impossible.

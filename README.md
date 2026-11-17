# Nordia Tasks — Offline-First Mobile Task Management (Track A)

Nordia maintains buildings. Technicians frequently work in basements, car parks, and technical rooms where mobile connectivity drops without warning. **Nordia Tasks** is an offline-first mobile application built with Flutter that guarantees zero data loss, zero task duplication, and robust conflict resolution when reconnected.

---

## 1. Quick Start & Running the Project

### Prerequisites
- **Flutter SDK**: `>=3.12.2` (tested on Flutter 3.44+)
- **Node.js**: `>=18.0.0` (to run the provided mock server)
- An Android Emulator, iOS Simulator, or Desktop / Web target.

### Step 1: Start the Mock Backend
From the case study folder:
```bash
node server.js
```
The server listens on `http://localhost:3002`.

### Step 2: Run the Flutter App

#### On an Android Emulator:
In the Android emulator, the host machine is accessed via `10.0.2.2`. This is configured as the default URL.
```bash
flutter run
```

#### On a Physical Device / Custom Network:
Pass the host machine's local IP address via `--dart-define`:
```bash
flutter run --dart-define=API_URL=http://192.168.1.50:3002
```

#### On Windows / Desktop:
```bash
flutter run -d windows --dart-define=API_URL=http://localhost:3002
```

---

## 2. Running Automated Tests

The project includes **42 automated tests** covering unit logic, sync engine, idempotency, backoff, conflict resolution, incremental reading, and widget UI:

```bash
flutter test
```

To run static code analysis (zero warnings / errors):
```bash
flutter analyze
```

---

## 3. Architecture & Synchronisation Design

The application follows an **Offline-First Outbox Pattern** with unidirectional data flow:

```
[UI Screens]  <--->  [TaskRepository]
                           |
        +------------------+------------------+
        |                                     |
  [SQLite Database]                    [SyncEngine]
   - tasks (confirmed state)                 |
   - ops (outbox queue)                [HttpTaskApi]
   - lost_values (preserved edits)           |
   - meta & members                 [REST Mock Server]
```

### Key Technical Choices

1. **Immediate Optimistic UI & Local Outbox (`ops` table)**
   - Creating or editing a task writes to the local SQLite database immediately.
   - An operation is added to the `ops` queue with an immutable `op_id` (used as the `Idempotency-Key` header).
   - Operations survive app closures and phone reboots.

2. **Idempotency & Replays (Rules S1 & S2)**
   - The server may succeed in writing but fail to send the response (simulated 500 or timeout).
   - Retries send the exact same `op_id`. The server recognises the key and returns the original answer (`Idempotent-Replay: true`) without duplicating tasks.

3. **Field-Level Conflict Resolution (Rule S4)**
   - When the server returns `409 version_conflict`, the response includes `current` (the latest server task).
   - **Different fields modified**: Both changes are merged (`keep`).
   - **Status modified on both sides**: The furthest status wins (`todo` < `doing` < `done`).
   - **Same field modified with conflicting values**: The server's value is kept active to preserve team consistency, while the technician's value is stored in `lost_values`. The technician is notified and given clear UI actions: **[Use mine]** (re-queues the value on top of current version) or **[Keep theirs]**. No value is silently overwritten.

4. **Error Handling & Backoff (Rule S5)**
   - **Temporary errors (5xx, timeout, network loss)**: Retried with exponential backoff (`2s, 4s, 8s, 16s, 32s, 60s`).
   - **Permanent errors (4xx other than 409)**: Never retried; marked as `rejected` in the outbox. The user sees a clear rejection explanation and a `Dismiss` button.

5. **Incremental Pulling & Tombstones (Rule S6)**
   - Incremental changes are fetched using `GET /tasks?since=<cursor>&limit=50`.
   - Each page of tasks and the new cursor are committed together in an atomic SQLite transaction.
   - Deletions arrive as tombstones (`deleted: true`). They are stored in SQLite to ensure subsequent incremental queries remain consistent, but are filtered out from the active task list.

6. **First Launch & User Selection**
   - At first launch, the app prompts the technician to pick their identity from the team member list.
   - The technician's identity is persisted in SQLite `meta`, and can be switched at any time from the app bar.
   - Includes a **"My tasks"** filter tab to toggle between viewing all team tasks and tasks assigned to the active technician.

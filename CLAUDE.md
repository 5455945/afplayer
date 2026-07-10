# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**afplayer** — A personal music internal-recording and metadata sync Android app (private use only). The app captures media audio from other apps (QQ Music, Huawei Music, etc.) as MP3 files while simultaneously syncing song metadata (title, artist, album, cover art), building a local offline music library.

The project is currently in the **design phase** (no source code yet). The primary reference documents are:

- `概要设计书.md` — Full requirements + architecture spec (v2.5, the definitive design document)
- `需求规格说明书.md` — Requirements specification (v1.2, requirements baseline from user perspective)
- `docs/system-design.md` — Design review checklist

## Build & Test Commands

The project targets Android, using Gradle with Kotlin. These commands are defined in the CI pipeline (`.github/workflows/ci.yml`) and are the canonical way to build and test:

```bash
# Lint (debug)
./gradlew lintDebug

# Unit tests (JVM)
./gradlew testDebugUnitTest

# Instrumented tests (requires emulator/device, API 34)
./gradlew connectedCheck

# Assemble debug APK
./gradlew assembleDebug

# Assemble release APK (requires release.keystore)
./gradlew assembleRelease
```

**Running a single test class or method** (standard Gradle patterns, not yet wired in CI but expected):
```bash
./gradlew testDebugUnitTest --tests "com.example.SessionArbiterTest"
./gradlew testDebugUnitTest --tests "com.example.SessionArbiterTest.testPrioritySorting"
```

## Tech Stack & Key Versions

| Component | Version | Notes |
|:---|:---|:---|
| **minSdk / targetSdk** | 29 (Android 10) / 34 (Android 14) | `AudioPlaybackCapture` requires API 29+ |
| **AGP** | 8.2.x | Compatible with compileSdk 34 + Kotlin 1.9 |
| **Kotlin** | 1.9.x | Paired with Coroutines 1.7+ |
| **KSP** | 1.9.x-1.0.x | For Room annotation processing (prefer over kapt) |
| **NDK** | 25.2.x | For libmp3lame compilation |
| **JDK** | 17 | AGP 8.x minimum |
| **Room** | 2.6+ | Via BOM or unified version |
| **Kotlin Coroutines** | 1.7+ | StateFlow + Channel for state machine |
| **MediaSessionCompat** | 1.7+ | `androidx.media:media` |
| **ABI** | arm64-v8a (primary), armeabi-v7a (optional) | Single-process architecture |

Dependency versions are managed via `gradle/libs.versions.toml` (Version Catalog).

## Architecture: The Big Picture

### Process Model
**Single-process**: UI and `RecordingService` run in the same process. Communication is via **Bound Service + StateFlow** (not BroadcastReceiver, to avoid state loss). If multi-process is needed later, requires AIDL + Coroutine bridge.

### Core State Machine (RecordingOrchestrator)

The central orchestrator runs a single-threaded event loop (`Dispatchers.Default.limitedParallelism(1)`) consuming events from a `Channel<StateEvent>`. All external callbacks (PCM data, playback state, silence detection) are funneled through this channel to avoid race conditions.

```
IDLE → PRE_RECORDING → RECORDING → FINALIZING → SAVING_TO_DB → IDLE
         (5s timeout,     (≥30s or emergency flush,
          storage check,   audio routing switch >2s,
          duplicate detect) Doze/kill recovery)
```

Any state → `ERROR` (on unrecoverable failure) → 3s delay or user reset → `IDLE`

**Key thresholds**: 30s minimum valid recording (shorter = discarded as preview/ad, except emergency flush), 5s PRE_RECORDING timeout, 5s silence threshold triggers FINALIZING, 2s audio routing switch tolerance, 500MB storage warning / 100MB critical.

### Module Responsibilities

| Module | Key Technology | Role |
|:---|:---|:---|
| **NotificationListenerService** | `NotificationListenerService` | Only legal entry point to get external apps' MediaSession tokens |
| **MetadataSessionListener** | `MediaSessionManager` + `MediaController` | Listens to whitelisted apps' MediaSession for metadata + playback state |
| **SessionArbiter** | Kotlin | Multi-session concurrency arbitration; only ONE active session at a time, chosen by priority |
| **AudioCapture** | `AudioPlaybackCapture` (API 29+) | Captures PCM 44.1kHz/16bit/Stereo from whitelisted apps only |
| **LameEncoder** | libmp3lame via JNI/NDK | Streaming PCM→MP3 encoding with ring buffer (3-level watermark: 0.7/0.9/1.0) |
| **Id3TagWriter** | mp3agic or jaudiotagger | Writes ID3v2.4 tags (including embedded cover art) after recording completes |
| **RecordingOrchestrator** | Kotlin Coroutines + StateFlow | Coordinates audio stream + metadata timing alignment, state machine |
| **ExportManager** | Storage Access Framework (SAF) | Copies MP3 to public directory without external storage permissions |
| **StorageMonitor** | StatFs + StateFlow | Pre-recording space estimation; 500MB/100MB two-level warning; blocks new recordings below 100MB |
| **SearchService** | Room Query + Kotlin Flow | Real-time keyword search (title/artist/album) with combined filters (source app, quality, date range) |
| **BatchOperationsManager** | SAF + File I/O | Batch export/delete with progress reporting and partial-failure tolerance |
| **PlaylistManager** | Room (playlists + playlist_tracks tables) | Custom playlist CRUD, many-to-many track association |
| **DuplicateDetector** | Room Query (identityHash cross-session) | PRE_RECORDING phase duplicate check; post-recording reminder if duplicate exists |
| **DiagnosticReportExporter** | SAF + ZIP packaging | Exports error_logs + session records + sanitized config + device info as ZIP (no MP3/covers) |
| **AudioRoutingListener** | AudioManager.AudioDeviceCallback | Monitors Bluetooth/wired headset connect/disconnect; forwards routing events to Orchestrator |
| **RecordingNotificationManager** | NotificationCompat | Foreground service notification showing recording status + song info; supports privacy mode and conflict-switch notifications |
| **LocalPlayerService** | MediaPlayer/ExoPlayer + MediaSessionCompat | Local library playback with background support |

### Database Schema (Room, 5 tables)

- **tracks** — Completed recordings with metadata, tagStatus, qualityFlag, identityHash
- **recording_sessions** — In-flight recording state for crash recovery (PRE_RECORDING / RECORDING / FINALIZING)
- **error_logs** — Structured error diagnostics with severity (INFO/WARNING/ERROR/FATAL); FATAL/ERROR all retained, WARNING/INFO latest 500; auto-pruned after 30 days
- **abnormal_silences** — Detected silence segments per track (SHORT_SUSPECT / LONG_ABNORMAL / INTERFERENCE)
- **target_apps** — Whitelist with priority ordering (QQ Music=10, NetEase=20, Kugou=30, Kuwo=40, Ximalaya=50)
- **playlists** — Custom playlist metadata (name, timestamps)
- **playlist_tracks** — Many-to-many junction table (playlist ↔ track with position ordering)

Database migrations: `fallbackToDestructiveMigration()` during dev (v0.x), explicit `Migration` objects for production (v1.0+). Migration tests use `MigrationTestHelper`.

### File Storage Layout

```
/data/data/{packageName}/files/music/
├── yyyyMMdd_HHmmss_{identityHash}.mp3   # Recorded MP3
├── covers/{identityHash}.jpg            # Local cover cache
└── temp/recording_{timestamp}.pcm       # Temporary PCM (deleted on completion)

/data/data/{packageName}/files/music/orphans/    # Orphan files from failed DB transactions
/data/data/{packageName}/databases/music_library.db
/data/data/{packageName}/logs/crash_{timestamp}.log
```

Cover art is cached locally immediately upon metadata receipt (to avoid Content URI expiration), using `SHA256(title|artist|album|sourcePackage).substring(0,16)` as filename.

### Whitelist + Audio Focus Dual Filter

Recording triggers only when ALL three conditions are met:
1. **Whitelist match** — Playing app is in `target_apps` with `enabled=true`
2. **Audio focus held** — MediaSession state is `STATE_PLAYING` and `active=true`
3. **Metadata available** — At least title or artist is non-null

Non-whitelist app MediaSession events are silently ignored.

### Audio Focus Loss Detection (Dual Mechanism)

- **Primary (Plan B)**: MediaSession state changes (PLAYING→PAUSED/STOPPED). Immediate, accurate.
- **Fallback (Plan A)**: Silence detection. Continuous 5s silence → FINALIZING. 5s delay, may false-positive on song-internal silence.

Either triggers FINALIZING. The mechanism also detects phone calls: PCM silence >3s → save current song → IDLE → auto-resume when playback restores.

### Song Change Detection

Dual verification: new metadata arrives AND `identityHash` differs from current. Same song repeated metadata pushes (progress updates) don't trigger save. `identityHash` = `SHA256(title|artist|album|sourcePackage).substring(0,16)`.

### Error Handling

**Layered exception hierarchy**:
```
AppException (sealed class)
├── EncoderBufferOverflowException (FATAL, unrecoverable)
├── AudioCaptureException (ERROR, recoverable via emergency flush)
├── EncoderFatalException (FATAL, unrecoverable)
├── StorageFullException (FATAL, unrecoverable)
└── PermissionRevokedException (FATAL, stop service + notify user)
```

Session switches are NOT exceptions — they're `SessionEvent` (normal flow).

**New FinalizeReason added in v2.5**: `AUDIO_ROUTING` (Bluetooth/headset disconnect >2s with PCM silence).

**WAL Checkpoint strategy**: Passive checkpoint after each `finalizeTrack()` success; FULL checkpoint every 10 recordings; TRUNCATE on service startup. WAL file size cap: 10MB.

**Three-layer error reporting** (all local, no network upload):
1. Structured `error_logs` table (viewable in-app)
2. Local crash log files (`/logs/crash_{timestamp}.log`)
3. Real-time diagnostic overlay (debug builds only)

**Crash recovery**: Native crashes in libmp3lame (SIGSEGV) kill the process. `START_STICKY` restarts the service, then `recording_sessions` table is used to salvage partial MP3 files.

### Permission Model

| Permission | Purpose | Acquisition |
|:---|:---|:---|
| `MediaProjection` | Screen capture auth (required for AudioPlaybackCapture) | System dialog via `MediaProjectionManager.createScreenCaptureIntent()` |
| `NotificationListenerService` | Get external app MediaSession tokens | User manually enables in system settings |
| `RECORD_AUDIO` | Audio capture (required by some OEM ROMs) | Runtime request |
| `FOREGROUND_SERVICE` + `mediaPlayback` type | Background persistence (Android 14+) | Manifest declaration |
| `POST_NOTIFICATIONS` | Foreground service notification (Android 13+) | Runtime request |

**Degraded modes** exist when permissions are partially denied — the app continues with reduced functionality rather than being completely unusable.

### Export Flow

Uses SAF (`ACTION_OPEN_DOCUMENT_TREE`) only — **no** `READ/WRITE_EXTERNAL_STORAGE` permissions. `ExportManager.copyToPublicDirectory()` pre-checks disk space via `StatFs` before copying, preserving full ID3 tags.

## Key Design Rules

- **All cross-layer suspend functions return `Result<T>`**; pure-query interfaces may return nullable.
- **Callback interfaces are annotated with thread** (`@WorkerThread`) — callbacks must not touch UI or block I/O directly.
- **`stop()` / `abort()` / `clearTags()` are idempotent** — multiple calls have no side effects.
- **Timing uses monotonic clock** (`SystemClock.elapsedRealtime()`) for recording duration; file timestamps use `System.currentTimeMillis()` with correction on detected clock rollback (>1 min).
- **Entity/DAO naming**: `TrackRecord` / `RecordingSessionRecord` / `ErrorLogRecord` / `AbnormalSilenceRecord` / `TargetApp`.
- **qualityFlag calculation**: ABNORMAL > SUSPECT > GOOD. Interference or long silence → ABNORMAL. Short silence only → SUSPECT. No silence events → GOOD.

## Development Milestones

| Phase | Deliverable | Est. Effort |
|:---|:---|:---|
| M1: Basic Recording | AudioCapture + LAME + Foreground Service + playable MP3 | 3-4 days |
| M2: Metadata Sync | MediaSession listener + State machine + SessionArbiter | 3-4 days |
| M3: Tags & Storage | ID3 writer + Room (5 tables) + File management + Transactions | 2-3 days |
| M4: Error Handling | Exception hierarchy + Service restart recovery + Error logs UI + Permission guide | 2-3 days |
| M5: Quality Detection | Silence detection + Abnormal segment marking + qualityFlag | 2 days |
| M6: Local Player | Playback UI + Library management + Cover display + Manual tag editing | 2-3 days |
| M7: Robustness | Multi-device testing + Configurable params + Edge case stress testing | 2-3 days |

## Build Variants

| Config | debug | release |
|:---|:---|:---|
| `minifyEnabled` | false | true (R8) |
| `fallbackToDestructiveMigration` | true | false |
| Log level | VERBOSE | INFO |
| Diagnostic panel | Visible | Hidden |
| `nativeDebuggable` | true | false |

ProGuard rules must preserve: Room entities/DAOs, JNI native methods (`-keepclasseswithmembernames`), MediaSession classes, and Kotlin Coroutines internal factories.

## Language

The project documentation and code are in Chinese (Simplified). Respond in Chinese unless asked otherwise.

## Design Review Checklist

- 所有 API 必须包含幂等性说明
- 数据库变更必须有回滚方案
- 第三方依赖需注明 SLA 和降级策略
- 性能指标需有基准数据和压测计划

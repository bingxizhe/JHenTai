![platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20Windows%20%7C%20MacOS%20%7C%20Linux-brightgreen)
![last-commit](https://img.shields.io/github/last-commit/bingxizhe/JHenTai)
![star](https://img.shields.io/github/stars/bingxizhe/JHenTai)
[![issue](https://img.shields.io/badge/chat-issue-brightgreen)](https://github.com/bingxizhe/JHenTai/issues/new)

# JHenTai (Fork)

English | [简体中文](README_cn.md) | [한국어](README_kr.md)

This is a fork of [JHenTai](https://github.com/jiangtian616/JHenTai), a manga app for E-Hentai, supporting Android & iOS & Windows & MacOS & Linux.

The fork focuses on **strengthening download management**, **local gallery management**, and **batch operations**. All changes are designed to be non-invasive and compatible with the upstream codebase, and are regularly merged with upstream.

## Fork Features

### 1. Gallery Version Chain Management

Upstream only stores a single-hop parent version URL. This fork extends it to a complete ancestor chain, enabling cross-multi-hop version recognition even when intermediate versions are deleted.

- **Complete ancestor chain**: `oldVersionGalleryUrl` is stored as a JSON array of the full ancestor chain (parent → grandparent → …, up to 20 levels). Downloading a new gallery automatically crawls and persists the chain in the background, with short-circuit optimization when an ancestor already exists locally.
- **Batch delete historical versions** (`eh_delete_history_versions_dialog.dart`): Groups downloaded galleries by ancestor chain and pre-selects all but the latest version in each group for one-click batch deletion. Supports "deep scan" to discover version relationships not recorded locally, with 24-hour result caching and dual-site (e-hentai/exhentai) fallback.
- **Fetch historical version links** (`eh_fetch_old_version_urls_dialog.dart`): Recursively crawls the complete ancestor chain for all downloaded galleries online, with dual-site fallback. Automatically upgrades old single-link records to the full chain format.
- **Domain-agnostic matching**: Version relationships are matched by gid+token regardless of domain, handling e-hentai.org vs exhentai.org URL mixing.

### 2. Download Restore Robustness

- **Deferred restore**: Download restore no longer runs at app startup. It is triggered on first entry to the download page via `ensureRestored()`, preventing large directories (thousands of galleries) from blocking app launch.
- **Restore progress banner**: The download page shows phased progress ("Parsing gallery data x/y", "Loading galleries x/y").
- **Batch restore mode**: Suppresses per-gallery `update()` calls during restore of 3000+ galleries, refreshing UI at intervals instead of per-item.
- **Async I/O restore**: Restore uses async file I/O instead of synchronous `listSync`/`readAsStringSync`, avoiding UI thread blocking.
- **Skip already-loaded galleries**: Extracts gid from directory names to skip metadata parsing for galleries already loaded from DB.
- **Metadata consistency verification** (`verifyDownloadedGalleriesMetadata`): Scans download directories to repair sanitizedTitle mismatches, stale image paths, and duplicate-directory oscillation. Also recovers galleries incorrectly reset to `paused` by prior verify errors (curCount=0 but cover file exists).
- **Orphan directory cleanup**: When deleting a gallery, if sanitizedTitle doesn't match the disk directory name, falls back to gid-prefix matching to delete the directory, preventing orphan directories from being re-imported by verify.

### 3. Favorite Batch Download

- **One-click batch download**: Download all favorites from a specific group with a single action. Automatically skips galleries already downloaded (normal or archive).
- **Breakpoint resume**: Supports 30-minute breakpoint resume. On load/download failure, progress is persisted and a countdown banner with "resume" button is shown.
- **Pre-download dialog**: Choose target download group and whether to download original images before batch download starts.
- **Progress banner**: Shows "Loading all favorites x" and "Batch downloading x/y" progress.
- **Retry mechanism**: 5 retries for both page loading (2s interval) and per-gallery enqueue (500ms interval).
- **Incremental persistence**: Favorites saved every 5 pages instead of every page, reducing O(n²) serialization overhead.

### 4. Local Gallery Management

- **Deferred scanning**: Local gallery scanning no longer blocks app startup. Triggered on first entry to the download page via `ensureScanned()`.
- **Scan progress display**: Shows "scanned directories / total" and "discovered galleries" count during scanning.
- **Loading state indicator**: Local gallery pages use `LoadingStateIndicator` to show scan loading state and progress text.
- **Full directory deletion**: Deleting a local gallery always removes the entire directory (including non-image files and metadata), preventing leftover empty folders or half-deleted states.
- **Async scan refactor**: Scan logic restructured to async/await with progress callbacks, replacing nested Completer patterns.

### 5. UI/UX Improvements

- **Reactive download icons**: Gallery card download icons are now reactive, listening to `GalleryDownloadService` and `ArchiveDownloadService` state changes. Icons update immediately when download/archive completes (previously based on a one-time `downloaded` check that never updated).
- **Text overflow fixes**: Long text in comment author names, dashboard cards, download list uploader names, and gallery card timestamps now use `Flexible` + `maxLines:1` + `overflow:ellipsis`.
- **Third-party viewer error handling**: `openThirdPartyViewer` judges errors by non-zero exit code only, avoiding false errors from Chromium/Electron stderr noise (e.g., GPU cache failures).

### 6. Performance & Engineering

- **Startup performance logging**: Records per-bean `initBean` duration; beans exceeding 50ms are logged at trace level, along with total init time.
- **Database WAL mode**: Enables `PRAGMA journal_mode = WAL` and `busy_timeout = 5000` for improved concurrent read/write performance.
- **Insert-or-replace for images**: `insertImage` changed to `InsertMode.insertOrReplace`, fixing conflicts from duplicate inserts.
- **Recent gallery group limit**: Recent gallery group count capped at 10.
- **Custom insertTime**: `GalleryDownloadRequest` adds an `insertTime` field for batch favorite downloads to stagger times for priority scheduler.
- **New version URL selection**: `newVersionGalleryUrl` selects the latest child version by updateTime instead of taking the last one.

## Download & Install

Download the latest release (Android APK & Windows ZIP) from [GitHub Releases](https://github.com/bingxizhe/JHenTai/releases).

To build from source:

1. You need to manage your Android signing by yourself, check https://docs.flutter.dev/deployment/android#signing-the-app
2. Run this project via IDEA or VSCode.

## About code contribution

1. There is no fixed requirement for branch names. You can make changes on your local master branch and submit a PR.
2. For changes that are large in scope or involve interactions between multiple modules, code submitted via Vibe Coding by developers without code review capability will not be accepted. Such code often fails to follow the project's existing coding conventions, is harmful to code extensibility, and its correctness cannot be guaranteed.
3. A single PR should focus on the minimal feature scope. If multiple features are involved, please submit separate PRs.

## Main Dart Dependencies

- [get](https://pub.flutter-io.cn/packages/get): dependency management, state management, l18n, NoSQL
- [dio](https://pub.flutter-io.cn/packages?q=dio): network
- [extendedImage](https://pub.flutter-io.cn/packages/extended_image): image
- [drift](https://pub.flutter-io.cn/packages/drift): database

## References & Thanks

- [JHenTai](https://github.com/jiangtian616/JHenTai) - The original project
- [FEhviewer](https://github.com/honjow/FEhViewer) - Layout and style reference
- [EHPanda](https://github.com/tatsuz0u/EhPanda) - Layout and style reference
- [EhTagTranslation](https://github.com/EhTagTranslation/Database) - Tag translation

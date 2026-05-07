# drift_sync

Offline-first synchronization toolkit for Drift databases.

## Packages

| Package | Description |
|---|---|
| [`drift_sync_core`](packages/drift_sync_core/) | Pure-Dart engine: orchestrator, type handlers, dependency manager, idempotent `sync()`, logging primitives. |
| [`drift_sync_flutter`](packages/drift_sync_flutter/) | Flutter glue: `SyncTriggers` — single attach/detach surface for app lifecycle, connectivity, and a periodic timer. |

Versions are independent. Each package is published separately to pub.dev.

## Repo layout

This is a [Dart pub workspace](https://dart.dev/tools/pub/workspaces) — Dart 3.6+ resolves all packages from a single root pubspec, with one shared lockfile.

```
drift_sync/
├── pubspec.yaml              # workspace root
├── packages/
│   ├── drift_sync_core/
│   └── drift_sync_flutter/
├── scripts/release.sh        # version bump + tag helper
└── README.md
```

## Development

```bash
# from the repo root
dart pub get
```

That resolves both packages with a shared lockfile. No path overrides needed in package pubspecs — they declare `resolution: workspace`.

## Releasing

Each package versions independently. Tags are scoped per package: `<package>-v<version>`.

```bash
./scripts/release.sh drift_sync_core 0.3.0
# → bumps version in pubspec.yaml
# → opens CHANGELOG.md for editing
# → commits
# → tags as drift_sync_core-v0.3.0
# Then: cd packages/drift_sync_core && dart pub publish
```

To release both packages from one set of changes, run the script twice (once per package).

## Consumer wiring

Apps reference packages via git URL with subdirectory `path`:

```yaml
dependencies:
  drift_sync_core:
    git:
      url: https://github.com/whilesmartflutter/drift_sync.git
      ref: drift_sync_core-v0.2.0
      path: packages/drift_sync_core
  drift_sync_flutter:
    git:
      url: https://github.com/whilesmartflutter/drift_sync.git
      ref: drift_sync_flutter-v0.1.0
      path: packages/drift_sync_flutter
```

Once published to pub.dev, the standard `^x.y.z` constraint works.

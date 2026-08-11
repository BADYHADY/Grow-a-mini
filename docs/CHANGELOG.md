# Changelog

Format: what changed, why, and what could break. Newest first.

## [0.1.0] — Phase 1, step 1.1 — project skeleton

**Added**
- Rojo project (`default.project.json`), Rokit toolchain pin, `.gitignore`, README.
- Server and client loaders with an explicit two-phase `Init` → `Start` order.
- `Shared/Net/Remotes`: single definition point for every remote, with a
  per-player token-bucket rate limiter that cannot be bypassed by forgetting it.
- `Shared/Config/`: GameConfig, MiniConfig, EconomyConfig, UpgradeConfig,
  EnemyConfig, MutationConfig. All tunables live here.
- `Shared/Util/`: Signal, Pool, Format.
- `Shared/Types/`: Profile and MiniSnapshot type definitions.
- `DataService` on vendored ProfileStore, with `SchemaVersion` and a migration
  table wired in from the first commit.
- `AnalyticsService` with the onboarding funnel event names from the Phase 0 plan.

**Why**
Everything here is load-bearing for later phases and painful to retrofit:
session locking, schema migration, rate limiting, and the config/code split.

**Known gaps**
- No gameplay yet. `place.rbxl` must be created by hand (empty Baseplate).
- ProfileStore runs against `.Mock` in Studio by default — see `DataService`.

# Changelog

## 0.1.0-dev - 2026-10-02

### Stage A foundation

- Added read-only environment inspection with explicit `ok` / `unverified` semantics.
- Added root-owned state schema, atomic updates, separate state lock and shared source-reference model.
- Hardened managed-path and symlink validation.
- Added transaction journal with snapshots, staged digests, pre-apply drift checks, atomic replace, conservative rollback and startup recovery.
- Added non-TTY mutation guard and read-only `status` behavior.
- Added idempotent development source installer.
- Added isolated unit tests and GitHub Actions CI entry.
- Added requirement matrix, test report, compatibility notes and review handoff.

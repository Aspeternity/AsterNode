# Changelog

## 0.2.0-dev - 2026-10-02

### Stage B node development

- Added pinned Xray v26.3.27 core/profile handling with checksum validation and real-core CI config tests.
- Added managed `rm-xray` service lifecycle, maintenance timer, multi-node/inbound rendering and explicit autostart handling.
- Added VLESS + RAW/TCP + REALITY node/upstream lifecycle, credential-safe export and timed UUID rotation.
- Added Target probing and D1-D4 diagnostics with explicit unverified boundaries.
- Fixed jq boolean-default semantics so explicit `false` is not treated as an absent value.
- Added managed-config drift detection and conservative refusal to overwrite external edits.
- Hardened archive symlink checks and restored executable-mode regression coverage.
- Stage B remains pre-production until real VPS/systemd/network/T24/T25 evidence is recorded.

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

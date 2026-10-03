# Changelog

## Unreleased - Stage C security development

- Added effective SSH policy inspection for service/socket mode, Include/Match/cloud-init and startup argument overrides.
- Added public-key validation, fingerprint inventory/removal, last-verified-entry protection and manual fresh-connection verification commands.
- Added protected SSH port/password/Root migrations with UFW coordination, systemd rollback timer, boot recovery guard and console recovery guidance.
- Added conservative UFW ownership, explicit business-port preservation, whitelist conflict refusal, IPv4/IPv6 boundaries and timed public access recovery.
- Added conservative Fail2ban sshd jail management with file/systemd log backends, dependency checks, runtime log-source health, UFW action selection, ban/unban tooling and managed growth limits.
- CI #88 on `bd4d10d` passed 21 tests with zero failures/skips, Bash syntax, ShellCheck and pinned Xray v26.3.27 config parsing.
- Stage C code/isolated automation is closed out; T05-T20/T26 remain pending final unified VM/VPS acceptance.

## 0.2.0-dev - 2026-10-02

### Stage B node development

- Added pinned Xray v26.3.27 core/profile handling with checksum validation and real-core CI config tests.
- Added managed `rm-xray` service lifecycle, maintenance timer, multi-node/inbound rendering and explicit autostart handling.
- Added VLESS + RAW/TCP + REALITY node/upstream lifecycle, credential-safe export and timed UUID rotation.
- Added Target probing and D1-D4 diagnostics with explicit unverified boundaries.
- Fixed jq boolean-default semantics so explicit `false` is not treated as an absent value.
- Added managed-config drift detection and conservative refusal to overwrite external edits.
- Hardened archive symlink checks and restored executable-mode regression coverage.
- Added staged upstream source migration (`source-add` / verify / `source-remove`) and normalized IPv4/IPv6/CIDR reference accounting.
- Added bounded Target candidate probing and a credential-redacted 0600 diagnostic bundle with no automatic upload.
- Avoided Xray restarts for metadata-only/source-only state changes while watching the managed config digest inside the transaction.
- CI #59 passed with 18 tests, Bash syntax, ShellCheck, pinned Xray v26.3.27 server/client config parsing, and zero skips.
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

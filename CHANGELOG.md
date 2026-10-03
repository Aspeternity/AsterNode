# Changelog

## Unreleased - Stage D maintenance development

- Real-VPS Target probing now parses full OpenSSL TLS output from temporary files, eliminating the -brief ALPN false-negative/NUL-command-substitution issue; candidate probing also filters HTTP redirects, expands the versioned candidate pool, and reports a measured recommended Target without auto-applying it.
- Added a hard anti-abuse Target gate: candidate probes test the resolved IP against unrelated valid SNI hostnames, high/unverified cross-SNI risk is excluded from recommendation, and real node create/Target changes re-run the gate before apply.
- Managed REALITY inbounds now persist per-node randomized limitFallbackUpload/limitFallbackDownload values supported by pinned Xray v26.3.27, reducing unauthenticated fallback bandwidth abuse without a single fixed one-click fingerprint.
- Hardened the anti-abuse gate with fail-closed CNAME/PTR shared-edge detection backed by a versioned CDN suffix list plus broader cross-SNI probes; observed Bing/Akamai-style trafficmanager.net -> edgekey.net -> akamaiedge.net chains are blocked from recommendation.
- Tightened randomized fallback limits from multi-megabyte unthrottled windows to hundreds-of-KiB ranges, reducing reconnect-based fallback bandwidth theft while preserving per-node parameter variation.
- Added dig/dnsutils to bootstrap dependency coverage so shared-edge DNS classification cannot silently degrade on minimal Debian/Ubuntu installs.
- Added fastly-edge.com to shared-edge classification and marked www.mozilla.org as a known shared-edge diagnostic candidate after real VPS evidence showed www-mozilla.fastly-edge.com; Mozilla is no longer eligible for automatic Target recommendation.
- Added signed, manifest-verified manager release packages with pinned trust-anchor handling and controlled version-directory switching.
- Added a generator for fixed-version HTTPS bootstrap scripts that pin both package and release-public-key SHA-256 values and reject unsafe archive paths/types before extraction.
- Manager package installation now requires the fixed outer package SHA-256; the bootstrap never follows floating `main` or `latest`.
- Added local-only update status and current-manager integrity verification so offline/network failures do not block inspection of installed state.
- Core updates now stage/download a candidate without switching the active symlink, test the existing shared config first, preserve the prior service enabled/active state, and restore the previous core on post-switch failure.
- Added explicit `update rollback-core UPGRADE_BACKUP_ID`; successful local validation remains separate from real line-client compatibility, and shared-service restarts are reported as connection-interrupting.
- Preserved explicit first-bootstrap trust boundaries in README: a remote bootstrap cannot independently prove the integrity of itself.
- Added integrity-checked backups with same-host machine binding; same-host restore preserves current SSH/UFW/Fail2ban and service state, while portable restore imports nodes/upstreams disabled for review.
- Added ownership-scoped uninstall with preflight drift checks, a default recovery backup, managed systemd/core/version cleanup, and conservative preservation of security settings, trust anchors, backups, exports and unknown content.
- Added low-resource maintenance status/pruning for terminal transactions, bounded backups, revoked/orphaned exports, orphaned D4 evidence, and old verified manager/core versions without deleting recovery state or unknown paths.
- CI #103 on `489fb8a` passed 27 tests with zero failures/skips, Bash syntax, ShellCheck and the pinned real-Xray configuration job.
- Stage D code/isolated automation is closed out; B/C/D real VPS gates remain mandatory before a release candidate can be treated as production-ready.

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

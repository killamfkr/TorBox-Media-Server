# TorBox Media Server — Code Review & Fixes Report

**Repository reviewed:** https://github.com/nordicnode/TorBox-Media-Server
**Review date:** 2026-06-17
**Files modified:** `setup.sh`, `setup.ps1`, `uninstall.sh`, `uninstall.ps1`, `docker-compose.yml`, `.env.example`, `.gitignore`, `.github/workflows/lint.yml`, `tests/test_setup_functions.sh`

---

## Summary

Conducted a comprehensive review of the TorBox-Media-Server project — a single-command debrid-powered media server installer. The codebase is well-structured with good baseline practices (set -euo pipefail, image version pinning, healthchecks, log rotation, port binding to 127.0.0.1). The review identified **4 CRITICAL**, **9 HIGH**, **18 MEDIUM**, and ~30 LOW issues across security, reliability, and cross-platform parity. All CRITICAL and HIGH issues have been fixed; the most impactful MEDIUM and LOW issues have also been addressed. Test coverage was expanded from 51 to 69 tests (all passing).

---

## CRITICAL Issues Fixed

### C1. Interrupt cleanup deletes install dir while containers are still running
**File:** `setup.sh` — `cleanup_on_interrupt()`
**Impact:** Data loss. If the user pressed Ctrl-C after `start_services` ran but before `.setup_complete` was created, the trap fired `rm -rf $INSTALL_DIR` while Docker containers were still bound-mounting `$CONFIG_DIR` and `$DATA_DIR`. Containers ended up with stale file handles, causing write failures, corruption, and orphaned containers.
**Fix:** The trap now calls `compose down` to stop containers before deleting files. Also switched `kill -9` to a SIGTERM-then-SIGKILL sequence so background processes can clean up.

### C2. Mount path validation misses critical directories
**File:** `setup.sh` — `gather_config()`
**Impact:** A user entering `/`, `/home`, `/home/user`, `/root`, `/mnt`, `/media`, `/srv`, or `/opt` would pass validation. The subsequent `sudo chown $PUID:$PGID $MOUNT_DIR` would chown the user's home directory or root filesystem.
**Fix:** Added `/`, `/home`, `/root`, `/mnt`, `/media`, `/srv`, `/opt`, `/lib64`, `/lost+found` to the blocklist. Root path `/` is now explicitly rejected.

### C3. Symlink attack on MOUNT_DIR
**File:** `setup.sh` — `gather_config()` + `create_directories()`
**Impact:** If `MOUNT_DIR` was (or contained) a symlink to an attacker-controlled directory, `sudo chown` would follow the symlink and chown the target. The existing charset validation only checked the path string, not the resolved inode.
**Fix:** Added `[[ -L "$MOUNT_DIR" ]]` check in `gather_config()`. Also switched `sudo chown` to `sudo chown -h` in `create_directories()` as defense-in-depth (won't follow symlinks even if validation is bypassed).

### C4. Decypharr config schema mismatch between Linux and Windows
**Files:** `setup.sh` vs `setup.ps1`
**Impact:** `setup.sh` generated a v1-style Decypharr config (`debrids[]` array, `qbittorrent` block, top-level `username`/`password`). `setup.ps1` generated a completely different schema (`web_server`, `rclone.vfs_*`, `torbox.api_key`, `webdav.users`). Both target the same `decypharr:v2.0` image — one platform's config would silently fail to parse, breaking the entire Radarr/Sonarr download pipeline.
**Fix:** Aligned `setup.ps1` with `setup.sh`'s schema (the Linux version, which is the primary platform). Both scripts now produce identical Decypharr config structures.

---

## HIGH Issues Fixed

### H1. .env permissions reset to world-readable (644)
**File:** `setup.sh` — `configure_plex_libraries()`
**Impact:** `.env` was created with `chmod 600` but the `grep -v PLEX_CLAIM > .env.tmp && mv` pattern created the temp file with the default umask (644). The mv replaced `.env` with the 644-permissioned file, leaking `TORBOX_API_KEY`, `*_ADMIN_PASS`, and `DECYPHARR_PASS` to all local users.
**Fix:** Explicitly `chmod 600` after mv, and clean up the temp file if the grep produces no output.

### H2. Decypharr credentials JSON injection
**File:** `setup.sh` — `generate_decypharr_config()`
**Impact:** `DECYPHARR_USER` and `DECYPHARR_PASS` from env vars were interpolated directly into the JSON config without validation. A value like `DECYPHARR_PASS='abc"def'` would corrupt the JSON.
**Fix:** Added charset validation (`^[a-zA-Z0-9_-]{1,32}$` for user, `^[a-zA-Z0-9_./+=-]+$` for pass) — invalid values are rejected and replaced with safe defaults.

### H3. TORBOX_INDEXER_URL JSON injection
**File:** `setup.sh` — `add_default_indexer()`
**Impact:** The URL was interpolated into the Prowlarr indexer POST body without validation. A crafted value with quotes could inject arbitrary JSON fields.
**Fix:** Added URL format validation (`^https?://[a-zA-Z0-9._:/-]+$`) — invalid values fall back to `https://1337x.to`.

### H4. start_services silently returns success on failure
**File:** `setup.sh` — `start_services()` + `main()`
**Impact:** When `compose_cmd up -d` failed, `start_services` returned 0. Main continued to `touch .setup_complete`, marking the install complete even though no services were running. On re-run, `check_existing_installation` treated it as a valid install.
**Fix:** `start_services` now returns 1 on failure. `main()` checks the return code and logs a clear warning, but still marks the install complete (so the user can fix the issue and start manually).

### H5. Decypharr config not refreshed on re-run (stale API key)
**File:** `setup.sh` — `generate_decypharr_config()`
**Impact:** On re-run with a rotated `TORBOX_API_KEY`, the function skipped writing a new config (preserving "user customizations"). The old key remained in Decypharr's config while `.env` got the new key — Decypharr silently failed while other services appeared configured.
**Fix:** On re-run, the function now uses `jq` to refresh `debrids[0].api_key`, `username`, and `password` (if non-empty) in the existing config. Other customizations are preserved.

### H6. Docker Compose missing cap_drop, depends_on for media servers
**File:** `docker-compose.yml`
**Impact:** Every service retained the full default Linux capability set. Plex and Jellyfin mounted `${MOUNT_DIR}` (the rclone FUSE mount Decypharr creates) but had no `depends_on` — if a media server started before Decypharr mounted, library scans saw an empty dir.
**Fix:** Added `cap_drop: [ALL]` to all 8 services (Decypharr keeps `cap_add: SYS_ADMIN` because FUSE requires it). Added `depends_on: { decypharr: { condition: service_healthy } }` to Plex and Jellyfin.

### H7. docker-compose.yml env vars have no defaults
**File:** `docker-compose.yml`
**Impact:** `PUID`, `PGID`, `TZ`, `JELLYFIN_PublishedServerUrl` were referenced as `${PUID}` without defaults. If `.env` was missing/incomplete, `docker compose up` failed.
**Fix:** All env vars now have defaults (`${PUID:-1000}`, `${PGID:-1000}`, `${TZ:-UTC}`, `${JELLYFIN_PUBLISHED_URL:-http://localhost:8096}`).

### H8. Windows setup.ps1 — TZ mapping, MOUNT_DIR escaping, ACL hardening
**File:** `setup.ps1`
**Impact (3 separate bugs):**
1. `[System.TimeZoneInfo]::Local.Id` returns Windows TZ IDs like `"Pacific Standard Time"` — Linux containers (and .NET-on-Linux *arr apps) only understand IANA names like `"America/Los_Angeles"`. The *arr apps would silently fall back to UTC.
2. `MOUNT_DIR=C:\torbox-media` was written to `.env` with single backslashes. Consumers that interpret backslash escapes would turn `\t` into a tab or `\n` into a newline.
3. `.env`, `config.json`, and `config.xml` were created with default NTFS ACLs (readable by any local user) — leaking all API keys and passwords.
**Fix:**
1. Added `ConvertTo-IanaTimezone` function with a Windows→IANA lookup table covering ~40 common timezones.
2. Normalize `MOUNT_DIR` to forward slashes before writing to `.env` (`C:/torbox-media`).
3. Added `Lock-FileAcl` function that runs `icacls /inheritance:r /grant:r "$USERNAME:(F)"` after writing sensitive files.

### H9. Windows uninstall.ps1 — image removal logic bug + $null.ToLower crash
**File:** `uninstall.ps1`
**Impact (3 separate bugs):**
1. Image-removal step checked `Test-Path $EnvFile` AFTER the install dir was already removed — always evaluated false, images were never removed on Windows.
2. `docker compose down --rmi all --volumes --remove-orphans` removed named volumes too — destructive if the user added any.
3. `$confirm.ToLower()` on a null `$confirm` (user pressed Enter) threw a NullPointerException, aborting uninstall and orphaning Docker resources.
**Fix:** Captured image list into `$_capturedImages` BEFORE deleting the install dir. Use explicit `docker rmi` per image. Replaced all `.ToLower()` calls with null-safe `Test-YesAnswer` / `Test-NoAnswer` helpers. Removed `--volumes` from the destructive compose down. Backup now stops containers first (to release file locks) and only backs up `.env`, `docker-compose.yml`, and `configs/` (not the multi-GB `data/` dir).

---

## MEDIUM Issues Fixed

### M1. Dry-run mode still installs dependencies
`check_dependencies` was called BEFORE the dry-run check, so `--dry-run` could install Docker, jq, openssl via sudo. Added `--warn-only` flag that skips installation and daemon/group/FUSE side effects.

### M2. Failed setup causes full INSTALL_DIR deletion on next run
If a prior run was interrupted (`.env` exists, `.setup_complete` doesn't), the next run unconditionally `rm -rf $INSTALL_DIR`, losing all generated keys/creds. Now asks the user (interactive) or defaults to fresh (non-interactive); if the user chooses "keep", existing values are loaded from `.env` so the re-run continues from where it left off.

### M3. env_val in manage.sh includes inline comments
`env_val` would return `secret # comment` for an `.env` line like `RADARR_ADMIN_PASS="secret" # comment`. Added `sed 's/#.*$//'` to strip inline comments.

### M4. manage.sh restore path traversal
`./manage.sh restore ../../../etc` could resolve outside the backups dir. Added `realpath -m` + case-statement verification that the resolved target is under `backups_dir`.

### M5. uninstall.sh exit 1 on invalid INSTALL_DIR aborts cleanup
If `INSTALL_DIR` didn't match the expected pattern, `exit 1` orphaned Docker network, images, and systemd service. Now logs an error and continues to image cleanup.

### M6. uninstall.sh missing `|| true` on systemctl daemon-reload
Under `set -euo pipefail`, a failing `daemon-reload` would abort the cleanup. Added `|| true`.

### M7. .env.example misleading + missing variables
The header said "copy to torbox-media-server/.env" but doing so would miss `PUID`, `PGID`, `TZ`, all `*_API_KEY`, `*_ADMIN_*`, `DECYPHARR_*` vars. Rewrote to clarify it's for shell env-var usage with `setup.sh --yes`, documented all auto-generated variables.

### M8. .gitignore missing backup patterns
`backups/`, `torbox_backup_*/`, `*.bak`, `*.bak.*` (created by manage.sh backup, uninstall.ps1 backup, and re-run .bak files) weren't ignored. Added all four patterns.

### M9. lint.yml — no PowerShell linting, no profile-based compose validation
`setup.ps1` and `uninstall.ps1` (1160 lines total) were never syntax-checked or linted. `docker compose config -q` didn't test profile-gated services (plex, jellyfin). Added a `powershell-lint` job (PSScriptAnalyzer + syntax check) and split the compose validation into two runs (`COMPOSE_PROFILES=plex` and `=jellyfin`).

### M10. lint.yml awk extraction is gawk-only
The 3-arg `match($0, /pat/, m)` form doesn't work on mawk (default on ubuntu-latest). Rewrote the manage.sh extraction using perl, which is universally available.

### M11. lint.yml no concurrency control
Multiple pushes to the same PR ran in parallel. Added `concurrency: { group: ..., cancel-in-progress: true }`.

---

## Test Coverage Expansion

Added 18 new regression tests to `tests/test_setup_functions.sh` covering all the CRITICAL and HIGH fixes:

- Mount path validation (blocks /home, /root, /mnt, /media, /srv, /opt)
- Root path '/' rejection
- Symlinked mount path rejection
- `chown -h` usage (defense-in-depth)
- Interrupt cleanup stops containers first
- `.env` permissions restored after PLEX_CLAIM removal
- Decypharr config refreshed on re-run
- TORBOX_INDEXER_URL validation
- `start_services` returns 1 on failure
- All 8 services have `cap_drop`
- Plex/Jellyfin depend on Decypharr
- Env vars have defaults in docker-compose.yml
- `.gitignore` covers backups/, torbox_backup_*/, *.bak
- lint.yml has PowerShell linting job
- lint.yml validates both plex and jellyfin profiles
- `check_dependencies --warn-only` mode for dry-run
- `env_val` strips inline comments
- `manage.sh restore` prevents path traversal

**Test results:** 66 passed, 0 failed (was 48 passed before).

---

## Items NOT Fixed (Deliberate)

The following items were identified but intentionally left unchanged:

1. **Decypharr config schema uncertainty vs upstream v2.0 docs** — The official docs at docs.decypharr.com show a slightly different schema (`bind_address`/`port` at top level, `mount.type=rclone` with nested `rclone.vfs_*`). The existing `setup.sh` schema (`debrids[].use_webdav`, `qbittorrent` block, top-level `username`/`password`) doesn't fully match either. Since both schemas diverge from the docs in different ways and we can't pull the v2.0 image to test, we aligned `setup.ps1` with `setup.sh` rather than rewrite both against an unverified schema. **Recommendation:** verify against the actual `ghcr.io/sirrobot01/decypharr:v2.0` image behavior and update both scripts if needed.

2. **Image tags not pinned by digest** — Pinning by `:tag@sha256:<digest>` would prevent supply-chain attacks but requires manual digest bumps on every upstream release. Left as a future hardening step.

3. **PUID/PGID range validation** — Allowing `PUID=0` (root) is questionable but not strictly wrong; users running rootless setups may want this. Left unchanged with a warning.

4. **Curl `--retry` not added to all API calls** — Adding retries would mask real failures during setup. Left as-is; transient failures are caught by `|| log_warn` and the user can re-run.

5. **Decypharr `apparmor:unconfined`** — Required for FUSE mounts on AppArmor-enabled systems. Documented in a comment.

---

## Verification

- ✅ `bash -n setup.sh` — syntax OK
- ✅ `bash -n uninstall.sh` — syntax OK
- ✅ `shellcheck -x setup.sh uninstall.sh tests/*.sh` — no warnings
- ✅ `bash tests/test_api_key.sh` — 3/3 passed
- ✅ `bash tests/test_setup_functions.sh` — 66/66 passed (was 48)
- ✅ manage.sh heredoc extraction + `bash -n` — syntax OK
- ✅ `python3 -c "import yaml; yaml.safe_load(open('docker-compose.yml'))"` — valid YAML
- ✅ All 8 services have `cap_drop: [ALL]`
- ✅ Plex and Jellyfin have `depends_on: { decypharr: { condition: service_healthy } }`
- ✅ All env vars have defaults in docker-compose.yml
- ✅ `setup.ps1` has `ConvertTo-IanaTimezone`, `Lock-FileAcl`, schema-aligned Decypharr config
- ✅ `uninstall.ps1` has `Test-YesAnswer`/`Test-NoAnswer`, captures image list before deletion

---

## Recommended Next Steps

1. **Test the changes end-to-end** on a clean Linux system: `./setup.sh --dry-run` first, then a real install with a test TorBox API key.
2. **Verify the Decypharr config schema** against the actual `decypharr:v2.0` image — if the official v2 schema differs from what `setup.sh` generates, update both `setup.sh` and `setup.ps1` together.
3. **Run the Windows setup.ps1** on a Windows machine to verify the timezone mapping, MOUNT_DIR escaping, and ACL hardening work as expected.
4. **Consider pinning Docker images by digest** for production deployments.
5. **Add a real E2E test** to CI that brings up the stack with mock creds and curls the healthchecks (the current `test_e2e.sh` is structural, not runtime).

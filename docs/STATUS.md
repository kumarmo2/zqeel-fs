# Project status and continuation notes

## Resume here

- Low-level FUSE migration is implemented on `feature/unlink` following checkpoint `8a4aa55` (`Add debug FUSE traces and document unlink design`); the user requested a commit and pull request for review. Existing file/directory operations have in-memory and authorized fresh-mount regression coverage.
- Regular-file unlink, empty-directory rmdir, and reclamation of inodes removed by the current session are implemented. **Rename, hard-link creation, and startup orphan recovery remain unimplemented.**
- `src/mount.zig` now registers `fuse_lowlevel_ops`, creates/mounts a session, and runs a single-threaded loop. Callbacks use inode IDs or parent/name pairs, not reconstructed paths.
- `src/store.zig` contains inode-based SQLite operations; the root ID is swapped with 1 as necessary for collision-free FUSE_ROOT_ID mapping. `setattr` combines size/timestamp changes atomically; ordinary MODE/UID/GID changes are explicitly unsupported.
- **TODO (user requested):** refactor `src/store.zig` to decouple its SQLite-backed operations from libfuse and move FUSE node-ID/root mapping and `FUSE_SET_ATTR_*` interpretation to the adapter. Consider Zig-native inputs and error unions instead of C-style output pointers/negative errno; translate POSIX/FUSE types and errors at the boundary while preserving specific SQLite error mapping. Design and implement only when requested.
- `src/runtime.zig` tracks handle-ID-to-inode state and separate open/kernel lookup references. `open`/`create` populate `fi->fh`; `release`, `releasedir`, `forget`, and `forget_multi` drop references and can reclaim zero-link inodes tracked by the current session. Shutdown retries outstanding reclamation after destroying the FUSE session and reports failure if cleanup still fails.
- `src/ffi.h` exports installed-header offsets for flags and fh, with width assertions; Zig accesses those scalar fields without guessing the opaque bitfield layout. The `field` helper in `src/mount.zig` now has a short explanation of byte offsets, alignment, and caller obligations. Write requests use current request flags (verified against libfuse 3.18.3 dispatch and fcntl/mmap smoke tests), not stale open-time flags.
- On `feature/database-locking`, format and mount hold a nonblocking exclusive advisory flock on the database inode until SQLite closes. This coordinates cooperating zqueel-fs instances on local filesystems; it does not prevent direct SQLite access or protect against pathname replacement. Do not implement orphan reclamation solely on the basis of this lock without addressing these limits.
- The user wants generic Linux knowledge retained in `docs/LINUX_FILESYSTEM_NOTES.md`. Its symlink-target SQL is illustrative only; no symlink schema migration or callback has been implemented.
- The first unprivileged pjdfstest pilot passed: 7 unchanged upstream scripts, 36 assertions. See [the test list and results](PJDFSTEST.md). The full and privileged suites have not been run.
- The user requested the low-level refactor after the checkpoint. They selected **per-open directory snapshots** with stable index cookies, and authorized fresh unprivileged mount/unmount smoke tests with artifacts retained and no cleanup. Existing `temp-dir/` and databases remain untouched. Crash-orphan recovery policy remains unresolved.
- Always use braces for statement-style if/else branches. Converted 79 unbraced branches across `src/main.zig`, `src/database_lock.zig`, and `src/mount.zig`; recorded the rule in `AGENTS.md`. Value-selecting if expressions remain inline; no behavior changes intended.
- All registered low-level callbacks guard `[fuse]` stderr traces with `builtin.mode == .debug`; release builds omit them. Traces now identify inode IDs or parent/name pairs, not paths; file contents are never logged. Names are raw filesystem bytes, so logs need not be UTF-8. Preserve manual changes and do not commit or implement additional operations without a request.

## Goal and confirmed decisions

- Build a production-grade SQLite-backed filesystem primarily for production agents.
- Implementation language/toolchain: Zig 0.17; database access through SQLite's C library; user prefers project implementation in Zig rather than C source files.
- Expose both an embedded API and a mountable filesystem.
- Separate inode identity, directory names, and file contents.
- Store contents in logical chunks, not one growing BLOB per file.
- Target POSIX metadata: file type/permissions, ownership, link counts, size, and timestamps.
- Begin external filesystem semantic testing with pjdfstest.
- Work on this machine for now; the user has no isolated environment.
- User requested a working mount for ordinary Linux file and directory commands, using libfuse3.
- Initial scope is basic shell operations with unsupported POSIX features reported explicitly.
- Formatting is a separate explicit command and must not overwrite existing databases.
- Restrict cooperating zqueel-fs instances to one active owner per database using an exclusive flock; different databases may be used concurrently.

## Current repository state

- `schema.sql` defines four application tables and the reverse directory-entry index.
- `inodes`: object identity and stat-like metadata; AUTOINCREMENT also creates SQLite's internal `sqlite_sequence` table.
- `dirents`: unique byte-oriented names within a parent directory, pointing to inodes.
- `file_chunks`: sparse, logically indexed content chunks with potentially short payloads.
- `fs_meta`: at most one row recording format version, root inode, and chunk size.
- `AGENTS.md` provides entry-point instructions for subsequent agents.
- `docs/LINUX_FILESYSTEM_NOTES.md` retains generic Linux filesystem knowledge: inodes/names, open/VFS/FUSE, descriptors versus open instances, unlink lifetime, links, redirection/truncation, timestamps, directories, and atomicity versus durability; examples are not implementation-status claims.
- `docs/INODE_MODES.md` explains file-type, permission and special mode bits, octal masks, umask, and their mapping to the current schema/code. General chmod/chown and non-file/directory types remain unsupported.
- `docs/SQLITE_FUNCTIONS.md` documents the SQLite C API calls used by the current Zig sources and the SQL `last_insert_rowid()` function, including ownership and error-handling caveats.
- `docs/FUSE_WORKFLOWS.md` compares current low-level and previous high-level workflows and summarizes callback reply functions versus lookup-reference accounting.
- `docs/UNLINK.md` explains unlink steps, regular-file nlink versus runtime reference counts, the implemented transaction and reclamation behavior, and outstanding crash recovery.
- `docs/RMDIR.md` explains empty-directory removal and how it shares unlink's lifetime rule.
- `src/main.zig` implements `format <new-database>` and `mount <database> <mountpoint>`; `src/ffi.h` exposes SQLite/FUSE/POSIX APIs through Zig translate-c.
- The formatter reserves a new file exclusively, locks it, initializes schema and root in one SQLite transaction, and refuses an existing path.
- `src/database_lock.zig` acquires a nonblocking exclusive flock using `std.os.linux.flock`; format and mount hold its close-on-exec descriptor until after SQLite closes. Contention reports `DatabaseInUse`; EINTR currently reports `DatabaseLock` without retry. Future embedded access must follow the same protocol.
- Locking is advisory, assumes a stable database pathname and cooperating processes, and is intended for local filesystems. Direct SQLite users and file replacement can bypass it; network filesystem behavior is not guaranteed. Orphan recovery is not implemented.
- Formatting selects format version 1, a 64 KiB chunk size, root mode 0755, and the formatter's effective uid/gid.
- `build.zig` links SQLite and libfuse3 and embeds the reviewed schema.
- `src/mount.zig` implements an experimental, foreground, single-threaded low-level FUSE adapter with init, lookup/forget/forget_multi, getattr/setattr, open/create/release, mkdir, unlink, rmdir, read/write, and opendir/readdir/releasedir. Single-threaded execution, default_permissions, kernel-applied umask, disabled writeback caching, and daemon-enforced append are preserved.
- `src/store.zig` reuses the chunk algorithms behind inode-based operations; directory handles own immutable snapshots. `src/runtime.zig` owns volatile handles and reference counts; teardown frees remaining runtime state without assuming final release/forget messages.
- File creation and mkdir share an atomic inode/dirent insertion helper with parent mtime/ctime updates and FUSE credentials.
- `store.unlinkName` removes one entry, verifies the remaining hard-link count, and updates target ctime and parent mtime/ctime in one transaction. The adapter preserves referenced zero-link files; reclaiming a file deletes chunks before the inode. The schema is unchanged.
- `store.rmdirName` checks live entries for emptiness and atomically removes the name, sets the target link count to zero, and decrements the parent's link count. A retained directory cannot receive new entries, and reads on its open directory handle return EOF. Reclamation shares unlink's reference checks and does not delete file chunks. No schema change.
- mkdir starts directories with nlink=2, increments parent nlink, and inherits gid/setgid from a setgid parent; the kernel applies umask.
- Timestamp changes now use low-level `setattr`, including explicit times, NOW flags and omitted fields. Combined size/timestamp requests use one transaction; explicit times override resize defaults. No-op requests do not bump ctime.
- `write` updates affected chunks, size, mtime and ctime in one SQLite transaction, supports append and sparse gaps, and clears setuid/setgid bits.
- Installed-header flags/fh offsets and width assertions replace the old flags-only ABI prefix. The adapter requests atomic O_TRUNC and killpriv v1 when supported, disables killpriv v2, and supports kernel kill-bit metadata flags without enabling chmod/chown.
- Resize uses `setattr`; shrinking trims/deletes discarded chunks and extension reads as zeros. `open` handles negotiated atomic O_TRUNC.
- Zig component tests live in `tests/database_lock_test.zig`, `tests/store_test.zig`, and `tests/runtime_test.zig`; run all three with `zig build test`. `tests/lowlevel_smoke.py` remains a separate, explicitly authorized fresh-mount test that retains artifacts.
- **Incomplete:** rename, startup orphan recovery, embedded filesystem API, migrations, broader pjdfstest coverage, durability validation, and a general cleanup runner. The mount cannot yet satisfy the full basic shell workflow.
- The mount opens SQLite read-write with foreign keys enabled and uses FUSE `default_permissions`; never use this preliminary code for production or concurrently modify its database.

## Operation tracking

Implemented means code exists, not that it is thoroughly tested or POSIX-compliant. The mount supports writes, append, and basic truncation.

| Operation | FUSE callback / component | Example | Status |
|---|---|---|---|
| Format a new database | Formatter | `zqueel-fs format new.db` | Implemented; refuses an existing path |
| Mount a database | Mount setup | `zqueel-fs mount test.db temp-mount/` | Implemented; foreground, single-threaded, limited mutations |
| Look up a path | Low-level `lookup(parent, name)` | Access `dir/file` | Implemented; inode-based child lookup, dot/dotdot, root mapping and lookup references |
| Read metadata | `getattr` | `stat file`, `ls -l` | Basic implementation |
| List a directory | `opendir`, `readdir`, `releasedir` | `ls directory/` | Per-open snapshots and continuation cookies; reopen to see new entries |
| Open an existing file | `open` | Open for reading | Basic implementation |
| Read file contents | `read` | `cat file` | Implemented, including zero-filled sparse ranges |
| Unmount | External FUSE utility | `fusermount3 -u temp-mount/` | Supported through external utility |
| Create a file | `create` | `touch file` | Basic empty-file creation implemented |
| Write or append | `write` | `echo hello > new-file`, `echo hello >> file` | Basic implementation; sparse, partial and cross-chunk writes supported |
| Resize a file | `setattr` (SIZE), `open` (O_TRUNC) | `truncate -s 100 file`, `echo text > existing-file` | Basic implementation; shrinking discards data and extension reads as zero |
| Delete a file | `unlink` | `rm file` | Implemented for regular files; open descriptors remain usable after unlink |
| Create a directory | `mkdir` | `mkdir dir`, `mkdir -p a/b` | Basic implementation; atomic creation, parent link counts/timestamps and setgid inheritance |
| Remove an empty directory | `rmdir` | `rmdir dir` | Implemented; nonempty directories are refused |
| Rename or move | `rename` | `mv old new` | Pending |
| Change permissions or owner | `chmod`, `chown` | `chmod 600 file` | Pending |
| Change timestamps | `setattr` (time flags) | `touch -t ... file` | Basic implementation; explicit times, now/omit, and ctime updates |
| Create links | `link`, `symlink`, `readlink` | `ln`, `ln -s` | Pending; phase-1 scope not decided |
| Sync data | `fsync`, `fsyncdir` | `fsync(2)` | Pending; durability contract also needs definition |
| Open-handle lifecycle | `open`/`create`, `release`, `forget` | Track live file/directory instances and kernel references | Implemented; zero-link inodes remain until their open and lookup references are gone |

| Other area | Status |
|---|---|
| Embedded Zig filesystem API | Pending |
| pjdfstest and regression tests | In-memory tests, explicit fresh-mount smoke script, and a passing seven-script pjdfstest pilot |
| Crash recovery, concurrent access, and durability validation | Pending |
| Clean handling of Ctrl+C | Session signal handlers and teardown implemented; fresh-mount smoke passed |

Update this table as operations are implemented or their scope changes; record validation separately.

## Proposed v1 details still subject to review

The schema records a concrete proposal, not approval of all operation semantics.

- Initial on-disk object types: regular files and directories only.
- Inode IDs are positive application-assigned/SQLite-generated identities; AUTOINCREMENT avoids reusing committed IDs.
- Filename values are BLOBs, compared byte-for-byte; empty names, slash, NUL, dot, and dot-dot are rejected.
- Dot and dot-dot are synthesized/resolved rather than stored as directory-entry rows.
- Multiple directory entries may reference a regular-file inode, leaving room for hard links; phase-1 hard-link support is not decided.
- No cascaded deletes; final inode/content reclamation must be explicit.
- Deferred ROLLBACK protects mutation callbacks on ordinary error returns, but its return code is currently ignored. Handling rollback failure/uncertain connection state is future hardening; process crashes rely on SQLite recovery rather than Zig defer.
- Timestamps are signed integer nanoseconds since the Unix epoch; ctime is status-change time, not birth time.
- Chunk size is persisted per database and must not change after formatting.
- The initial formatter uses a 64 KiB chunk size; this implementation choice needs performance measurement.
- A present chunk contains 1..chunk_size bytes; omitted suffix bytes and absent chunks read as zeros.
- Logical file length comes from inodes.size, not the number or lengths of chunk rows.
- STRICT tables require SQLite 3.37+; WITHOUT ROWID chunk storage uses SQL reads/updates, not sqlite3_blob_open.

## Applying the schema safely

For review/validation without creating a disk database:

```sh
sqlite3 -bail :memory: '.read schema.sql' 'PRAGMA integrity_check;' 'PRAGMA foreign_key_check;'
```

For an explicitly chosen NEW database only:

```sh
sqlite3 -bail filesystem.db < schema.sql
```

The script enables foreign keys before its DDL transaction. Every future SQLite connection must independently enable and verify foreign-key enforcement before transactions. Do not run the script inside an existing transaction. The script intentionally has no IF NOT EXISTS: existing tables should cause failure rather than conceal a schema mismatch.

The SQL script alone creates tables only. The implemented `format` command initializes schema, directory root (nlink=2), and metadata row in one transaction. If formatting fails, the newly created path is retained for inspection; it is never automatically deleted.

Journal mode, synchronous mode, busy handling, filesystem identity, and durability promises are not yet selected. Applying this DDL alone does not produce a usable or production-safe filesystem.

## Invariants required in the implementation

Enforce cross-row rules in the same transaction as the operation; foreign keys alone do not enforce them:

1. Each directory-entry parent is a directory.
2. Each non-root directory has exactly one parent; directories cannot be hard-linked or moved into their descendants.
3. Root is a directory, resolves its own parent, and cannot be removed, replaced, or given an ordinary incoming directory entry.
4. Only regular files own chunks; chunk payloads cannot exceed the configured chunk size.
5. Chunk offsets/file lengths are checked for overflow and chunks do not retain data past EOF.
6. Truncating removes later chunks and discards bytes past the new EOF in a retained tail, preventing stale-data exposure on extension.
7. Missing chunks, short-chunk suffixes, and gaps created by writes beyond EOF read as zeros.
8. Link counts track namespace mutations; directory counts follow the chosen POSIX directory convention, not a simple count of incoming dirents.
9. Rename/replacement, contents, sizes, link counts, and relevant timestamps change atomically.
10. Open handles keep unlinked inodes alive until final close; zero-link reclamation is explicit.
11. Orphan recovery cannot reclaim objects still open through another active filesystem instance.
12. A mounted/opened filesystem must have exactly one valid fs_meta row and a supported format version.

## Unresolved choices before implementation

- Approve or revise schema; choose chunk size and maximum file/name/path limits.
- Settle phase-1 operations: core files/directories versus hard links, symlinks, and additional POSIX functionality.
- Define rename replacement, unlink transaction/reclamation and crash recovery, directory size reporting, and broader timestamp-update policy. Inode-based lookup and volatile open/lookup accounting are implemented.
- Decide how shared-core code exposes embedded operations and the libfuse3 mount adapter.
- Design enforcement against non-cooperating database access and pathname replacement if required; the cooperative flock does not protect against either.
- Define permissions/credentials, umask, special bits, and enforcement responsibilities.
- Define write/fsync/directory-fsync and embedded transaction durability guarantees; select SQLite journaling/synchronous policy accordingly.
- Design bootstrap, shutdown, locking, interrupted-operation recovery, and schema version migrations.
- Consider directory enumeration cookies, st_blocks reporting, and inode-ID mapping for the mount adapter.

## Testing direction, deferred until operation design

- pjdfstest first for POSIX semantics; many cases need root and supported features.
- Maintain explicit passes/failures/unsupported cases; do not weaken tests to hide implementation errors.
- Later: fsx/fsstress, selected xfstests, model-based API tests, concurrency, fault injection, and crash recovery.
- SQLite integrity_check does not prove filesystem semantic consistency; foreign_key_check and filesystem invariants are separate checks.
- Planned same-machine lifecycle: fresh database and mount per run, keep logs, preserve failed-run artifacts.
- Cleanup must stop tests, unmount, verify unmounted, stop remaining filesystem processes, and only then remove verified owned paths.
- Cleanup is repeatability, not a privileged-test security boundary; review tests and obtain authorization before elevated execution.

## Validation log

- Inspected the initial Zig sources/build files without modifying them.
- Local tools report Zig 0.17.0 and sqlite3 CLI 3.54.0.
- Executed `schema.sql` in an in-memory database using the SQLite CLI: integrity_check returned `ok`; foreign_key_check returned no violations.
- Ran an ephemeral Python/SQLite in-memory smoke check: root/file metadata, a non-UTF-8 filename, and chunk content were accepted; all 24 invalid mutations were rejected.
- Rejection checks covered invalid filename bytes/types, duplicate keys, missing foreign-key targets, invalid mode/owner/size/link-count/chunk metadata, and deletion of a referenced inode.
- Verified the DDL leaves inodes/fs_meta empty for future atomic bootstrap; no on-disk database, mounts, privileged commands, or persistent test harness were used.
- Built the partial formatter with `zig build` using Zig 0.17, SQLite, and libfuse3.
- Formatted a temporary database, inspected root/metadata, checked integrity and foreign keys, and verified a second format refuses and leaves it unchanged.
- With user authorization, mounted a fresh temporary database unprivileged, listed and read an injected sparse file, verified writes fail with EROFS, unmounted and verified the mount was gone before cleanup.
- Earlier failed mount attempts were preserved at `/tmp/zqueel-fuse-smoke-qrvfd9a2` and `/tmp/zqueel-fuse-check-knfxvngx`; neither was mounted. Do not delete without authorization.
- After implementing empty-file create, built with `zig build` and tested an authorized temporary mount: creation, umask/mode, ownership, empty read, duplicate rejection, and unsupported write/truncate.
- Injected a SQLite trigger failure during dirent creation and verified rollback left no orphan inode; checked database integrity and foreign keys after unmount.
- Before utimens implementation, `touch` created an empty file but reported an error because timestamp updates were unimplemented.
- After implementing utimens, built with `zig build` and tested a fresh authorized temporary mount: touch new/existing, nanosecond and negative timestamps, UTIME_NOW/UTIME_OMIT, both-omit no-op, root-directory and file-descriptor updates.
- A trigger-injected SQLite update failure left the original timestamps unchanged; integrity and foreign-key checks passed after unmount.
- An earlier timestamp smoke-test attempt used a differently owned injected inode and failed at kernel permission checks as expected; its unmounted artifacts remain at `/tmp/zqueel-utimens-ygv686wz` for inspection.
- After implementing write, debug and ReleaseSafe builds passed. Authorized temporary-mount checks covered partial overwrites, cross-chunk writes, sparse gaps, append, concurrent append, shell creation/write, and persistence after remount.
- An injected SQLite failure on the second chunk rolled back the entire write; integrity and foreign-key checks passed. Truncation remains explicitly unsupported.
- Replaced the temporary C helper with a Zig ABI-prefix accessor; debug and ReleaseSafe builds passed, and an authorized temporary mount verified O_APPEND overrides a pwrite offset.
- Implemented `truncate` and the atomic O_TRUNC open path: debug and ReleaseSafe builds passed; an authorized temporary mount verified shell overwrite/append, ftruncate shrink/extend across chunk boundaries, zero-filled extension, rollback on injected chunk-delete failure, and persistence after remount.
- SQLite integrity and foreign-key checks passed after the truncation smoke test. Previously observed successful shell overwrites with stale trailing bytes resulted from libfuse's default atomic O_TRUNC path passing the flag to `open`, which previously ignored it.
- After implementing mkdir, debug and ReleaseSafe builds passed. An authorized fresh temporary mount validated mkdir/mkdir -p, mode/umask, ownership, parent/child link counts, nested file I/O, duplicate/missing-parent/non-directory/long-name errors, setgid inheritance, and persistence after remount.
- A trigger-injected parent-link-count update failure rolled back the new inode, directory entry and parent metadata; SQLite integrity/foreign-key checks passed and no directory content chunks were present.
- Subagent delegation was requested where relevant; no subagent tool was available in this earlier session.
- On `feature/database-locking`, debug and ReleaseSafe builds passed; `zig build test` exercised flock contention across a fork and independent descriptors, then reacquisition after close using an anonymous file. Expected contention diagnostics appear in test output. Builds and tests passed again after switching flock and test setup to `std.os.linux` APIs and removing the flock EINTR retry; EINTR itself was not injected.
- Formatted a fresh database and verified integrity, foreign keys, and existing-file refusal without modification. The test database is retained at `/tmp/zqueel-lock-check-84aptv1z`; no mount/unmount or cleanup was performed. No actual mount-lifetime integration test was run.
- Added `docs/FUSE_WORKFLOWS.md` after reviewing the current lookup/open/read callbacks and registration. Documentation-only work; no builds, mounts, or runtime tests were run for these diagrams.
- Added entry traces to all nine registered callbacks in `src/mount.zig`; paths are null-safe for logging, modes are octal, flags hexadecimal, and utimens includes timestamp values. `zig fmt --check src/mount.zig`, `zig build`, and `zig build -Doptimize=ReleaseSafe` passed. A read-only subagent review found no coverage or behavior-change issues beyond logging. No mounts or runtime callback tests were run for this change.
- Guarded callback traces with `builtin.mode == .debug`; this Zig 0.17 toolchain requires the lowercase enum tag rather than `.Debug`. Formatting, Debug and ReleaseSafe builds passed. Binary inspection confirmed no `[fuse]` strings in ReleaseSafe and all nine callback trace prefixes in Debug. The last build was Debug; no mounts or runtime callback tests were run.
- Converted statement-style if branches to braces. Comparison against the pre-edit sources confirmed only braces/whitespace changed in the three Zig files. Formatting, Debug/ReleaseSafe builds, and `zig build test` passed; a follow-up `--summary all` reported 4/4 steps succeeded. Read-only subagent audit found no missed statement branches or semantic issues. No mounts, unmounts, or cleanup performed; existing `temp-dir/` left untouched.
- Added `docs/UNLINK.md` with an unlink/nlink explanation and lifecycle diagram. Reviewed against `schema.sql` and current status; read-only subagent review found no substantive factual issues. Documentation-only change; diff whitespace checks passed, with no builds, runtime tests, mounts, or cleanup performed.
- Before the requested pre-refactor commit checkpoint, formatting, ReleaseSafe and Debug builds, `zig build test --summary all` (4/4 steps succeeded), and diff whitespace checks passed again. No mounts, unmounts, or runtime-data cleanup performed.
- Implemented the requested low-level FUSE migration without unlink or schema changes. Formatting, Debug/ReleaseSafe builds, and all 11 tests across the ownership/storage/runtime suites passed (some repeated runs reuse cached ownership results). New tests cover non-1 root mapping, byte names, dot/dotdot, missing-vs-database errors, creation/setgid/link-count rollback, sparse chunks/append/resize, combined setattr, unsupported chmod/chown, metadata/content rollback, reference overflow/underflow, allocation failure, stale/wrong-kind handles, and teardown ownership. ReleaseSafe binary inspection found no `[fuse]` strings; last executable build is Debug.
- With the user's explicit authorization, `tests/lowlevel_smoke.py` exercised a fresh unprivileged mount/remount: existing shell operations, umask/setgid/ownership, nanosecond/negative and FD timestamps, sparse/cross-chunk writes, O_APPEND including fcntl changes, mmap writes through an append-open descriptor, truncate shrink/extension and shell O_TRUNC, privilege-bit clearing, concurrent append, 700-entry multi-buffer directory snapshots, non-UTF-8 names, creation/resize rollback, unsupported chmod/link, database integrity/foreign keys/link counts, persistence, and Ctrl+C teardown. Final run passed; artifacts retained at `/tmp/zqueel-lowlevel-1enqgyrw`.
- Earlier fresh runs remain at `/tmp/zqueel-lowlevel-rp1jffpr` (filesystem checks passed, log UTF-8 decoding failed), `/tmp/zqueel-lowlevel-amvvltvv` (filesystem checks passed, an invalid expectation of kernel forget timing failed), and `/tmp/zqueel-lowlevel-ph6q_1a4` (passed). All four test mountpoints were verified unmounted; no cleanup or existing-database experimentation was performed. Forget accounting is unit-tested; the kernel may omit final forget messages at unmount.
- Read-only subagent audits caught stale saved append flags and an over-broad MODE privilege-clearing exception during implementation; both were corrected and covered by tests. Final audit found no concrete must-fix issues. Rollback failures/uncertain connection state remain existing hardening work; no POSIX/durability claim follows from these checks.
- Added `docs/INODE_MODES.md` at user request; checked schema/code constants and project limitations, with a read-only subagent fact check. Documentation only; no mounts or runtime tests were performed.
- Completed regular-file unlink and session-local reclamation. Debug and ReleaseSafe builds, formatting, and all 15 tests passed using a fresh Zig cache (the existing cache contained a malformed generated C binding). In-memory coverage includes multiple names, link-count consistency, inode identity after name reuse, and transaction/reclamation rollback and retry. The explicitly authorized fresh unprivileged smoke test passed: `rm`, missing name and directory rejection, multiple opens and `dup`, `O_PATH` after attribute-cache expiry, open-after-unlink I/O and resize, name reuse, reclamation, and remount. Artifacts retained at `/tmp/zqueel-lowlevel-clyu_315`; no existing filesystem data used. No crash or privileged tests run.
- Moved all 14 named Zig tests into three component suites under `tests/`; the former anonymous runtime import block was replaced by a standalone suite. Formatting, the Debug executable build, and all 14 tests in Debug and ReleaseSafe passed. No mount test was run for this reorganization.
- Implemented `rmdir`. Formatting, Debug and ReleaseSafe builds, and component tests passed (17 tests in ReleaseSafe; Debug reused cached lock/runtime results). New in-memory tests cover nonempty and invalid targets, link counts and timestamps, name reuse, creation rejection under detached directories, and rollback and reclamation retry. No mounts or runtime callback integration tests were run for rmdir.
- With explicit authorization, ran the [pjdfstest pilot](PJDFSTEST.md) on a fresh unprivileged mount. All 36 assertions passed; supplemental nonempty and open-directory removal checks passed. Verified unmounted, with clean SQLite integrity/foreign-key checks and no remaining zero-link inodes. Artifacts retained at `/tmp/zqueel-pjdfstest-YdSv0CS9`; no sudo or existing database used.
- These checks do not establish POSIX semantics, durability, security against hostile pathname replacement, or cross-row invariants.

## Suggested next work (only when requested)

1. Review unlink and its regression coverage. Resolve crash-orphan recovery policy before implementing automatic reclamation on startup.
2. Add rename and the shared embedded core only when requested; define synchronization, error mapping, permissions and crash/recovery behavior before relying on the filesystem.
3. Use `tests/lowlevel_smoke.py` for explicitly authorized fresh-mount regressions; it retains artifacts. Authorization for this migration's runs does not authorize privileged suites, crash tests, or destructive cleanup.
4. Add safe per-run test lifecycle and applicable pjdfstest cases when requested.

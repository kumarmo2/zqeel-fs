# Project status and continuation notes

## Resume here

- Last implementation commit: `1c9c3cd` (`Implement directory creation`); mkdir is implemented and validated. See the operation table below for the full baseline.
- The user requested unlink next, but implementation paused for Linux filesystem explanations. **No unlink callback or handle tracking has been implemented.**
- Before coding unlink, resolve its open-file semantics with the user: full Linux behavior with inode-based handles versus an explicitly limited EBUSY-on-open implementation. The user asked explanatory questions but has not selected either option.
- Current callbacks resolve objects by pathname. `open`/`create` do not allocate handle IDs; `fi->fh`, open-count maps, and `release` are not wired up. Supporting open-after-unlink requires more than deleting directory entries.
- Discussed design, not approved implementation: volatile handle-ID-to-inode/open-state mappings plus per-inode open-reference counts; reclaim only when both persistent nlink and open references reach zero. The kernel tracks application FDs and their sharing; FUSE release signals the end of an open instance.
- Only the initial flags field of opaque `fuse_file_info` is exposed by our Zig ABI-prefix accessor. Access to fh would need an extended, header-checked binding; do not assume it exists.
- On `feature/database-locking`, format and mount hold a nonblocking exclusive advisory flock on the database inode until SQLite closes. This coordinates cooperating zqueel-fs instances on local filesystems; it does not prevent direct SQLite access or protect against pathname replacement. Do not implement orphan reclamation solely on the basis of this lock without addressing these limits.
- The user wants generic Linux knowledge retained in `docs/LINUX_FILESYSTEM_NOTES.md`. Its symlink-target SQL is illustrative only; no symlink schema migration or callback has been implemented.
- pjdfstest was explained but not integrated or run. Test scripts often require mkdir/unlink/rmdir/chmod/chown beyond their named category; review dependencies and FUSE credential access before running privileged tests.
- The latest request was documentation of the SQLite functions currently used in the program. Preserve manual changes and do not commit or implement additional operations without a request.

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
- `docs/SQLITE_FUNCTIONS.md` documents the SQLite C API calls used by the current Zig sources and the SQL `last_insert_rowid()` function, including ownership and error-handling caveats.
- `src/main.zig` implements `format <new-database>` and `mount <database> <mountpoint>`; `src/ffi.h` exposes SQLite/FUSE/POSIX APIs through Zig translate-c.
- The formatter reserves a new file exclusively, locks it, initializes schema and root in one SQLite transaction, and refuses an existing path.
- `src/database_lock.zig` acquires a nonblocking exclusive flock using `std.os.linux.flock`; format and mount hold its close-on-exec descriptor until after SQLite closes. Contention reports `DatabaseInUse`; EINTR currently reports `DatabaseLock` without retry. Future embedded access must follow the same protocol.
- Locking is advisory, assumes a stable database pathname and cooperating processes, and is intended for local filesystems. Direct SQLite users and file replacement can bypass it; network filesystem behavior is not guaranteed. Orphan recovery is not implemented.
- Formatting selects format version 1, a 64 KiB chunk size, root mode 0755, and the formatter's effective uid/gid.
- `build.zig` links SQLite and libfuse3 and embeds the reviewed schema.
- `src/mount.zig` implements an experimental, foreground, single-threaded FUSE mount with getattr, readdir, open, sparse chunk read/write, truncate, file/directory creation, and utimens callbacks.
- File creation and mkdir share an atomic inode/dirent insertion helper with parent mtime/ctime updates and FUSE credentials.
- mkdir starts directories with nlink=2, increments parent nlink, and inherits gid/setgid from a setgid parent; the kernel applies umask.
- `utimens` updates atime/mtime and ctime atomically, supports UTIME_NOW and UTIME_OMIT, and relies on kernel default_permissions checks.
- `write` updates affected chunks, size, mtime and ctime in one SQLite transaction, supports append and sparse gaps, and clears setuid/setgid bits.
- Zig accesses the initial `int32_t flags` ABI field of opaque `fuse_file_info` via an extern-struct prefix; `src/ffi.h` has compile-time assertions for field offset and width against the installed libfuse headers.
- `truncate` handles shrink/extension and atomically trims/deletes discarded chunks with inode metadata; `open` handles libfuse's default atomic O_TRUNC path.
- **Incomplete:** delete/rmdir/rename, open-handle lifetime, embedded filesystem API, migrations, persistent tests, and cleanup runner are not implemented; the mount cannot yet satisfy the basic shell workflow.
- The mount opens SQLite read-write with foreign keys enabled and uses FUSE `default_permissions`; never use this preliminary code for production or concurrently modify its database.

## Operation tracking

Implemented means code exists, not that it is thoroughly tested or POSIX-compliant. The mount supports writes, append, and basic truncation.

| Operation | FUSE callback / component | Example | Status |
|---|---|---|---|
| Format a new database | Formatter | `zqueel-fs format new.db` | Implemented; refuses an existing path |
| Mount a database | Mount setup | `zqueel-fs mount test.db temp-mount/` | Implemented; foreground, single-threaded, limited mutations |
| Look up a path | Internal lookup | Access `dir/file` | Basic implementation |
| Read metadata | `getattr` | `stat file`, `ls -l` | Basic implementation |
| List a directory | `readdir` | `ls directory/` | Basic implementation |
| Open an existing file | `open` | Open for reading | Basic implementation |
| Read file contents | `read` | `cat file` | Implemented, including zero-filled sparse ranges |
| Unmount | External FUSE utility | `fusermount3 -u temp-mount/` | Supported through external utility |
| Create a file | `create` | `touch file` | Basic empty-file creation implemented |
| Write or append | `write` | `echo hello > new-file`, `echo hello >> file` | Basic implementation; sparse, partial and cross-chunk writes supported |
| Resize a file | `truncate`, `open` (O_TRUNC) | `truncate -s 100 file`, `echo text > existing-file` | Basic implementation; shrinking discards data and extension reads as zero |
| Delete a file | `unlink` | `rm file` | Pending |
| Create a directory | `mkdir` | `mkdir dir`, `mkdir -p a/b` | Basic implementation; atomic creation, parent link counts/timestamps and setgid inheritance |
| Remove an empty directory | `rmdir` | `rmdir dir` | Pending |
| Rename or move | `rename` | `mv old new` | Pending |
| Change permissions or owner | `chmod`, `chown` | `chmod 600 file` | Pending |
| Change timestamps | `utimens` | `touch -t ... file` | Basic implementation; explicit times, now/omit, and ctime updates |
| Create links | `link`, `symlink`, `readlink` | `ln`, `ln -s` | Pending; phase-1 scope not decided |
| Sync data | `fsync`, `fsyncdir` | `fsync(2)` | Pending; durability contract also needs definition |
| Open-handle lifecycle | `release` and shared core | Read an open file after unlink | Pending |

| Other area | Status |
|---|---|
| Embedded Zig filesystem API | Pending |
| pjdfstest and persistent regression tests | Pending |
| Crash recovery, concurrent access, and durability validation | Pending |
| Clean handling of Ctrl+C | Pending; currently may report `MountFailed` |

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
- Define path lookup, rename replacement, open/unlink lifetime, directory size reporting, and timestamp-update policy.
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
- These checks do not establish POSIX semantics, durability, security against hostile pathname replacement, or cross-row invariants.

## Suggested next work (only when requested)

1. Resume the unlink/open-file-lifetime scope discussion, then implement the agreed semantics; no choice has been finalized.
2. Add rmdir/rename and the shared embedded core only when requested; define synchronization, error mapping, permissions and crash/recovery behavior before relying on the filesystem.
3. Validate writable shell operations on a fresh dedicated mount; user authorized an unprivileged temporary mount smoke test.
4. Add safe per-run test lifecycle and applicable pjdfstest cases when requested.

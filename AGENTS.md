# Agent handoff: zqueel-fs

## Read first

1. Read `docs/STATUS.md`, starting with "Resume here", for decisions, unresolved questions, current state, and next steps.
2. Read `schema.sql` before proposing storage changes; each table and column has a one-line Linux filesystem mapping.
3. Read the current contents of any file before editing it; preserve user/manual changes unless explicitly asked to change them.

## Project constraints

- Production-oriented SQLite-backed filesystem for agents, implemented in Zig 0.17 using SQLite's C library; prefer Zig implementation code over project-owned C source.
- Intended interfaces: embedded library API and a mountable POSIX interface; libfuse3 is the selected mount technology.
- Chosen design direction: inode/directory-entry separation, chunked contents, and POSIX metadata.
- Current priority: implement a basic libfuse3 mount supporting normal file/directory shell operations; report unsupported features explicitly.
- First planned external semantic suite: pjdfstest; passing it will not establish durability or production readiness.

## Working rules

- Always use braces for statement-style `if`/`else` branches, including single statements; value-selecting `if` expressions may remain inline.

- Ask about meaningful unresolved design choices rather than treating proposals as approved requirements.
- Use subagents for relevant independent work when a subagent tool is available; the user explicitly requested this. Do not claim delegation when no such tool is available.
- Do not implement future work merely because it appears in the handoff checklist.
- Do not run privileged filesystem tests, mount/unmount commands, or destructive cleanup without explicit authorization.
- Work is currently on the user's main machine; there is no isolated test environment.
- Prefer in-memory databases for schema checks; never experiment against an existing filesystem database.
- `schema.sql` is a fresh-database DDL script, not an idempotent migration or a complete filesystem formatter.
- Preserve the schema's one-line table/column explanations when editing it.
- Keep `docs/STATUS.md` current after requested work: record decisions, changes, validation, and remaining issues.

## Files

- `schema.sql`: reviewable proposed v1 schema.
- `docs/STATUS.md`: project bookkeeping and continuation notes, including the paused unlink/open-handle design discussion.
- `docs/LINUX_FILESYSTEM_NOTES.md`: generic Linux concepts; illustrative designs are not implemented-feature claims.
- `src/main.zig`, `src/ffi.h`, `src/mount.zig`: formatter and experimental low-level FUSE adapter; file/directory creation, writes, truncation and timestamp updates are supported, while deletion and rename remain unimplemented.
- `src/store.zig`: inode-based SQLite operations; `src/runtime.zig`: volatile handles, lookup/open references, and directory snapshot ownership. No persistent inode reclamation yet.
- `tests/database_lock_test.zig`, `tests/store_test.zig`, `tests/runtime_test.zig`: component tests run by `zig build test`. `tests/lowlevel_smoke.py`: explicitly authorized unprivileged mount/unmount smoke test; retains fresh run artifacts.
- `build.zig`, `build.zig.zon`: Zig 0.17 executable configuration with SQLite and libfuse3 linkage.

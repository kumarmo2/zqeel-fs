# SQLite functions used by zqueel-fs

This is a guide to the SQLite C API calls currently used by `src/main.zig`, `src/mount.zig`, and the inode-based operations in `src/store.zig` (excluding test-only helpers). Zig accesses them through the translated declarations in `src/ffi.h`. It describes what the code does today, not a promise of complete error handling or production readiness. Consult the [SQLite C API reference](https://www.sqlite.org/c3ref/intro.html) for the full contracts.

The names below are C functions. SQLite types (`sqlite3`, `sqlite3_stmt`) and constants such as `SQLITE_OK` are not functions. The SQL function `last_insert_rowid()` is covered separately at the end.

## The usual lifecycle

1. **Open** a database connection with `sqlite3_open_v2`.
2. Execute simple SQL directly with `sqlite3_exec`, or **prepare** a statement with `sqlite3_prepare_v2`.
3. **Bind** parameters, then call `sqlite3_step` to execute and, for queries, obtain rows.
4. Read the current row with the appropriate `sqlite3_column_*` functions. A reusable statement can be reset and rebound.
5. **Finalize** every prepared statement, then **close** the connection.

For mutations, the filesystem groups related SQL changes in SQLite transactions. The separate database `flock` coordinates cooperating zqueel-fs instances; it does not replace SQLite transaction locking.

## Connections and SQL execution

### `sqlite3_open_v2`

Opens a database connection and writes its handle to an output parameter. The function returns a result code; it does not return the database handle directly. We use `SQLITE_OPEN_READWRITE`, without `SQLITE_OPEN_CREATE`, for both formatting and mounting. Formatting first creates a new file exclusively.

Check the result code even when a handle is returned: on most errors SQLite still provides a handle that must be closed; an allocation failure may leave it null. See [`sqlite3_open_v2`](https://www.sqlite.org/c3ref/open.html).

### `sqlite3_close`

Closes a connection after its statements and other dependent resources have been released. If resources remain, `sqlite3_close` can return `SQLITE_BUSY` and leave the connection open. Our code currently ignores its return value. See [`sqlite3_close`](https://www.sqlite.org/c3ref/close.html).

### `sqlite3_exec`

Executes one or more SQL statements from a NUL-terminated string. We use it for transaction control, schema setup and PRAGMAs. It returns `SQLITE_OK` on success or an error code. Our calls use null row-callback and error-message output arguments; the connection's error message can be obtained separately.

Our deferred rollback calls currently ignore their return codes, so a rollback failure is not reported. See [`sqlite3_exec`](https://www.sqlite.org/c3ref/exec.html).

### `sqlite3_errmsg`

Returns a human-readable message for the connection's most recent error. SQLite owns the returned string: do not free it, and copy it if it must survive later SQLite calls that change the error state or the connection's closure. The formatter uses it for diagnostics. See [`sqlite3_errmsg`](https://www.sqlite.org/c3ref/errcode.html).

### `sqlite3_errcode`

Returns the connection's most recent error code. `src/store.zig` maps selected SQLite errors to filesystem errno values, masking to the primary code. Read the error promptly: later SQLite calls can change the connection's error state. See [`sqlite3_errcode`](https://www.sqlite.org/c3ref/errcode.html).

## Prepared statements and parameters

### `sqlite3_prepare_v2`

Compiles the first SQL statement in a string into a `sqlite3_stmt`. The code passes `-1` for the length of NUL-terminated SQL and ignores the tail pointer. A successfully created, non-null statement must eventually be finalized. The `v2` interface retains the SQL text for automatic recompilation when applicable. See [`sqlite3_prepare_v2`](https://www.sqlite.org/c3ref/prepare.html).

### `sqlite3_bind_int` and `sqlite3_bind_int64`

Bind a 32-bit or signed 64-bit integer, respectively, to a statement parameter. **Parameter indexes start at 1**, unlike result-column indexes. Both return `SQLITE_OK` or an error. The formatter uses both; the mount uses `sqlite3_bind_int64` for inode IDs, metadata, offsets and other values.

Bindings remain after `sqlite3_reset`; replace them or clear them explicitly before reusing a statement when necessary. See [binding values](https://www.sqlite.org/c3ref/bind_blob.html).

### `sqlite3_bind_blob`

Binds bytes and an explicit byte length to a parameter. The mount uses it for byte-oriented directory names and file chunks. Every current call passes `SQLITE_TRANSIENT`, telling SQLite to copy the input before the bind call returns; the caller retains ownership of its buffer. It returns `SQLITE_OK` or an error. See [`sqlite3_bind_blob`](https://www.sqlite.org/c3ref/bind_blob.html).

### `sqlite3_step`

Runs or advances a prepared statement:

- `SQLITE_ROW`: a result row is available to read with `sqlite3_column_*`.
- `SQLITE_DONE`: execution completed; there are no more rows.
- Other results indicate an error or another condition needing handling.

Column data belongs to the current row and must be consumed before advancing, resetting or finalizing the statement. See [`sqlite3_step`](https://www.sqlite.org/c3ref/step.html).

### `sqlite3_reset`

Resets a prepared statement so it can be executed again. It does **not** clear existing parameter bindings. Its result can also report an error from the preceding evaluation. Our write path checks the result; the read path currently ignores it. See [`sqlite3_reset`](https://www.sqlite.org/c3ref/reset.html).

### `sqlite3_finalize`

Destroys a prepared statement and releases its resources. It can return an error associated with the statement's most recent evaluation; our code currently ignores that return value. Do not use a statement after finalizing it. See [`sqlite3_finalize`](https://www.sqlite.org/c3ref/finalize.html).

## Reading results

### `sqlite3_column_int` and `sqlite3_column_int64`

Read a column from the current result row as a 32-bit or signed 64-bit integer. **Column indexes start at 0.** SQLite may convert the stored value; SQL `NULL` becomes zero, so zero alone does not distinguish a null value. The mount uses these for metadata and configuration. See [result-column access](https://www.sqlite.org/c3ref/column_blob.html).

### `sqlite3_column_blob` and `sqlite3_column_bytes`

`sqlite3_column_blob` provides a pointer to the current column's BLOB bytes; `sqlite3_column_bytes` provides its length in bytes. The mount uses these for names and file chunks. SQLite owns the memory: do not free it, and copy it before stepping, resetting or finalizing the statement, or performing a conversion that invalidates the pointer.

A null pointer can represent SQL `NULL` or a zero-length BLOB, not only an allocation failure. A zero byte count also does not distinguish those cases. See [result-column access and pointer lifetimes](https://www.sqlite.org/c3ref/column_blob.html).

### `sqlite3_changes`

Returns the number of rows directly inserted, updated, or deleted by the most recent completed INSERT, UPDATE, or DELETE on the connection. Unlink checks the result after each single-row mutation to detect unexpected state; changes made by triggers are not counted. See [`sqlite3_changes`](https://www.sqlite.org/c3ref/changes.html).

## Inserted row identity

### `sqlite3_last_insert_rowid`

Returns the most recent successful rowid-table insert ID on that connection. The mount uses it after inserting an inode to create its directory entry. Inserts into `WITHOUT ROWID` tables are not recorded; a successful insert can remain the last insert even if its transaction is later rolled back. See [`sqlite3_last_insert_rowid`](https://www.sqlite.org/c3ref/last_insert_rowid.html).

### SQL `last_insert_rowid()`

This is a **SQL function**, not a C API call. The formatter uses it inside its `INSERT INTO fs_meta` statement to refer to the root inode inserted on the same connection. It exposes the same connection-specific last-insert-rowid value. See [SQLite core functions](https://www.sqlite.org/lang_corefunc.html#last_insert_rowid).

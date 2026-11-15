-- Proposed v1 schema for regular files and directories; requires SQLite 3.37+.
-- Apply once to a fresh database: sqlite3 -bail filesystem.db < schema.sql
-- DDL only: root inode and fs_meta initialization belong in a separate atomic bootstrap.
-- Enable foreign_keys on EVERY connection, before any transaction; this setting is not persisted.
PRAGMA foreign_keys = ON;

BEGIN IMMEDIATE;

-- inodes: Linux inode-like objects whose identity survives rename and unlink while open.
CREATE TABLE inodes (
    -- inode_id: stable filesystem object number exposed as stat.st_ino; committed IDs are not reused.
    inode_id INTEGER PRIMARY KEY AUTOINCREMENT,

    -- mode: stat.st_mode file type plus permissions/special bits; initially S_IFDIR or S_IFREG only.
    mode INTEGER NOT NULL CHECK (
        mode BETWEEN 0 AND 65535
        AND (mode & 61440) IN (16384, 32768)
    ),

    -- uid: owning Linux user ID exposed as stat.st_uid.
    uid INTEGER NOT NULL CHECK (uid BETWEEN 0 AND 4294967295),
    -- gid: owning Linux group ID exposed as stat.st_gid.
    gid INTEGER NOT NULL CHECK (gid BETWEEN 0 AND 4294967295),

    -- nlink: stat.st_nlink; zero permits an unlinked-but-open inode, and directories need special accounting.
    nlink INTEGER NOT NULL CHECK (nlink >= 0),
    -- size: stat.st_size logical byte length including sparse holes; directory reporting policy remains open.
    size INTEGER NOT NULL CHECK (size >= 0),

    -- atime_ns: stat.st_atim access time as signed nanoseconds since the Unix epoch.
    atime_ns INTEGER NOT NULL,
    -- mtime_ns: stat.st_mtim content/directory-entry modification time as Unix-epoch nanoseconds.
    mtime_ns INTEGER NOT NULL,
    -- ctime_ns: stat.st_ctim inode-status-change time as Unix-epoch nanoseconds, NOT creation time.
    ctime_ns INTEGER NOT NULL
) STRICT;

-- dirents: persistent directory names mapping to inodes, analogous to directory entries rather than kernel dentry caches.
CREATE TABLE dirents (
    -- parent_inode: containing directory inode used for path lookup and readdir; directory type is checked by Zig.
    parent_inode INTEGER NOT NULL
        REFERENCES inodes(inode_id),

    -- name: case-sensitive filename bytes, excluding NUL, slash, empty names, dot, and dot-dot.
    name BLOB NOT NULL CHECK (
        length(name) > 0
        AND instr(name, x'00') = 0
        AND instr(name, x'2F') = 0
        AND name NOT IN (x'2E', x'2E2E')
    ),

    -- target_inode: inode reached by this name; multiple regular-file names can support link(2).
    target_inode INTEGER NOT NULL
        REFERENCES inodes(inode_id),

    PRIMARY KEY (parent_inode, name)
) STRICT, WITHOUT ROWID;

-- dirents_by_target: supports reverse references and parent discovery for dot-dot resolution and namespace checks.
CREATE INDEX dirents_by_target ON dirents(target_inode);

-- file_chunks: logical regular-file data ranges backing read/write/truncate; absent ranges read as zeros.
CREATE TABLE file_chunks (
    -- inode_id: owning regular-file inode; Zig must reject chunks attached to other object types.
    inode_id INTEGER NOT NULL
        REFERENCES inodes(inode_id),

    -- chunk_index: zero-based logical chunk number, calculated as byte offset divided by fs_meta.chunk_size.
    chunk_index INTEGER NOT NULL CHECK (chunk_index >= 0),

    -- data: up to chunk_size payload bytes; missing suffix bytes are zeros, and reads stop at inode.size.
    data BLOB NOT NULL CHECK (length(data) > 0),

    PRIMARY KEY (inode_id, chunk_index)
) STRICT, WITHOUT ROWID;

-- fs_meta: singleton filesystem format/superblock-like metadata, populated atomically with the root inode.
CREATE TABLE fs_meta (
    -- singleton: constant key 1, limiting this database to at most one filesystem metadata row.
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),

    -- format_version: application schema/on-disk format version checked before mount or embedded API access.
    format_version INTEGER NOT NULL CHECK (format_version > 0),

    -- root_inode: root directory identity for absolute path lookup; root resolves its own dot-dot.
    root_inode INTEGER NOT NULL
        REFERENCES inodes(inode_id),

    -- chunk_size: immutable positive power-of-two logical allocation unit, independent of SQLite page size.
    chunk_size INTEGER NOT NULL CHECK (
        chunk_size > 0
        AND (chunk_size & (chunk_size - 1)) = 0
    )
) STRICT;

COMMIT;

-- Zig must enforce cross-row invariants within each mutation transaction; see docs/STATUS.md.
-- No cascading deletes: unlink removes a name, while final inode reclamation is an explicit lifecycle operation.
-- WITHOUT ROWID content tables use SQL I/O, not sqlite3_blob_open incremental BLOB handles.

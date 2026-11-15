# Linux filesystem notes

Generic Linux filesystem concepts discussed while building zqueel-fs. Examples describe normal Linux behavior, not a claim that this project's filesystem implements every operation.

## 1. Names, inodes, and contents are separate

An inode represents a filesystem object's identity and metadata. Regular files, directories, and symbolic links all have inodes.

```text
Directory entry: "notes.txt" -> inode 42
Inode 42: type, permissions, owner, size, timestamps, link count
File data: contents associated with inode 42
```

A filename belongs to a directory entry, not to the inode. A pathname is a sequence of names resolved through directories.

| Inode information | Meaning |
|---|---|
| Inode number | Object identity within one filesystem; not globally unique |
| Type and mode | Regular file/directory/symlink, permissions, and special bits |
| UID/GID | Owner and group |
| Size | Logical length; not necessarily allocated disk space |
| Link count (`st_nlink`) | Number of hard links, with special directory conventions |
| Timestamps | Access, modification, and inode-status-change times |

`ls -i file` shows its inode number. Across mounted filesystems, `(st_dev, st_ino)` is commonly used to distinguish identities; inode numbers can be reused after deletion.

## 2. What open() does

```c
int fd = open("/mnt/notes.txt", O_RDWR);
```

Conceptually:

1. The application makes a syscall (a library's `open()` wrapper may use `openat()`).
2. Linux's Virtual Filesystem layer (VFS) resolves the path across directories and mounts and checks access.
3. Linux invokes filesystem-specific operations as needed.
4. On success, the kernel installs and returns a file descriptor in the calling process.

An open normally does not read the contents. Later `read()` and `write()` calls transfer bytes. Flags can also request creation (`O_CREAT`), exclusive creation (`O_CREAT | O_EXCL`), truncation (`O_TRUNC`), or append (`O_APPEND`). These are distinct behaviors, not all necessarily implemented in a filesystem's open callback.

For a kernel filesystem such as ext4, filesystem code runs in the kernel. For FUSE, the kernel sends requests to a userspace filesystem process, where libfuse invokes callbacks.

### Three different identifiers

| Identifier | Managed by | Purpose |
|---|---|---|
| File descriptor, e.g. `3` | Kernel, in a process's descriptor table | Application reference used in read/write/close calls |
| Filesystem-private open state, e.g. FUSE `fi->fh` | Filesystem implementation | Optional state/identifier passed back in later filesystem requests |
| Inode number, e.g. `42` | Filesystem | Identifies the underlying filesystem object |

The filesystem's open callback returns success or an error, not the application's FD. A FUSE filesystem may populate `fi->fh`, but it is not required to do so.

## 3. File descriptors versus open file descriptions

A file descriptor points to a kernel open file description, which holds state such as the current offset and file status flags.

- Two independent `open()` calls normally create separate open file descriptions and offsets, even for the same inode.
- `dup()` and inherited descriptors after `fork()` can refer to the same open file description and share its offset.
- The kernel tracks descriptor ownership and sharing; a filesystem does not scan processes or maintain their FD tables.
- FUSE `release` is issued when the kernel no longer needs an open instance, not on every individual descriptor close.
- FUSE `flush` and `release` are different; `flush` is not a substitute for final-release accounting or a guarantee that data reached disk.

A FUSE implementation can maintain `handle ID -> inode/open state` and an inode reference count. This is a design choice, not a universally required table or on-disk schema.

## 4. Unlink is removing a name, not necessarily the data

`unlink()` removes a directory entry and decreases the inode's hard-link count. `rm file` ordinarily uses an unlink-family operation.

```text
A opens notes.txt
B opens notes.txt
Someone unlinks notes.txt -> name disappears
A and B can still read/write through existing descriptors
Last open reference is released -> reclaim if no hard links remain
```

The useful simplified reclamation rule is:

```text
no hard links AND no remaining open references -> file storage can be reclaimed
```

Actual implementations also account for other references, such as memory mappings, and may defer physical reclamation.

The other process does not automatically get an error or notification just because the name was removed:

| Action after the last name is unlinked | Result |
|---|---|
| Read/write using an existing descriptor | Continues to work |
| `fstat()` the descriptor | Reports link count zero |
| Open the old pathname again | `ENOENT`, unless the name has been recreated |
| Recreate the same pathname | Creates a different object; old descriptors still reference the original |

Open state is normally volatile. Recovering leftover unlinked objects after a crash needs a deliberate recovery design, especially if several instances can access the same backing store.

## 5. Hard links

A hard link is another directory entry pointing to the same inode, not a copy and not a pathname-based shortcut.

```sh
echo hello > original.txt
ln original.txt another.txt
```

```text
original.txt --+
               +--> inode 42 --> contents
another.txt ---+
```

- Neither name is primary; both refer to the same object.
- Writes through either name affect the same contents and metadata.
- Two names give `st_nlink = 2`; removing one leaves the other usable.
- Hard links cannot cross filesystem boundaries.
- Ordinary applications cannot create hard links to directories.

## 6. Symbolic links (soft links)

A symlink is a separate inode whose payload is a target pathname.

```sh
ln -s original.txt shortcut.txt
```

```text
shortcut.txt -> symlink inode -> target path "original.txt"
original.txt -> regular inode -> file contents
```

Linux reads the target and continues pathname resolution. A relative target is resolved from the directory containing the symlink, not from the application's current working directory. An absolute target starts from the process's filesystem root.

### Where the target is stored

"Target bytes" means the pathname's characters stored as data, not the target file's contents or inode number. For `ln -s /data/report.txt shortcut`, the stored payload is `/data/report.txt`.

There is no global Linux symlink table. Each filesystem defines how a symlink inode locates its payload: ext4 can store short targets inside the inode and longer targets in separate data blocks. The filesystem retrieves that payload when Linux follows the link or an application calls `readlink()`.

A symlink does not track the identity of the target object. Moving the target does not update the stored path; the link may become dangling. Replacing the object at the stored path makes the link resolve to the replacement.

### Illustration using our SQL design (not implemented)

The current `schema.sql` allows only regular files and directories and has no symlink target storage. One possible future design is a separate table keyed by inode ID:

```sql
-- Illustration only; not part of the current schema.
CREATE TABLE symlink_targets (
    inode_id INTEGER PRIMARY KEY REFERENCES inodes(inode_id),
    target BLOB NOT NULL
) STRICT;
```

```text
dirents:          "shortcut" -> inode 57
inodes:           inode 57, type = symlink
symlink_targets:  inode 57 -> bytes "/data/report.txt"
```

The shared `inode_id` associates the inode with its payload; a foreign key alone would not enforce that the inode is a symlink. Implementing this would also require allowing the symlink type in `inodes.mode`, validating targets, and adding create/readlink operations. A FUSE `readlink` callback would return the stored target; Linux would then resolve it.

| Property | Hard link | Symlink |
|---|---|---|
| Separate inode | No | Yes |
| References | Same filesystem object | Target pathname |
| Can cross filesystems | No | Yes |
| Can refer to a directory | Generally not allowed | Yes |
| Target name removed | Other hard link remains valid | Can become dangling |
| Target name replaced with a new object | Still refers to original inode | Resolves the new object at that path |

`stat()` follows a symlink; `lstat()` reports the symlink itself; `readlink()` returns its stored target. A symlink's own size is normally the target pathname's byte length. In FUSE, `symlink` creates the link and `readlink` returns its target; the kernel handles normal following.

## 7. Creation, writing, truncation, and shell redirection

| Operation | Meaning |
|---|---|
| Create | Add a new object and name; a new regular file starts empty |
| Write | Replace bytes at an offset and extend length if needed; does not remove an old suffix |
| Truncate smaller | Discard bytes beyond the new EOF |
| Truncate larger | Extend logical length; new bytes read as zeros |
| Append | Select the current EOF as the write position; Linux `O_APPEND` combines position selection and writing atomically |

The shell, not `echo`, interprets these operators:

```sh
echo hello > file.txt    # Create if absent; truncate if present; write "hello\n".
echo more >> file.txt    # Create if absent; append "more\n".
```

For ordinary output redirection, `>` uses open flags equivalent to `O_WRONLY | O_CREAT | O_TRUNC`; `>>` uses `O_WRONLY | O_CREAT | O_APPEND` (shell options can affect details).

Writing a shorter string at offset zero without truncating leaves old trailing bytes. After shrink-then-extend, discarded bytes must not reappear. Sparse ranges can read as zeros without physically storing those zeros.

For FUSE, `O_TRUNC` can reach either truncate or open depending on negotiated capabilities; implementing only one path without accounting for the other can produce incorrect overwrites.

## 8. Timestamps and touch

| Timestamp | Meaning |
|---|---|
| `atime` | Last access time; actual updates depend on mount policy such as relatime/noatime |
| `mtime` | Last content modification; directory entry changes modify directory mtime |
| `ctime` | Last inode status change, not creation time |
| Birth time, if supported | Creation time; separate from ctime |

`touch file` creates it if missing and normally updates access/modification times. Creation and updating existing timestamps are separate filesystem operations, so creation alone is insufficient for general touch behavior.

The FUSE `utimens` callback handles atime/mtime changes with nanosecond resolution:

- Explicit timestamp: set the requested time.
- `UTIME_NOW`: use current time.
- `UTIME_OMIT`: preserve that timestamp.
- Both omitted: no timestamp change, including ctime.
- Otherwise, an accepted timestamp mutation also updates ctime; callers cannot directly choose ctime with utimensat.

## 9. Directory creation

`mkdir()` creates a directory inode and adds a name in its parent, updating parent metadata. Traditional Unix directory link counts start at two (dot and the parent entry); each immediate subdirectory contributes another link through dot-dot. Not every filesystem reports directory counts identically.

Creation permissions are affected by umask; setgid directories typically pass their group to new children and setgid to new subdirectories. ACLs and filesystem policies can further affect permission handling.

## 10. Atomic operations versus durability

A namespace mutation may require multiple internal updates. For a database-backed filesystem, a single transaction can ensure they all commit or all roll back. A failed SQL statement alone does not necessarily undo earlier successful statements; the transaction must be rolled back or otherwise resolved.

Atomicity is not the same as durability: crash/power-loss guarantees also depend on journaling, synchronization, the host filesystem, and storage behavior. A successful write is not universally a promise that data has reached persistent media; synchronization operations have their own contracts.

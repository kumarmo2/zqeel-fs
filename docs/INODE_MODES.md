# Understanding inode mode bits

An inode's **mode** describes its file type, access permissions, and special permission bits. On Linux it is exposed as `stat.st_mode`; in zqueel-fs it is stored in the `inodes.mode` SQLite integer column.

This note explains generic Linux concepts first. The project currently supports only regular files and directories, and does not implement general `chmod` or `chown`.

## 1. One number, several meanings

For example, `0o100644` is a regular file with permissions `rw-r--r--`:

```text
0o  100000    0     6     4     4
    └ type ┘  │     │     │     └ other: r--
              │     │     └ group: r--
              │     └ owner: rw-
              └ special bits: none
```

`0o` is Zig's prefix for an octal (base-8) number. Each octal digit represents three bits:

```text
4 = 100 = read       2 = 010 = write       1 = 001 = execute
6 = 110 = read+write 5 = 101 = read+execute 7 = 111 = all three
```

The mode is a **bit field**, not a decimal string. Type values are not individual flags; mask and compare them.

## 2. File type

The type bits tell Linux what kind of object the inode represents.

| Name | Octal value | `ls -l` first character | zqueel-fs schema |
|---|---:|---|---|
| `S_IFREG` | `0o100000` | `-` | Allowed |
| `S_IFDIR` | `0o040000` | `d` | Allowed |
| `S_IFLNK` | `0o120000` | `l` | Not allowed yet |
| `S_IFIFO` | `0o010000` | `p` | Not allowed yet |
| `S_IFCHR` | `0o020000` | `c` | Not allowed yet |
| `S_IFBLK` | `0o060000` | `b` | Not allowed yet |
| `S_IFSOCK` | `0o140000` | `s` | Not allowed yet |

Use the **type mask** `S_IFMT = 0o170000` to isolate these bits:

```zig
const kind = mode & 0o170000;
if (kind == 0o100000) {
    // Regular file.
} else if (kind == 0o040000) {
    // Directory.
}
```

Example:

```text
0o100644 & 0o170000 = 0o100000   regular file
0o040755 & 0o170000 = 0o040000   directory
```

In `src/store.zig`, the equivalent checks use hexadecimal: `0xf000` is `0o170000`, `0x8000` is `0o100000`, and `0x4000` is `0o040000`.

## 3. The nine ordinary permission bits

Each group has three bits: read (`r` = 4), write (`w` = 2), and execute (`x` = 1).

| Who | Read | Write | Execute |
|---|---:|---:|---:|
| Owner | `0o400` | `0o200` | `0o100` |
| Group | `0o040` | `0o020` | `0o010` |
| Others | `0o004` | `0o002` | `0o001` |

Mask with `0o777` to extract these nine bits:

```text
0o100644 & 0o777 = 0o644 = rw-r--r--
0o040755 & 0o777 = 0o755 = rwxr-xr-x
```

### For a regular file

- **Read** allows reading file contents.
- **Write** allows changing file contents, subject to other checks.
- **Execute** allows executing it as a program, subject to other checks.

### For a directory

- **Read** permits listing entry names.
- **Write**, together with search permission, permits namespace changes such as creating or removing entries, subject to additional checks.
- **Execute** means **search/traverse**: accessing children by name or traversing through the directory. It does not mean running the directory as a program.

For example, deleting `dir/file` generally depends on permissions on `dir`, not on whether `file` itself is writable. Sticky-bit rules and other restrictions can also apply.

The kernel checks the applicable owner/group/other class using process credentials, alongside other security mechanisms; these bits alone do not describe every access decision.

## 4. The three special bits

| Bit | Octal | Typical meaning |
|---|---:|---|
| Set-user-ID (setuid) | `0o4000` | On an executable file, execution may use the file owner's effective UID. |
| Set-group-ID (setgid) | `0o2000` | On an executable file, execution may use the file's group; on a directory, new entries typically inherit its group and new subdirectories inherit setgid. |
| Sticky | `0o1000` | On a directory, restricts who may remove or rename entries, even if directory permissions otherwise allow it. |

These are simplified descriptions: Linux credentials, capabilities, mount flags, ACLs, and other rules affect the final behavior. The sticky bit's modern practical use is on directories such as `/tmp`.

`0o7777` masks the **three special bits plus the nine ordinary bits**:

```text
0o042775 & 0o7777 = 0o2775
                      │└── 775: rwxrwxr-x
                      └─── 2: setgid
```

`ls -l` shows special bits in place of execute characters:

- Owner execute position: `s` means setuid and execute; `S` means setuid without execute.
- Group execute position: `s` means setgid and execute; `S` means setgid without execute.
- Others execute position: `t` means sticky and execute; `T` means sticky without execute.

For example, a setgid directory with `0o2775` permissions displays `drwxrwsr-x`.

## 5. Type and permissions are combined

A mode can be constructed with bitwise OR:

```zig
const regular_file = 0o100000 | 0o644; // 0o100644
const directory = 0o040000 | 0o755;    // 0o040755
```

In `src/store.zig`, creation combines the chosen type, requested permission/special bits, and any inherited directory setgid bit:

```zig
(mode & 0o7777) | kind | inherited
```

This is why a database inode's mode includes the type as well as the permissions: `0o100644`, not just `0o644`.

## 6. Creation and umask

For the ordinary nine permission bits, absent a default ACL, creation generally applies:

```text
requested permissions & ~umask
```

For example, file creation requesting `0o666` with umask `0o022` produces `0o644`; requesting directory permissions `0o777` produces `0o755`. Actual creation behavior can also depend on ACLs, filesystem rules, and special-bit handling.

In our FUSE mount, the kernel applies umask before creation callbacks. If a parent directory has setgid, our creation logic gives new files and directories the parent's group and gives new subdirectories the setgid bit.

## 7. How this maps to our schema and code

`schema.sql` checks the type using **decimal SQL constants**:

```sql
(mode & 61440) IN (16384, 32768)
```

Those numbers correspond to:

| Decimal in SQL | Zig octal | Meaning |
|---:|---:|---|
| `61440` | `0o170000` | File-type mask |
| `16384` | `0o040000` | Directory |
| `32768` | `0o100000` | Regular file |

The formatter creates root with mode `0o040755`. On successful content writes and resizing, our existing implementation clears setuid and setgid bits; that internal behavior does **not** mean ordinary `chmod` is implemented. The mount delegates permission checks to Linux using `default_permissions`, but broader POSIX permission semantics remain incomplete.

On a normal Linux filesystem, `stat -c '%f %a %A' file` displays the mode in hexadecimal, the permission/special bits in octal, and a symbolic representation. It does not modify the file. Avoid interpreting these examples as claims that all listed types or operations work on our mount.

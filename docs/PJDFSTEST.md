# pjdfstest pilot

[pjdfstest](https://github.com/pjd/pjdfstest) checks what filesystem operations do from an application's point of view. For this pilot we selected individual upstream scripts whose setup, checks, and cleanup use operations zqueel-fs already supports. We didn't modify the scripts.

## Tests run

All seven scripts passed (36 assertions) on a fresh zqueel-fs mount, as the same unprivileged user who mounted it. Upstream revision: [`85a8aea9e685999ef0540392fd80535f873d7ff7`](https://github.com/pjd/pjdfstest/tree/85a8aea9e685999ef0540392fd80535f873d7ff7).

| Upstream script (under `tests/`) | What it checks | Passed |
|---|---|---:|
| `rmdir/00.t` | Remove empty directories, confirm the name disappears, and check the parent's updated timestamps | 10/10 |
| `rmdir/04.t` | Removing an already-removed or nonexistent name returns `ENOENT` | 4/4 |
| `rmdir/12.t` | Linux rejects removal through a final `/.` or `/..` | 6/6 |
| `truncate/02.t` | Grow a file with a maximum-length name and reject a longer name | 5/5 |
| `truncate/09.t` | Truncating a directory returns `EISDIR` | 3/3 |
| `ftruncate/13.t` | Truncating an open file to a negative length returns `EINVAL` | 4/4 |
| `unlink/04.t` | Remove a regular file and reject missing names | 4/4 |

Separate mounted checks also passed: a hidden file blocks directory removal without losing its contents; after the file is removed, an open directory handle survives `rmdir` with zero links and an empty listing; recreating the name gives it a new inode. The mount was unmounted successfully, and afterward SQLite integrity and foreign-key checks passed with no zero-link inodes left. The empty listing is an application-visible check; Linux can stop the read before FUSE sees it.

## Not run yet

- Scripts needing `chmod`, `chown`, rename, links, or special files. A script's folder name doesn't tell you everything it uses: for example, `mkdir/00.t` also changes permissions and ownership.
- Scripts that switch user IDs or need root, and the full suite. Upstream documents the full suite as root-only. The existing FUSE mount does not grant access to other users by default.

Artifacts retained in `/tmp/zqueel-pjdfstest-YdSv0CS9`: `prove.log`, `mount.log`, `upstream-build.log`, the pinned upstream checkout, and the disposable database. No existing filesystem database was used.

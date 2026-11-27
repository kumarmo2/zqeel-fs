# How `rmdir` works

Like [`unlink`](UNLINK.md), `rmdir` removes a name first and cleans up the underlying record when nothing needs it anymore. The main difference is that `rmdir` only removes **empty directories**.

## What happens when you run `rmdir projects/drafts`

1. **Find the directory.** The Mount module receives the request to remove `drafts` from `projects`. If the name doesn't exist or points to a file, the request fails. The filesystem root, `.`, and `..` aren't removable entries.
2. **Check that it's empty.** The Store checks what's actually in `drafts` now, not what an earlier listing showed. A single file (even a hidden one) or an empty subdirectory is enough to refuse removal. Nothing inside is deleted.
3. **Remove the name and update the records together.** The Store removes `drafts` from `projects`, marks `drafts` as having zero links, and lowers the parent's link count by one because it lost a subdirectory. It updates the change times for both directories and the parent's last-modified time. If any part fails, none of those changes take effect.
4. **Report success once the name is gone.** A new attempt to open `projects/drafts` by name will fail. If someone creates a new `drafts` there, it is a separate directory; old open handles won't switch to it.

## What if someone already has it open?

An open handle doesn't stop us from removing an empty directory. It can still refer to the old directory, but reading its listing gives no more entries, and nobody can create files or subdirectories inside it. An earlier listing of the **parent** may still show the old name because listings are snapshots; seeing the name there doesn't mean it can still be opened.

Runtime tracks whether an open handle or Linux still holds a reference to the old directory. Once both are gone, the Store can delete the leftover record. This uses the same lifetime rule as `unlink`, but there are no file contents to clean up. Recovering leftover records after a crash is separate work.

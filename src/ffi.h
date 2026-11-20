#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sqlite3.h>
#define FUSE_USE_VERSION 31
#include <fuse3/fuse_lowlevel.h>
#include <errno.h>
#include <sys/stat.h>

/* translate-c cannot represent fuse_file_info bitfields. Export installed-header
 * offsets so Zig can access scalar fields without guessing padding or bitfields. */
#include <stddef.h>
enum {
    ZQ_FI_FLAGS_OFFSET = offsetof(struct fuse_file_info, flags),
    ZQ_FI_FH_OFFSET = offsetof(struct fuse_file_info, fh),
};
_Static_assert(sizeof(((struct fuse_file_info *)0)->flags) == 4, "fuse_file_info flags width changed");
_Static_assert(sizeof(((struct fuse_file_info *)0)->fh) == 8, "fuse_file_info fh width changed");

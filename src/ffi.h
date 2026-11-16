#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sqlite3.h>
#define FUSE_USE_VERSION 31
#include <fuse3/fuse.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/syscall.h>
#include <sys/wait.h>

/* Verify the ABI prefix accessed in Zig; translate-c cannot represent the bitfields. */
#include <stddef.h>
_Static_assert(offsetof(struct fuse_file_info, flags) == 0, "fuse_file_info flags offset changed");
_Static_assert(sizeof(((struct fuse_file_info *)0)->flags) == 4, "fuse_file_info flags width changed");

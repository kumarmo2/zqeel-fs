#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sqlite3.h>
#define FUSE_USE_VERSION 31
#include <fuse3/fuse.h>
#include <errno.h>
#include <sys/stat.h>

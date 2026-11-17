#!/usr/bin/env python3
"""Explicitly invoked, unprivileged FUSE smoke test. Retains all run artifacts.

Run only with authorization to mount/unmount a fresh test filesystem:
    python3 tests/lowlevel_smoke.py
Never uses an existing database or deletes run directories.
"""
import ctypes
import errno
import fcntl
import mmap
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

BINARY = Path("zig-out/bin/zqueel-fs").resolve()
RUN = Path(tempfile.mkdtemp(prefix="zqueel-lowlevel-"))
DB = RUN / "fs.db"
MOUNT = RUN / "mount"
MOUNT.mkdir()
print(f"Artifacts retained: {RUN}", flush=True)
subprocess.run([BINARY, "format", DB], check=True)
with sqlite3.connect(DB) as db:
    db.execute("UPDATE inodes SET mode=? WHERE inode_id=1", (0o42775,))
    for name in ("priv-write", "priv-truncate"):
        inode = db.execute("INSERT INTO inodes(mode,uid,gid,nlink,size,atime_ns,mtime_ns,ctime_ns) VALUES(?,?,?,1,8,0,0,0)", (0o106755, os.getuid(), os.getgid())).lastrowid
        db.execute("INSERT INTO dirents VALUES(?,?,?)", (1, name.encode(), inode))
        db.execute("INSERT INTO file_chunks VALUES(?,0,?)", (inode, b"original"))
    db.executescript("""
    CREATE TRIGGER fail_creation BEFORE INSERT ON dirents WHEN NEW.name=x'726f6c6c6261636b'
    BEGIN SELECT RAISE(ABORT,'injected creation failure'); END;
    CREATE TRIGGER fail_resize BEFORE UPDATE ON inodes
    WHEN NEW.size=3 AND EXISTS(SELECT 1 FROM dirents WHERE target_inode=OLD.inode_id AND name=x'6661696c2d726573697a65')
    BEGIN SELECT RAISE(ABORT,'injected resize failure'); END;
    """)

process = None
log = None


def start(number):
    global process, log
    log = (RUN / f"mount-{number}.log").open("wb")
    process = subprocess.Popen([BINARY, "mount", DB, MOUNT], stdout=log, stderr=log)
    for _ in range(150):
        if os.path.ismount(MOUNT):
            return
        if process.poll() is not None:
            raise RuntimeError(f"mount exited {process.returncode}; inspect {log.name}")
        time.sleep(0.04)
    raise RuntimeError("mount timeout")


def stop(interrupt=False):
    global process, log
    if process is None:
        return
    if os.path.ismount(MOUNT):
        if interrupt and process.poll() is None:
            process.send_signal(signal.SIGINT)
        else:
            subprocess.run(["fusermount3", "-u", MOUNT], check=True)
    try:
        code = process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.terminate()
        code = process.wait(timeout=10)
        raise RuntimeError(f"mount process did not exit normally: {code}")
    finally:
        log.close()
    assert not os.path.ismount(MOUNT), "mount unexpectedly remains active"
    assert code == 0, f"mount process exited {code}"
    process = None


def expect_error(fn, allowed):
    try:
        fn()
    except OSError as error:
        assert error.errno in allowed, error
    else:
        raise AssertionError("operation unexpectedly succeeded")


try:
    start(1)
    old_umask = os.umask(0o027)
    try:
        (MOUNT / "projects" / "second" / "third").mkdir(parents=True)
        (MOUNT / "mode-file").write_bytes(b"")
    finally:
        os.umask(old_umask)
    directory = MOUNT / "projects"
    assert directory.stat().st_mode & 0o7777 == 0o2750
    assert directory.stat().st_uid == os.getuid()
    assert directory.stat().st_gid == os.getgid()
    assert (MOUNT / "mode-file").stat().st_mode & 0o777 == 0o640
    assert directory.stat().st_nlink == 3
    expect_error(lambda: directory.mkdir(), {errno.EEXIST})
    expect_error(lambda: (MOUNT / "missing" / "child").mkdir(), {errno.ENOENT})
    expect_error(lambda: (MOUNT / "rollback").mkdir(), {errno.EIO})
    assert not (MOUNT / "rollback").exists()

    file = directory / "data"
    original = bytes(range(256)) * 600
    file.write_bytes(original)
    assert file.read_bytes() == original
    subprocess.run(["sh", "-c", 'printf shorter > "$1"', "sh", file], check=True)
    assert file.read_bytes() == b"shorter"
    fd = os.open(file, os.O_RDWR)
    try:
        os.pwrite(fd, b"CROSS", 65534)
        assert os.pread(fd, 5, 65534) == b"CROSS"
        assert os.pread(fd, 20, 1000) == bytes(20)
        os.ftruncate(fd, 65536)
        os.ftruncate(fd, 65544)
        assert os.pread(fd, 10, 65534) == b"CR" + bytes(8)
        ns = (1_234_567_890_123_456_789, -500_000_000)
        os.utime(fd, ns=ns)
        stat = os.fstat(fd)
        assert (stat.st_atime_ns, stat.st_mtime_ns) == ns
    finally:
        os.close(fd)
    append = os.open(file, os.O_WRONLY | os.O_APPEND)
    try:
        os.pwrite(append, b"APPEND", 0)
    finally:
        os.close(append)
    assert file.read_bytes()[-6:] == b"APPEND"
    assert file.read_bytes()[:7] == b"shorter"

    # Flag changes must affect an existing handle, not just newly opened files.
    flags_file = MOUNT / "flags"
    flags_file.write_bytes(b"abc")
    fd = os.open(flags_file, os.O_RDWR | os.O_APPEND)
    try:
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_APPEND)
        os.pwrite(fd, b"X", 0)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_APPEND)
        os.pwrite(fd, b"Y", 0)
    finally:
        os.close(fd)
    assert flags_file.read_bytes() == b"XbcY"
    mapped = MOUNT / "mapped"
    mapped.write_bytes(bytes(4096))
    fd = os.open(mapped, os.O_RDWR | os.O_APPEND)
    try:
        with mmap.mmap(fd, 4096) as view:
            view[0:4] = b"MMAP"
            view.flush()
    finally:
        os.close(fd)
    assert mapped.stat().st_size == 4096
    assert mapped.read_bytes()[:4] == b"MMAP"
    (MOUNT / "priv-write").write_bytes(b"changed")
    assert (MOUNT / "priv-write").stat().st_mode & 0o6000 == 0
    os.truncate(MOUNT / "priv-truncate", 3)
    assert (MOUNT / "priv-truncate").stat().st_mode & 0o6000 == 0

    rollback = MOUNT / "fail-resize"
    rollback.write_bytes(b"original-data")
    fd = os.open(rollback, os.O_RDWR)
    try:
        before = os.fstat(fd)
        expect_error(lambda: os.ftruncate(fd, 3), {errno.EIO})
        after = os.fstat(fd)
        assert after.st_size == before.st_size
        assert after.st_mtime_ns == before.st_mtime_ns
        assert os.pread(fd, 13, 0) == b"original-data"
    finally:
        os.close(fd)

    appended = MOUNT / "parallel-append"
    appended.write_bytes(b"")

    def append_lines(label):
        fd = os.open(appended, os.O_WRONLY | os.O_APPEND)
        try:
            for _ in range(25):
                assert os.write(fd, label * 32 + b"\n") == 33
        finally:
            os.close(fd)

    with ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(append_lines, [b"A", b"B"]))
    lines = appended.read_bytes().splitlines()
    assert len(lines) == 50
    assert lines.count(b"A" * 32) == lines.count(b"B" * 32) == 25

    # Over 32 KiB of entries exercises multiple libc/kernel readdir buffers.
    names = [f"entry-{i:04d}-" + "x" * 80 for i in range(700)]
    listing = MOUNT / "listing"
    listing.mkdir()
    for name in names:
        (listing / name).touch()
    iterator = os.scandir(listing)  # opendir establishes the immutable snapshot.
    try:
        (listing / "created-after-open").touch()
        old_names = {entry.name for entry in iterator}
    finally:
        iterator.close()
    assert old_names == set(names)
    assert set(os.listdir(listing)) == set(names) | {"created-after-open"}
    byte_name = os.fsencode(MOUNT) + b"/nonutf8-\xff"
    fd = os.open(byte_name, os.O_CREAT | os.O_WRONLY, 0o600)
    os.close(fd)
    assert b"nonutf8-\xff" in os.listdir(os.fsencode(MOUNT))
    expect_error(lambda: os.chmod(file, 0o600), {errno.ENOSYS, errno.EOPNOTSUPP})
    expect_error(lambda: os.link(file, MOUNT / "hardlink"), {errno.ENOSYS, errno.EOPNOTSUPP, errno.EPERM})
    persisted = file.read_bytes()
    stop()

    with sqlite3.connect(DB) as db:
        assert db.execute("PRAGMA integrity_check").fetchone() == ("ok",)
        assert not db.execute("PRAGMA foreign_key_check").fetchall()
        assert db.execute("SELECT count(*) FROM inodes i WHERE i.inode_id<>1 AND NOT EXISTS(SELECT 1 FROM dirents d WHERE d.target_inode=i.inode_id)").fetchone() == (0,)
        assert db.execute("SELECT count(*) FROM inodes i WHERE (mode & 61440)=32768 AND nlink<>(SELECT count(*) FROM dirents d WHERE d.target_inode=i.inode_id)").fetchone() == (0,)
    start(2)
    assert file.read_bytes() == persisted
    assert set(os.listdir(listing)) == set(names) | {"created-after-open"}
    stop(interrupt=True)
    logs = (RUN / "mount-1.log").read_bytes()
    # The kernel may retain lookup references until unmount and omit final forgets.
    # Forget accounting is covered by the in-memory runtime tests, not log timing.
    for callback in ("lookup", "getattr", "setattr", "open", "create", "mkdir", "read", "write", "release", "opendir", "readdir", "releasedir"):
        assert f"[fuse] {callback} ".encode() in logs, callback
    assert b"underflow" not in logs
    print("PASS: existing operations, snapshots, rollback, persistence and Ctrl+C teardown", flush=True)
finally:
    if process is not None:
        stop()

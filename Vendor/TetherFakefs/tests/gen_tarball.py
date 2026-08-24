#!/usr/bin/env python3
"""
gen_tarball.py — regenerate tests/data/mini_rootfs.tar.gz for Tether fakefs.

The tarball is committed to the repo so tests run fully offline; this
script only exists to reproduce it deterministically. MIT licensed.

Layout:
  bin/                      directory
  bin/hello.txt             known bytes (T2)
  bin/tool                  regular file
  bin/tool-link             HARDLINK -> bin/tool
  etc/os-release            small text file
  lib/libtest.so.1          regular file
  lib/libtest.so            SYMLINK -> libtest.so.1        (relative)
  usr/bin/hello-abs         SYMLINK -> /bin/hello.txt      (absolute, T3)
  usr/bin/loop-a            SYMLINK -> loop-b   (cycle, for ELOOP test)
  usr/bin/loop-b            SYMLINK -> loop-a
  dev/null                  char device 1,3
  dev/sda                   block device 8,0
  data/f0000.txt..f0999.txt 1000 files, content "payload <i> for tether fakefs\n" (T4)
"""
import io
import os
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "data", "mini_rootfs.tar.gz")

HELLO = b"Hello from Tether fakefs! \xf0\x9f\x94\x97 binary-safe bytes: \x00\x01\x02\xff\n"
TOOL = b"#!/bin/sh\necho tether tool\n" * 8


def ti(name, **kw):
    t = tarfile.TarInfo(name)
    t.mtime = 1700000000
    t.uid = kw.pop("uid", 0)
    t.gid = kw.pop("gid", 0)
    t.mode = kw.pop("mode", 0o644)
    for k, v in kw.items():
        setattr(t, k, v)
    return t


def add_file(tar, name, data, mode=0o644):
    t = ti(name, mode=mode, size=len(data))
    tar.addfile(t, io.BytesIO(data))


def add_dir(tar, name, mode=0o755):
    tar.addfile(ti(name, mode=mode, type=tarfile.DIRTYPE))


def add_symlink(tar, name, target):
    tar.addfile(ti(name, mode=0o777, type=tarfile.SYMTYPE, linkname=target))


def add_hardlink(tar, name, target):
    tar.addfile(ti(name, mode=0o755, type=tarfile.LNKTYPE, linkname=target))


def add_dev(tar, name, kind, major, minor, mode):
    t = ti(name, mode=mode, type=kind)
    t.devmajor, t.devminor = major, minor
    tar.addfile(t)


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    # mtime=0 in GzipFile => deterministic output
    with open(OUT, "wb") as raw:
        import gzip
        gz = gzip.GzipFile(fileobj=raw, mode="wb", mtime=0)
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as tar:
            for d in ("bin", "etc", "lib", "usr", "usr/bin", "dev", "data"):
                add_dir(tar, d)
            add_file(tar, "bin/hello.txt", HELLO)
            add_file(tar, "bin/tool", TOOL, mode=0o755)
            add_hardlink(tar, "bin/tool-link", "bin/tool")
            add_file(tar, "etc/os-release",
                     b'NAME="Tether Mini"\nID=tether-mini\nVERSION_ID=1.0\n')
            add_file(tar, "lib/libtest.so.1", b"\x7fELF-not-really\n")
            add_symlink(tar, "lib/libtest.so", "libtest.so.1")
            add_symlink(tar, "usr/bin/hello-abs", "/bin/hello.txt")
            add_symlink(tar, "usr/bin/loop-a", "loop-b")
            add_symlink(tar, "usr/bin/loop-b", "loop-a")
            add_dev(tar, "dev/null", tarfile.CHRTYPE, 1, 3, 0o666)
            add_dev(tar, "dev/sda", tarfile.BLKTYPE, 8, 0, 0o660)
            for i in range(1000):
                add_file(tar, f"data/f{i:04d}.txt",
                         f"payload {i} for tether fakefs\n".encode())
        gz.close()
    size = os.path.getsize(OUT)
    print(f"wrote {OUT} ({size} bytes)")
    assert size < 500 * 1024, "tarball must stay under 500KB"


if __name__ == "__main__":
    main()

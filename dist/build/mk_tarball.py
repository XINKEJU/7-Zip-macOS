#!/usr/bin/env python3
"""mk_tarball.py — write a byte-reproducible .tar.gz of a staged tree.

Why this exists
---------------
The Homebrew formula pins the sha256 of the distribution tarball, and
dist/homebrew/verify_formula.sh asserts that the pinned value equals the hash
of the tarball actually on disk. Producing the archive with /usr/bin/tar makes
that assertion fail after *every* rebuild, for two independent reasons:

  1. tar stores each entry's mtime, and `install` sets mtime to "now";
  2. tar emits entries in readdir order, which is not stable across
     filesystems or even across runs on the same filesystem.

macOS ships bsdtar 3.5.3, which supports neither GNU tar's --sort=name nor its
--mtime, so the usual `tar --sort=name --mtime=...` recipe is unavailable. This
script replaces the archive step with an explicitly deterministic one:

  * entries are sorted by name, compared as raw bytes under the C locale;
  * uid/gid are pinned to 0 and uname/gname are emptied;
  * every mtime is pinned to SOURCE_DATE_EPOCH (default 2025-01-01T00:00:00Z);
  * modes are normalised to 0755 for directories and executables, 0644 for
    everything else, so a stray umask cannot change the output;
  * the gzip stream carries mtime 0 and no original filename.

The result depends only on the set of file names and their contents, which is
what makes the committed checksum meaningful rather than a value that has to be
patched into the formula on every build.

Usage:  mk_tarball.py <pack-dir> <root-name> <output.tar.gz>
"""

import gzip
import io
import os
import sys
import tarfile

# 2025-01-01T00:00:00Z. Arbitrary but fixed; the point is that it never
# changes. SOURCE_DATE_EPOCH overrides it for distributions that pin their own.
DEFAULT_MTIME = 1735689600


def collect_entries(root_path):
    """Return every path under root_path, sorted by name as raw bytes.

    os.walk yields names in readdir order, which is exactly what we must not
    trust. Sorting the concatenated list (with a bytes key, so the order does
    not depend on the locale) gives a stable sequence. Directories sort before
    their own contents because the parent prefix is a strict prefix of every
    child path.
    """
    found = []
    for dirpath, dirnames, filenames in os.walk(root_path):
        for name in dirnames + filenames:
            found.append(os.path.join(dirpath, name))
    found.sort(key=lambda p: os.fsencode(os.path.relpath(p, os.path.dirname(root_path))))
    return found


def normalise(tarinfo, mtime):
    """Pin everything about an entry that is not its name or its contents."""
    tarinfo.uid = 0
    tarinfo.gid = 0
    tarinfo.uname = ""
    tarinfo.gname = ""
    tarinfo.mtime = mtime

    # pax/GNU extended headers would otherwise capture an atime/ctime pair.
    tarinfo.pax_headers = {}

    if tarinfo.isdir():
        tarinfo.mode = 0o755
    elif tarinfo.issym():
        # A symlink's mode is meaningless on the extracting side; leave the
        # conventional 0777 that tar itself records.
        tarinfo.mode = 0o777
    else:
        tarinfo.mode = 0o755 if (tarinfo.mode & 0o111) else 0o644
    return tarinfo


def main(argv):
    if len(argv) != 4:
        sys.stderr.write(__doc__.split("Usage:")[1].strip() + "\n")
        return 2

    pack_dir, root_name, out_path = argv[1], argv[2], argv[3]
    root_path = os.path.join(pack_dir, root_name)
    if not os.path.isdir(root_path):
        sys.stderr.write("mk_tarball: 不是目录: %s\n" % root_path)
        return 1

    try:
        mtime = int(os.environ.get("SOURCE_DATE_EPOCH", DEFAULT_MTIME))
    except ValueError:
        sys.stderr.write("mk_tarball: SOURCE_DATE_EPOCH 不是整数\n")
        return 1

    out_dir = os.path.dirname(os.path.abspath(out_path))
    if not os.path.isdir(out_dir):
        sys.stderr.write("mk_tarball: 输出目录不存在: %s\n" % out_dir)
        return 1

    entries = collect_entries(root_path)

    # The root entry must come first so that an extractor creates the tree
    # before its members; tar convention puts it at offset 0.
    root_ti = tarfile.TarInfo(root_name)
    root_ti.type = tarfile.DIRTYPE
    root_ti.mode = 0o755
    root_ti.uid = root_ti.gid = 0
    root_ti.uname = root_ti.gname = ""
    root_ti.mtime = mtime

    # gzip is given mtime=0 and an empty filename: writing straight into a
    # GzipFile (rather than using tarfile's "w:gz", which shells out to the
    # gzip binary) keeps the header free of build-machine state.
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tar:
            tar.addfile(root_ti)
            for path in entries:
                arcname = os.path.relpath(path, os.path.dirname(root_path))
                ti = tar.gettarinfo(path, arcname=arcname)
                normalise(ti, mtime)
                if ti.isreg():
                    with open(path, "rb") as fh:
                        tar.addfile(ti, fh)
                elif ti.issym():
                    ti.linkname = os.readlink(path)
                    tar.addfile(ti, None)
                else:
                    tar.addfile(ti, None)

    # Write via a temporary file plus rename: a partially written archive must
    # never be left where the checksum step could pick it up.
    tmp_path = out_path + ".tmp"
    with open(tmp_path, "wb") as fh:
        fh.write(buf.getvalue())
    os.replace(tmp_path, out_path)

    sys.stdout.write("   可复现归档: %s (%d 条目, %d 字节)\n"
                     % (out_path, len(entries) + 1, len(buf.getvalue())))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

"""Stand-in for the C and C++ compilers while the gates build a package.

The gate puts a wrapper for each GCC driver name first on PATH. The wrapper runs
this file with the real driver and the gate's socket, then the driver's own
arguments. For every call that compiles a source, the record keeps the
preprocessor's view of it (-E -dD -C), taken with the same arguments the
compile gets, and the jobs the driver runs (-###). For every call that links,
it keeps the files the linker read, with a digest of each one the build could
have written. The record goes to the gate over the socket once the call has
finished, so the build can add a record but never change one. A compile that
this file never saw shows up in the gate as an object, or an ELF, it cannot
attribute.
"""

import hashlib
import json
import os
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import tempfile

REAL, SOCKET, ARGV = (sys.argv[1], sys.argv[2], sys.argv[3:]) if len(sys.argv) > 2 else (None, None, [])
DROPPED_WITH_VALUE = {"-o", "-MF", "-MT", "-MQ"}
DROPPED = {"-MD", "-MMD", "-MP", "-M", "-MM", "-MG"}
ARCHIVE = b"!<arch>\n"
# defining one of these in the package's own code turns a failed stack or fortify check into a call that returns
GUARDS = {"__stack_chk_fail", "__stack_chk_fail_local", "__chk_fail", "__fortify_fail"}


def fail(message):
    sys.stderr.write(f"gate compiler shim: {message}\n")
    sys.exit(1)


def planned_jobs():
    plan = subprocess.run([REAL, "-###", *ARGV], capture_output=True, text=True, check=False)
    if plan.returncode:
        return None
    return [shlex.split(line) for line in plan.stderr.splitlines() if line.startswith(" ")]


def preprocessing_arguments():
    kept, skip = [], False
    for arg in ARGV:
        if skip:
            skip = False
        elif arg in DROPPED_WITH_VALUE:
            skip = True
        elif arg not in DROPPED and not (arg[:3] in ("-MF", "-MT", "-MQ") or (arg.startswith("-o") and len(arg) > 2)):
            kept.append(arg)
    return kept


def value_of(job, option):
    return job[job.index(option) + 1] if option in job[:-1] else None


def digest(data):
    return hashlib.sha256(data).hexdigest()


def kind_of(head):
    if head.startswith(b"\x7fELF") and len(head) > 17:
        return {1: "rel", 2: "exec", 3: "dyn"}.get(head[16], "elf")
    if head.startswith(ARCHIVE):
        return "archive"
    if head.startswith(b"!<thin>\n"):
        return "thin-archive"
    return "other"


def members(data):
    offset, found = len(ARCHIVE), []
    while offset + 60 <= len(data):
        header = data[offset : offset + 60]
        name, size = header[:16].decode("latin-1").strip(), int(header[48:58])
        body = data[offset + 60 : offset + 60 + size]
        if name not in ("/", "//", "/SYM64/"):
            found.append({"name": name, "sha256": digest(body), "lto": b".gnu.lto_" in body})
        offset += 60 + size + (size & 1)
    return found


def code_digest(path):
    """A digest of an ELF file's executable sections, which strip and an RPATH edit leave as they are."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF" or data[4] != 2:
        return None
    order = "<" if data[5] == 1 else ">"
    (table,) = struct.unpack_from(order + "Q", data, 0x28)
    size, count = struct.unpack_from(order + "HH", data, 0x3A)
    code = hashlib.sha256()
    for index in range(count):
        _name, kind, flags, _address, offset, length = struct.unpack_from(order + "IIQQQQ", data, table + index * size)
        if flags & 0x4 and kind != 8:
            code.update(data[offset : offset + length])
    return code.hexdigest()


def defined_guards(path):
    table = subprocess.run([shutil.which("readelf") or "/usr/bin/readelf", "-sW", path], capture_output=True, text=True, check=False).stdout
    return sorted({f[7].split("@")[0] for f in (line.split() for line in table.splitlines()) if len(f) > 7 and f[6] != "UND" and f[7].split("@")[0] in GUARDS})


def build_id(path):
    notes = subprocess.run([shutil.which("readelf") or "/usr/bin/readelf", "-nW", path], capture_output=True, text=True, check=False).stdout
    for line in notes.splitlines():
        if "Build ID:" in line:
            return line.split("Build ID:")[1].strip()
    return None


def linked_from(dependency_file):
    with open(dependency_file, encoding="utf-8", errors="surrogateescape") as f:
        words = shlex.split(f.read().replace("\\\n", " "), posix=True)
    inputs = []
    # the first word is the output, and each input comes again as an empty rule "input:"
    for word in dict.fromkeys(w for w in words[1:] if not w.endswith(":")):
        path = os.path.abspath(word)
        if not os.path.exists(path):
            inputs.append({"path": path, "missing": True})
            continue
        status = os.stat(path)
        entry = {"path": os.path.realpath(path), "uid": status.st_uid, "mode": status.st_mode}
        # files the build user can write are the ones it could have made, so only they need a digest
        if status.st_uid != 0 or status.st_mode & 0o022:
            with open(path, "rb") as f:
                data = f.read()
            entry |= {"kind": kind_of(data[:32]), "sha256": digest(data), "lto": b".gnu.lto_" in data}
            if entry["kind"] == "archive":
                entry["members"] = members(data)
        inputs.append(entry)
    return inputs


def send(record):
    data = json.dumps(record).encode("utf-8")
    try:
        with socket.socket(socket.AF_UNIX) as conn:
            conn.connect(SOCKET)
            conn.sendall(data)
    except OSError as error:
        fail(f"cannot send the record to the gate: {error}")


def main():
    jobs = planned_jobs()
    if jobs is None:
        sys.exit(subprocess.run([REAL, *ARGV], check=False).returncode)
    # cc1 with -E only preprocesses, as it does for assembly; that is not a compile the gate can judge
    compiles = [job for job in jobs if os.path.basename(job[0]) in ("cc1plus", "cc1") and "-E" not in job]
    links = [job for job in jobs if os.path.basename(job[0]) == "collect2"]
    if not links and not compiles:
        sys.exit(subprocess.run([REAL, *ARGV], check=False).returncode)
    scratch = tempfile.mkdtemp(prefix="gate-shim-")
    try:
        record = {"cwd": os.getcwd(), "compiler": REAL, "argv": ARGV, "jobs": jobs, "sources": len(compiles)}
        # several sources in one call get no preprocessed view, so an object from one of them is one the gate cannot attribute
        if len(compiles) == 1:
            preprocessed = os.path.join(scratch, "view.i")
            view = subprocess.run([REAL, *preprocessing_arguments(), "-E", "-dD", "-C", "-o", preprocessed], capture_output=True, check=False)
            if view.returncode == 0 and os.path.exists(preprocessed):
                with open(preprocessed, encoding="utf-8", errors="surrogateescape") as f:
                    record["preprocessed"] = f.read()
            elif view.returncode == 0:
                # --version and --help plan a compile and run none, and a preprocessor that wrote nothing saw no source
                compiles = []
        dependencies = os.path.join(scratch, "link.dep")
        compiled = subprocess.run([REAL, *ARGV, *([f"-Wl,--dependency-file={dependencies}"] if links else [])], capture_output=True, check=False)
        sys.stdout.buffer.write(compiled.stdout)
        sys.stderr.buffer.write(compiled.stderr)
        # the compiler's own diagnostics, so warnings count however the build treats its output
        record["status"], record["diagnostics"] = compiled.returncode, compiled.stderr.decode("utf-8", "replace")
        if compiled.returncode == 0:
            record["objects"] = {}
            for job in jobs:
                out = value_of(job, "-o") if os.path.basename(job[0]) == "as" else None
                if out and os.path.exists(out):
                    with open(out, "rb") as f:
                        data = f.read()
                    record["objects"][os.path.realpath(out)] = {"sha256": digest(data), "lto": b".gnu.lto_" in data, "defines": defined_guards(out)}
            # a call such as --version plans a link and runs none, so only a linker that wrote its dependency file linked
            if links and os.path.exists(dependencies):
                out = os.path.realpath(value_of(links[0], "-o") or "a.out")
                record["link"] = {"output": out, "build_id": build_id(out), "code": code_digest(out), "inputs": linked_from(dependencies)}
        if compiles or "link" in record:
            send(record)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    sys.exit(compiled.returncode)


if sys.argv[1:2] == ["--code-digest"]:
    print(code_digest(sys.argv[2]))
else:
    main()

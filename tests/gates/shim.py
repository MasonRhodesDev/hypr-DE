"""Stand-in for the C and C++ compilers while the gates build a package.

The gate puts a wrapper for each GCC driver name first on PATH. The wrapper runs
this file with the real driver and the record directory, then the driver's own
arguments. For every call that compiles a source, the record keeps the
preprocessor's view of it (-E -dD -C), taken with the same arguments the
compile gets, and the jobs the driver runs (-###). For every call that links,
it keeps the files the linker read, with a digest of each one the build could
have written. A compile that this file never saw shows up in the gate as an
object, or an ELF, it cannot attribute.
"""

import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile

REAL, RECORDS, ARGV = sys.argv[1], sys.argv[2], sys.argv[3:]
DROPPED_WITH_VALUE = {"-o", "-MF", "-MT", "-MQ"}
DROPPED = {"-MD", "-MMD", "-MP", "-M", "-MM", "-MG"}
ARCHIVE = b"!<arch>\n"


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
            entry |= {"kind": kind_of(data[:32]), "sha256": digest(data)}
            if entry["kind"] == "archive":
                entry["members"] = members(data)
        inputs.append(entry)
    return inputs


def main():
    jobs = planned_jobs()
    if jobs is None:
        sys.exit(subprocess.run([REAL, *ARGV], check=False).returncode)
    compiles = [job for job in jobs if os.path.basename(job[0]) in ("cc1plus", "cc1")]
    links = [job for job in jobs if os.path.basename(job[0]) == "collect2"]
    preprocess_only = any("-E" in job for job in compiles)
    if not links and (not compiles or preprocess_only):
        sys.exit(subprocess.run([REAL, *ARGV], check=False).returncode)
    fd, path = tempfile.mkstemp(dir=RECORDS, suffix=".json")
    os.close(fd)
    stem = path.removesuffix(".json")
    record = {"cwd": os.getcwd(), "compiler": REAL, "argv": ARGV, "jobs": jobs}
    if compiles:
        if len(compiles) != 1:
            fail("one source per compiler call, so that each object has one preprocessed view")
        view = subprocess.run([REAL, *preprocessing_arguments(), "-E", "-dD", "-C", "-o", stem + ".i"], capture_output=True, text=True, check=False)
        if view.returncode:
            fail(f"could not preprocess for the gate:\n{view.stderr}")
        record["preprocessed"] = stem + ".i"
    extra = [f"-Wl,--dependency-file={stem}.dep"] if links else []
    status = subprocess.run([REAL, *ARGV, *extra], check=False).returncode
    record["status"] = status
    if status == 0:
        objects = {}
        for job in jobs:
            out = value_of(job, "-o") if os.path.basename(job[0]) == "as" else None
            if out and os.path.exists(out):
                with open(out, "rb") as f:
                    data = f.read()
                objects[os.path.realpath(out)] = {"sha256": digest(data), "lto": b".gnu.lto_" in data}
        record["objects"] = objects
        if links:
            out = os.path.realpath(value_of(links[0], "-o") or "a.out")
            record["link"] = {"output": out, "build_id": build_id(out), "inputs": linked_from(stem + ".dep")}
    with open(path, "w", encoding="utf-8") as f:
        json.dump(record, f)
    sys.exit(status)


main()

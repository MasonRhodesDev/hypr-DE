"""A pull request may shrink what the gates allow, never grow it, unless it says why.

    python3 -I tests/gates/ratchet.py <base commit>

Compares the base commit's baseline, file classes and linter configurations
with the working tree. These fail:

* a baseline row that is new, or allows more than the base's row did;
* a classified.tsv row whose class changed, unless it went from a class no gate
  reads to one a gate reads, and a new row with a class no gate reads;
* any change to a linter configuration, the hardening flags or the pinned tools.

They pass when a commit since the base, or the text in GATE_CHANGE_REASONS (CI
passes the pull request body), has a line that starts with "Gate-change:" and
gives a reason. The lines that would fail are printed either way, so the review
sees each one beside its reason.
"""

import os
import re
import subprocess
import sys

BASELINE = "tests/gates/baseline.tsv"
MANIFEST = "tests/gates/classified.tsv"
CONFIGS = (".shellcheckrc", "ruff.toml", ".luacheckrc", "plugins/.clang-tidy", "plugins/cmake/Safety.cmake", "tests/gates/requirements.txt")
UNREAD = {"data", "blob", "make", "cpp-test", "cpp-fixture"}
REASON = re.compile(r"^Gate-change:[ \t]*\S.*$", re.MULTILINE)


def at_base(base, path):
    shown = subprocess.run(["git", "show", f"{base}:{path}"], capture_output=True, text=True, check=False)
    return shown.stdout if shown.returncode == 0 else None


def in_tree(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return None


def rows(text, width):
    """Tab-separated rows of the given width, keyed by their first field or fields."""
    fields = (line.split("\t") for line in (text or "").splitlines())
    return {tuple(f[: width - 2]) if width == 6 else f[0]: f for f in fields if len(f) >= width}


def loosened(base):
    found = []
    before, after = rows(at_base(base, BASELINE), 6), rows(in_tree(BASELINE), 6)
    for key, row in sorted(after.items()):
        allowed = int(before[key][4]) if key in before else 0
        if int(row[4]) > allowed:
            found.append(f"baseline {' '.join(key[:3])}: {allowed} -> {row[4]}: {row[5]}")
    before, after = rows(at_base(base, MANIFEST), 2), rows(in_tree(MANIFEST), 2)
    for path, row in sorted(after.items()):
        old = before[path][1] if path in before else None
        if old is None and row[1] in UNREAD:
            found.append(f"classified {path}: new as {row[1]}, which no gate reads")
        elif old is not None and old != row[1] and not (old in UNREAD and row[1] not in UNREAD):
            found.append(f"classified {path}: {old} -> {row[1]}")
    for path in CONFIGS:
        if at_base(base, path) != in_tree(path):
            found.append(f"config {path}: changed")
    return found


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    base = sys.argv[1]
    if subprocess.run(["git", "cat-file", "-e", f"{base}^{{commit}}"], capture_output=True, check=False).returncode:
        sys.exit(f"ratchet: {base} is not a commit here; fetch the base branch's history")
    log = subprocess.run(["git", "log", "--format=%B", f"{base}..HEAD"], capture_output=True, text=True, check=False).stdout
    reasons = REASON.findall(os.environ.get("GATE_CHANGE_REASONS", "") + "\n" + log)
    found = loosened(base)
    for line in found:
        print(f"{'note' if reasons else 'FAIL'} ratchet: {line}")
    for reason in reasons if found else []:
        print(f"     {reason.strip()}")
    if found and not reasons:
        print("Each line above loosens a gate. Fix it, or add a line that starts with Gate-change: and says why, to a commit or the pull request body.")
        sys.exit(1)
    if not found:
        print("ok   ratchet: nothing the gates allow has grown")


main()

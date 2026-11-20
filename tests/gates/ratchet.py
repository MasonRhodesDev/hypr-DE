"""A pull request may shrink what the gates allow, never grow it, unless it says why.

    python3 -I ratchet.py <base commit>

CI runs the base commit's copy of this file, so a pull request cannot loosen
the ratchet itself. It compares the base commit's baseline, file classes and
configurations with the files git tracks in the working tree. These fail:

* a baseline row that is new, or allows more than the base's row did, unless
  it is a row whose line was edited or rewrapped: the base row's count fell by
  as much, and its text became the new row's text (see successors);
* a classified.tsv row whose class changed, unless it went from a class no gate
  reads to one a gate reads, and a new row with a class no gate reads, except
  a C or C++ test source (cpp-test), which ships nothing;
* any change to a file under CONFIGS: the linter configurations, the hardening
  flags, the gates themselves with their pinned tools, and the workflows and
  CODEOWNERS that run and guard them.

They pass when a commit since the base, or the text in GATE_CHANGE_REASONS (CI
passes the pull request body), has a line that starts with "Gate-change:" and
gives a reason. The lines that would fail are printed either way, so the review
sees each one beside its reason, and on GitHub they are also warnings on the
run and lines in its summary.
"""

import collections
import difflib
import functools
import os
import re
import subprocess
import sys

BASELINE = "tests/gates/baseline.tsv"
MANIFEST = "tests/gates/classified.tsv"
# a path that ends in / covers every file under it
CONFIGS = (".shellcheckrc", "ruff.toml", ".luacheckrc", "plugins/.clang-tidy", "plugins/cmake/", "tests/gates/", ".github/")
UNREAD = {"data", "blob", "make", "cpp-test", "cpp-fixture"}
REASON = re.compile(r"^Gate-change:[ \t]*\S.*$", re.MULTILINE)
# the same threshold as gate.py's SAME_LINE, so a row the gate lets follow its line passes here too
SAME_LINE = 0.6


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=False)


def at_base(base, path):
    shown = git("show", f"{base}:{path}")
    return shown.stdout if shown.returncode == 0 else None


def in_tree(path):
    try:
        with open(path, encoding="utf-8", errors="surrogateescape") as f:
            return f.read()
    except FileNotFoundError:
        return None


def config_files(base):
    prefixes = [p for p in CONFIGS if p.endswith("/")]
    listed = set(git("ls-tree", "-r", "--name-only", base, "--", *prefixes).stdout.splitlines())
    listed |= set(git("ls-files", "--", *prefixes).stdout.splitlines())
    return sorted({p for p in listed if p not in (BASELINE, MANIFEST)} | {p for p in CONFIGS if not p.endswith("/")})


def rows(text, width):
    """Tab-separated rows of the given width, keyed by their first field or fields."""
    fields = (line.split("\t") for line in (text or "").splitlines())
    return {tuple(f[: width - 2]) if width == 6 else f[0]: f for f in fields if len(f) >= width}


def normalised(text):
    return " ".join(text.replace("\\\n", "").split())


@functools.cache
def spans(lines):
    """Each run of one to four lines, as a finding's text is joined, and where in the file it runs."""
    found = collections.defaultdict(list)
    for n in range(1, 5):
        for i in range(len(lines) - n + 1):
            found[normalised("\n".join(lines[i : i + n]))].append(range(i, i + n))
    return found


def successors(text, candidates, lines):
    """The candidates an edit made of a line with this text, most alike first: those on the lines of the file most like the text
    now, so an edited line, and a statement a formatter wrapped or joined, keep their finding."""
    runs = spans(tuple(lines))
    matcher = difflib.SequenceMatcher(None, autojunk=False)
    matcher.set_seq2(text)
    best, score = (text, 1.0) if text in runs else (None, 0.0)
    for other in [] if best else sorted(runs):
        matcher.set_seq1(other)
        # the cheap upper bounds first, so a long file costs little once a close run is found
        if matcher.real_quick_ratio() > score and matcher.quick_ratio() > score and matcher.ratio() > score:
            best, score = other, matcher.ratio()
    if best is None or score < SAME_LINE:
        return []
    held = [c for c in candidates if any(set(a) & set(b) for a in runs[best] for b in runs.get(c, ()))]

    def likeness(other):
        matcher.set_seq1(other)
        return matcher.ratio()

    return sorted(held, key=lambda c: (-likeness(c), c))


def count(table, key):
    return int(table[key][4]) if key in table else 0


def grown_rows(base):
    before, after = rows(at_base(base, BASELINE), 6), rows(in_tree(BASELINE), 6)
    grown = {key: count(after, key) - count(before, key) for key in after}
    for old in sorted(key for key in before if count(before, key) > count(after, key)):
        spare = count(before, old) - count(after, old)
        new = {after[key][5]: key for key in grown if key[:3] == old[:3] and grown[key] > 0}
        text = in_tree(old[1]) if new else None
        for moved in successors(before[old][5], new, text.splitlines()) if text else []:
            shift = min(spare, grown[new[moved]])
            grown[new[moved]] -= shift
            spare -= shift
    return [f"baseline {' '.join(key[:3])}: {count(before, key)} -> {after[key][4]}: {after[key][5]}" for key, more in sorted(grown.items()) if more > 0]


def loosened(base):
    found = grown_rows(base)
    before, after = rows(at_base(base, MANIFEST), 2), rows(in_tree(MANIFEST), 2)
    for path, row in sorted(after.items()):
        old = before[path][1] if path in before else None
        if old is None and row[1] in UNREAD - {"cpp-test"}:
            found.append(f"classified {path}: new as {row[1]}, which no gate reads")
        elif old is not None and old != row[1] and not (old in UNREAD and row[1] not in UNREAD):
            found.append(f"classified {path}: {old} -> {row[1]}")
    for path in config_files(base):
        if at_base(base, path) != in_tree(path):
            found.append(f"config {path}: changed")
    return found


def annotate(found, reasons):
    """On GitHub, each loosening is a warning on the run and a line in its summary, not only a line in the log."""
    for line in found:
        print(f"::{'warning' if reasons else 'error'} title=Gate loosened::{line.replace('%', '%25')}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write("### What this pull request loosens in the gates\n\n")
            f.writelines(f"* `{line}`\n" for line in found)
            if reasons:
                f.write("\nReasons given:\n\n" + "".join(f"* {reason.strip()}\n" for reason in reasons))
            else:
                f.write("\nNo Gate-change: reason was given, so this fails.\n")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    base = sys.argv[1]
    if git("cat-file", "-e", f"{base}^{{commit}}").returncode:
        sys.exit(f"ratchet: {base} is not a commit here; fetch the base branch's history")
    log = git("log", "--format=%B", f"{base}..HEAD").stdout
    reasons = REASON.findall(os.environ.get("GATE_CHANGE_REASONS", "") + "\n" + log)
    found = loosened(base)
    for line in found:
        print(f"{'note' if reasons else 'FAIL'} ratchet: {line}")
    for reason in reasons if found else []:
        print(f"     {reason.strip()}")
    if found and os.environ.get("GITHUB_ACTIONS"):
        annotate(found, reasons)
    if found and not reasons:
        print("Each line above loosens a gate. Fix it, or add a line that starts with Gate-change: and says why, to a commit or the pull request body.")
        sys.exit(1)
    if not found:
        print("ok   ratchet: nothing the gates allow has grown")


main()

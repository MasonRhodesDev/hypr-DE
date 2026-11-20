import argparse
import atexit
import collections
import concurrent.futures
import difflib
import functools
import hashlib
import json
import math
import os
import platform
import re
import shlex
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASELINE = "tests/gates/baseline.tsv"
MANIFEST = "tests/gates/classified.tsv"
REQUIREMENTS = "tests/gates/requirements.txt"
SHIM = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shim.py")
SHELLCHECK_RC = ".shellcheckrc"
RUFF_CONFIG = "ruff.toml"
LUACHECK_RC = ".luacheckrc"
LUACHECK = "1.2.0"
TIDY_CONFIG = "plugins/.clang-tidy"
FIXTURE = "tests/gates/cpp-fixture"
FIXTURE_PKGBUILD = f"{FIXTURE}/PKGBUILD"

# a finding from these gates, or under these rules, is never recorded in the baseline, so it always fails
UNBASELINED_GATES = {"cpp-selftest", "classify"}
UNBASELINED_RULES = {
    "build-failed", "tidy-failed", "not-built", "unattributed", "unlintable-shell", "pkgbuild-source",
    "cannot-run", "forged-record", "malformed-record", "unshimmed", "not-judged", "untrusted-tool", "driver-override",
}
# a gate that cannot see the code it judges says so once, and stays silent about what it therefore cannot count
BLOCKING_RULES = {"build-failed", "unattributed", "cannot-run", "forged-record", "malformed-record", "unshimmed", "not-judged", "untrusted-tool", "driver-override"}
# what a file the gates cannot place by its suffix or its plugin is, so that none goes unchecked by default
CLASSES = {
    "sh": "shell script that sh runs or sources",
    "bash": "shell script that bash runs or sources",
    "python": "Python script",
    "lua": "Lua script",
    "pkgbuild": "makepkg build script; its package is built and audited",
    "spec": "RPM spec; its scriptlets are linted, its build sections may only unpack, configure, build and install, and the RPM job audits what it ships",
    "blob": "opaque data no gate can read; the row's third field says why it is in the tree",
    "make": "Makefile",
    "data": "read, never run",
    "cpp-test": "C or C++ that only a test script builds; never shipped",
    "cpp-fixture": "a known-bad build under tests/gates that the gates build to test themselves",
}
CPP_SUFFIXES = (".c", ".cc", ".cpp", ".cxx", ".c++", ".h", ".hh", ".hpp", ".hxx", ".h++", ".inc", ".inl", ".ipp", ".tpp", ".tcc", ".ixx", ".cppm")
# a suffix here tells a gate what the file is; any other suffix, or none, needs a row in the manifest
KNOWN_SUFFIXES = {
    *CPP_SUFFIXES, ".sh", ".bash", ".py", ".lua", ".install", ".spec", ".cmake",
    ".conf", ".service", ".path", ".timer", ".preset", ".hook", ".toml", ".yml", ".yaml", ".json", ".jsonc", ".ini",
    ".txt", ".md", ".tsv", ".png", ".svg", ".hbs", ".asc", ".map", ".rpmlintrc", ".1", ".7",
    ".clang-tidy", ".clang-format", ".shellcheckrc", ".luacheckrc", ".gitignore",
}
OBJECT_MAGIC = (b"\x7fELF", b"!<arch>\n", b"!<thin>\n")
# compressed or encrypted bytes, or text that encodes bytes, which a reviewer cannot read and a script can turn into a program
OPAQUE_ENTROPY, OPAQUE_MIN = 7.0, 1024
ENCODED = re.compile(
    r"(?:^[ \t]*[A-Za-z0-9+/]{40,}={0,2}[ \t]*\r?\n){8,}|[A-Za-z0-9+/=]{320,}"
    r"|(?:0x[0-9a-fA-F]{1,2}\s*,\s*){128,}|(?:\\x[0-9a-fA-F]{2}){64,}|(?:\\[0-7]{1,3}){64,}",
    re.MULTILINE,
)
# the only lines a spec's prep, conf, build and install sections may hold: unpack, configure the source directory with
# no options of its own, build and install. Fedora's flags then harden the build, and the RPM job audits what it ships.
SPEC_BUILD_LINE = re.compile(r"%autosetup(?: -n \S+)?(?: -p\d+)?|%cmake -S [\w./-]+|%cmake_build|%cmake_install|\s*(?:#.*)?")
# a spec that asks for a compiler or a C or C++ build system, or names one in its build sections, macros included, compiles;
# a clean Fedora build root has no compiler a spec did not ask for
SPEC_COMPILES = re.compile(r"(?<![\w.+-])(?:gcc|gcc-c\+\+|g\+\+|c\+\+|cc|cxx|clang(?:\+\+)?|cmake\w*|meson\w*|ninja(?:-build)?|make\w*|ld|as)(?![\w.+-])")
SPEC_FLAGS_MACRO = re.compile(r"^%(?:global|define|undefine)\s+(\S*(?:flags|hardened|fortify|lto|annobin|cmake|_build_type)\S*)", re.MULTILINE)
# how alike, from 0 to 1, a baselined line and the line an edit made of it are; a fixed line and a new one are rarely this close
SAME_LINE = 0.6

# shellcheck reads these; any other shell in a shebang cannot be linted, so it fails
LINTED_SHELLS = {"sh", "bash", "dash", "ksh", "ash", "mksh", "busybox"}
OTHER_SHELLS = {"zsh", "fish", "csh", "tcsh", "yash", "posh", "rc", "es", "elvish", "nu", "xonsh", "oksh", "pdksh"}
SHELL_SUFFIXES = (".sh", ".bash")
# makepkg assigns srcdir and pkgdir and reads pkgname and the rest itself, so shellcheck sees neither side
PKGBUILD_EXCLUDES = "SC2034,SC2154"
SHELLCHECK_DIRECTIVE = re.compile(r"#\s*shellcheck\s+([^#\n]*\bdisable=[^#\n]*)(?:#.*)?")
SPEC_SECTION = re.compile(
    r"^%(package|description|prep|build|install|check|clean|files|changelog|generate_buildrequires|conf|patchlist|sourcelist"
    r"|pre|post|preun|postun|pretrans|posttrans|preuntrans|postuntrans|verify|(?:file|transfile)?trigger\w*)\b(.*)$"
)
SPEC_SCRIPTLET = re.compile(r"^(pre|post|preun|postun|pretrans|posttrans|preuntrans|postuntrans|verify|(?:file|transfile)?trigger\w*)$")
SPEC_SHELLS = {"/bin/sh", "/usr/bin/sh", "/bin/bash", "/usr/bin/bash"}
# written in two parts so that this line is not a suppression by its own rule
PYTHON_SUPPRESSION = re.compile(r"#.*\b(?:no" + r"qa|ruff\s*:)", re.IGNORECASE)
LUA_SUPPRESSION = re.compile(r"--.*\bluacheck\s*:")

COMPILER_WARNING = re.compile(r"^(.+?):(\d+):(\d+): warning: (.*?)(?: \[(-W[^\]]+)\])?$")
TIDY_LINE = re.compile(r"^(.+?):(\d+):(\d+): (?:warning|error): (.*) \[([\w.,-]+)\]$")
LUACHECK_LINE = re.compile(r"^(.+?):(\d+):(\d+): \((\w+)\) (.*)$")

# the preprocessor's view: linemarkers name the file each line came from, and -dD keeps every #define and #undef in place
LINEMARKER = re.compile(r'^# (\d+) "((?:[^"\\]|\\.)*)"((?: \d)*)$')
MACRO = re.compile(r"^#(define|undef) ([A-Za-z_]\w*)(?:\(.*?\))?(?: (.*))?$")
LEXEME = re.compile(
    r"""(?P<comment>//[^\n]*|/\*.*?\*/)"""
    r"""|(?<!\w)(?:u8|u|U|L)?R"(?P<delim>[^()\\\s"]{0,16})\(.*?\)(?P=delim)\""""
    r"""|(?<!\w)(?:u8|u|U|L)?"(?:\\.|[^"\\\n])*\""""
    r"""|(?<!\w)(?:u8|u|U|L)?'(?:\\.|[^'\\\n]){1,8}'""",
    re.DOTALL,
)
PRAGMA = re.compile(r"^\s*#\s*pragma\s+(GCC|clang)\s+(\w+)\s*(\w*)")
WEAKENING_PRAGMAS = {"optimize", "push_options", "target"}
ATTRIBUTE = re.compile(r"\b__attribute(?:__)?\s*\(\s*\(|\[\[")
WEAKENING_ATTRIBUTE = re.compile(r"\b(?:__)?(optimize|target|no_stack_protector|no_sanitize\w*|no_address_safety_analysis|nocf_check)(?:__)?\b")
NOLINT = re.compile(r"\bNOLINT(?:NEXTLINE|BEGIN|END)?\b")
REQUIRED_WARNINGS = ["all", "extra", "conversion", "shadow"]
# what Safety.cmake sets; glibc turns it into __USE_FORTIFY_LEVEL only when optimising
FORTIFY_LEVEL = 3
# glibc sends these to their __*_chk form whenever fortify is on, so a plain import is code fortify never saw
ALWAYS_FORTIFIED = {"printf", "fprintf", "vprintf", "vfprintf", "sprintf", "vsprintf", "vsnprintf", "dprintf", "vdprintf", "syslog", "vsyslog"}
SHIMMED = ("c++", "g++", "gcc", "cc")
# the environment that tells GCC or the loader where to find programs and libraries; the wrappers drop it before the shim runs
SCRUBBED = ("COMPILER_PATH", "GCC_EXEC_PREFIX", "LIBRARY_PATH", "GCC_COMPARE_DEBUG")
# driver options that choose which compiler, assembler or linker runs, or rewrite what each is told, past what -### shows
OVERRIDE = re.compile(r"-B.*|-?-specs(?:=.*)?|-wrapper|-fplugin(?:-arg-[\w-]+)?=.*|-iplugindir=.*")
# where a scriptlet may run a program but never write: the system's library and program directories, and the loader's own lists
PROTECTED = re.compile(r"(?<![\w./$-])(?:(?:/usr(?:/local)?)?/(?:lib|lib64|bin|sbin|libexec)|/etc/ld\.so\.[\w.]+)(?![\w.-])")
COMMAND_WORD = re.compile(r"(?:^|[;&|({`!]|\b(?:then|do|else|if|elif|while|until|exec|command|env|nice|time))\s*[\"']?$")
TOOLCHAIN = ("makepkg", "cmake", "readelf", "c++", "fakeroot", "strace", "setpriv")
# the unprivileged user a root gate builds as, and the parts of a build's work directory that user owns
BUILDER = 65534
BUILDER_DIRS = ("start", "build", "out", "home")
# strace -f sees every program the build runs; a compiler, assembler or linker that no shim started is a compile the gate never saw
TOOL = re.compile(r"cc1\w*|lto1|lto-wrapper|collect2|as|ld(?:\.\w+)?|lld|mold|(?:[\w.-]+-)?(?:gcc|g\+\+|c\+\+|cc|clang(?:\+\+)?|cpp)(?:-[\d.]+)?")
EXEC = re.compile(r"^(\d+) +(?:execve(?:at)?\((.*)|<\.\.\. execve(?:at)? resumed>.*)$")
SPAWN = re.compile(r"^(\d+) +(?:(?:clone3?|v?fork)\(|<\.\.\. (?:clone3?|v?fork) resumed>).*= (\d+)$")
C_STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')

SELFTEST = [
    ("WARNING", "cpp-harden", f"{FIXTURE}/src/fixture.cpp", "-Wconversion"),
    ("SIBLING", "cpp-harden", "tests/gates/cpp-fixture-sibling/sibling.hpp", "-Wconversion"),
    ("NOWARN", "cpp-harden", FIXTURE_PKGBUILD, "warning-off:-Wno-conversion"),
    ("NOWARNINGS", "cpp-harden", FIXTURE_PKGBUILD, "warning-off:-w"),
    ("WEAKSTACK", "cpp-harden", f"{FIXTURE}/src/fixture.cpp", "stack-protector-off"),
    ("NOASSERT", "cpp-harden", f"{FIXTURE}/src/fixture.cpp", "assertions-off"),
    ("NDEBUG", "cpp-harden", f"{FIXTURE}/src/fixture.cpp", "ndebug"),
    ("NOSAFETY", "cpp-harden", f"{FIXTURE}/src/fixture.cpp", "fortify-off"),
    ("NOSAFETY", "cpp-harden", "@gate-fixture/usr/lib/gate-fixture/libgate-fixture.so", "elf-lazy-binding"),
    ("RESPONSEFILE", "cpp-harden", f"{FIXTURE}/src/fixture.cpp", "unoptimized"),
    ("WP", "cpp-harden", f"{FIXTURE}/src/fixture.cpp", "fortify-off"),
    ("UNITY", "cpp-harden", "@gate-fixture/tests/gates/cpp-fixture/build/CMakeFiles/gate-fixture.dir/Unity/unity_0_cxx.cxx", "stack-protector-off"),
    ("SYSTEM", "cpp-harden", "tests/gates/cpp-fixture-sibling/sibling.hpp", "system-header-in-tree"),
    ("LAUNCHER", "cpp-harden", f"{FIXTURE}/src/fixture.cpp", "fortify-off"),
    ("CUSTOM", "cpp-harden", f"{FIXTURE}/src/custom.cpp.txt", "unoptimized"),
    ("BYPASS", "cpp-harden", "@gate-fixture/usr/lib/gate-fixture/bypass.so", "unattributed"),
    ("RPATH", "cpp-harden", "@gate-fixture/usr/lib/gate-fixture/libgate-fixture.so", "elf-runpath"),
    ("NORELRO", "cpp-harden", "@gate-fixture/usr/lib/gate-fixture/libgate-fixture.so", "elf-no-relro"),
    ("ENVCI", "cpp-harden", f"{FIXTURE}/src/fixture.cpp", "stack-protector-off"),
    ("EVASION", "cpp-harden", f"{FIXTURE}/src/fixture.cpp", "fortify-off"),
    ("EVASION", "cpp-harden", f"{FIXTURE}/src/fixture.cpp", "assertions-off"),
    ("EVASION", "cpp-harden", "tests/gates/cpp-fixture-sibling/evasion.hpp", "source-weakens: attribute optimize"),
    ("EVASION", "cpp-harden", "tests/gates/cpp-fixture-sibling/evasion.hpp", 'suppression: #pragma GCC diagnostic ignored "-Wconversion"'),
    ("BUILDID", "cpp-harden", "@gate-fixture/usr/lib/gate-fixture/libgate-fixture.so", "unattributed"),
    ("ASM", "cpp-harden", "@gate-fixture/usr/lib/gate-fixture/asm.so", "unattributed"),
    ("LTO", "cpp-harden", "@gate-fixture/usr/lib/gate-fixture/libgate-fixture.so", "unattributed"),
    ("STATIC", "cpp-harden", "@gate-fixture/tests/gates/cpp-fixture/build/generated/member.cpp", "stack-protector-off"),
    ("PRAGMASYSTEM", "cpp-harden", "tests/gates/cpp-fixture-sibling/pragma-system.hpp", "system-header-in-tree"),
    ("UNFORTIFIED", "cpp-harden", "@gate-fixture/usr/lib/gate-fixture/libgate-fixture.so", "elf-unfortified:sprintf"),
    ("GENERATED", "cpp-harden", "@gate-fixture/tests/gates/cpp-fixture/build/generated/generated.hpp", 'suppression: #pragma GCC diagnostic ignored "-Wconversion"'),
    ("GENSOURCE", "cpp-harden", "@gate-fixture/tests/gates/cpp-fixture/build/generated/gensource.cpp", "stack-protector-off"),
    ("GENSOURCE", "cpp-tidy", "@gate-fixture/tests/gates/cpp-fixture/build/generated/gensource.cpp", "cppcoreguidelines-pro-type-reinterpret-cast"),
    ("TEMPLATE", "cpp-tidy", "@gate-fixture/tests/gates/cpp-fixture/build/generated/template.hpp", "cppcoreguidelines-pro-type-reinterpret-cast"),
    ("TIDY", "cpp-tidy", f"{FIXTURE}/src/fixture.cpp", "cppcoreguidelines-pro-type-reinterpret-cast"),
    ("SIBLING", "cpp-tidy", "tests/gates/cpp-fixture-sibling/sibling.hpp", "bugprone-narrowing-conversions"),
    ("OVERFLOW", "cpp-sanitize", FIXTURE, "tests-failed"),
    ("UNDEFINED", "cpp-sanitize", FIXTURE, "tests-failed"),
    ("NOSANITIZE", "cpp-sanitize", f"{FIXTURE}/src/fixture.cpp", "sanitizer-off"),
    ("BYPASS", "cpp-harden", FIXTURE_PKGBUILD, "unshimmed"),
    ("MANUALENDBR", "cpp-harden", f"{FIXTURE}/src/fixture.cpp", "manual-endbr"),
    ("NOCF", "cpp-harden", f"{FIXTURE}/src/fixture.cpp", "source-weakens: attribute nocf_check"),
    ("GUARD", "cpp-harden", f"{FIXTURE}/src/fixture.cpp", "defines-guard:__stack_chk_fail"),
    ("PRAGMAOPEN", "cpp-harden", f"{FIXTURE}/src/fixture.cpp", "pragma-unbalanced"),
    ("SETID", "cpp-harden", "@gate-fixture/usr/lib/gate-fixture/libgate-fixture.so", "mode-setid"),
    ("NEEDED", "cpp-harden", "@gate-fixture/usr/lib/gate-fixture/libgate-fixture.so", "needed-undeclared"),
]


def normalised(text):
    return " ".join(text.replace("\\\n", "").split())


def digest(text):
    return hashlib.sha256(text.encode("utf-8", "surrogateescape")).hexdigest()[:16]


class Findings:
    """Findings keyed by file, rule and the hash of the offending text, so that one finding cannot stand in for another."""

    def __init__(self):
        self.counts = collections.Counter()
        self.texts = {}
        self.details = collections.defaultdict(list)

    def add(self, path, rule, text, detail, weight=1):
        text = normalised(text)
        key = (path, rule, digest(text))
        self.counts[key] += weight
        self.texts[key] = text
        self.details[key].append(detail)


def die(message):
    sys.exit(f"gate: {message}")


def read(path):
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(text)


def run(argv, **kwargs):
    return subprocess.run(argv, capture_output=True, text=True, check=False, **kwargs)


def numbered(path):
    return enumerate(read(path).splitlines(), 1)


@functools.cache
def source_lines(path):
    return read(path).splitlines()


def source_text(path, first, last=None):
    """The lines a finding names, as the text its baseline row is keyed by; the message when the file is not in the tree."""
    lines = source_lines(path) if path in tracked() else []
    return "\n".join(lines[first - 1 : last or first]) if 0 < first <= len(lines) else None


def require(tool, package):
    pin = re.search(rf"^{re.escape(package)}==(\d+\.\d+\.\d+)", read(REQUIREMENTS), re.MULTILINE)
    if not pin:
        die(f"{REQUIREMENTS} does not pin {package}")
    found = run([tool, "--version"]).stdout if shutil.which(tool) else ""
    if not re.search(rf"(?<![\d.]){re.escape(pin.group(1))}(?![\d.])", found):
        die(f"{tool} {pin.group(1)} is required; install it with: python3 -m pip install -r {REQUIREMENTS}")


@functools.cache
def tracked():
    # only what git tracks, so a stray file in a checkout judges the same as in CI's clone
    listed = run(["git", "ls-files", "--cached"]).stdout.splitlines()
    files = [p for p in listed if os.path.isfile(p) and not os.path.islink(p)]
    if not files:
        die("git lists no files; run the gates from a checkout")
    return frozenset(files)


def scratch():
    root = tempfile.mkdtemp(prefix="hypr-de-gates-")
    atexit.register(shutil.rmtree, root, ignore_errors=True)
    return root


def without_disable(line):
    def rest(directive):
        kept = [word for word in directive[1].split() if not word.startswith("disable=")]
        # a directive left with nothing in it is a parse error
        return "# shellcheck " + " ".join(kept) if kept else "#"

    return SHELLCHECK_DIRECTIVE.sub(rest, line)


def without_luacheck(line):
    return LUA_SUPPRESSION.sub(lambda match: match[0].replace("luacheck", "luacheck off"), line)


def copies_of(paths, rewrite):
    copies = scratch()
    for path in paths:
        write(os.path.join(copies, path), rewrite(path))
    return copies


def per_line(transform):
    return lambda path: "".join(transform(line) for line in read(path).splitlines(keepends=True))


def suppressions(found, paths, directive):
    for path in paths:
        for number, line in numbered(path):
            if directive.search(line):
                found.add(path, "suppression", line, f"{path}:{number}: {line.strip()}")


def head_of(path):
    with open(path, "rb") as f:
        return f.read(4096)


def first_line(path):
    return head_of(path).decode("utf-8", "replace").split("\n", 1)[0]


def interpreter(first):
    words = first[2:].split() if first.startswith("#!") else []
    if words and os.path.basename(words[0]) == "env":
        words = [w for w in words[1:] if not w.startswith("-") and "=" not in w]
    return os.path.basename(words[0]) if words else None


def language(first):
    name = interpreter(first)
    if name in LINTED_SHELLS or name in OTHER_SHELLS:
        return "shell"
    if name and re.fullmatch(r"python[\d.]*", name):
        return "python"
    if name and re.fullmatch(r"lua(?:jit)?[\d.]*", name):
        return "lua"
    return name


def suffix(path):
    name = os.path.basename(path)
    return name[name.rfind(".") :].lower() if "." in name else ""


@functools.cache
def manifest_rows():
    entries, reasons = {}, {}
    for number, line in enumerate(read(MANIFEST).splitlines(), 1):
        fields = line.split("\t")
        if len(fields) not in (2, 3) or (len(fields) == 3) != (fields[1] == "blob") or not all(fields):
            die(f"{MANIFEST}:{number}: expected a path and a class separated by a tab, and for a blob a third field that says why it is in the tree")
        entries[fields[0]] = fields[1]
        reasons[fields[0]] = fields[2:]
    return entries, reasons


def manifest():
    return manifest_rows()[0]


def gated_dirs(files):
    return {os.path.dirname(p) for p in files if re.fullmatch(r"plugins/[^/]+/CMakeLists\.txt", p)}


def needs_class(path, gated):
    inside = any(path.startswith(d + "/") for d in gated)
    if os.path.basename(path) == "PKGBUILD" or suffix(path) == ".spec":
        return True
    if os.path.basename(path) == "CMakeLists.txt":
        return os.path.dirname(path) not in gated
    return suffix(path) not in KNOWN_SUFFIXES or (path.lower().endswith(CPP_SUFFIXES) and not inside)


def gate_classify(found, _args):
    files, (classes, reasons) = tracked(), manifest_rows()
    gated = gated_dirs(files)
    for path, kind in sorted(classes.items()):
        if path not in files:
            found.add(path, "missing", "not in the tree", f"{path}: listed in {MANIFEST} but not in the tree")
        elif kind not in CLASSES:
            found.add(path, "invalid", kind, f"{path}: unknown class '{kind}'; one of {', '.join(CLASSES)}")
        elif kind == "blob" and not reasons[path]:
            found.add(path, "invalid", kind, f"{path}: a blob needs a reason")
        elif kind == "cpp-fixture" and not path.startswith("tests/gates/"):
            found.add(path, "invalid", kind, f"{path}: only the gates' own fixtures under tests/gates are cpp-fixture")
        elif kind == "cpp-test" and not path.lower().endswith(CPP_SUFFIXES):
            found.add(path, "invalid", kind, f"{path}: only a C or C++ source or header is cpp-test")
    for path in sorted(files):
        kind = classes.get(path)
        if os.path.basename(path) == "PKGBUILD" and kind not in ("pkgbuild", "cpp-fixture"):
            found.add(path, "packaging-class", str(kind), f"{path}: a PKGBUILD is classified pkgbuild, so the gates build its package")
        if suffix(path) == ".spec" and kind != "spec":
            found.add(path, "packaging-class", str(kind), f"{path}: an RPM spec is classified spec, so the gates check it")
        why = opaque(path)
        if why and kind != "blob":
            found.add(path, "opaque", "opaque", f"{path}: {why}; classify it blob, with the reason it is in the tree")
        if head_of(path).startswith(OBJECT_MAGIC):
            found.add(path, "binary", "binary", f"{path}: a committed object, library or executable; build it from source in a package instead")
        if kind is None:
            if needs_class(path, gated):
                found.add(path, "unclassified", "unclassified", f"{path}: add it to {MANIFEST} with one of: {', '.join(CLASSES)}")
            continue
        first = first_line(path)
        if kind in ("data", "make") and (first.startswith("#!") or os.stat(path).st_mode & stat.S_IXUSR):
            found.add(path, "code-marked-data", kind, f"{path}: is listed as {kind} but has a shebang or the executable bit")
        spoken = language(first)
        if spoken and {"sh": "shell", "bash": "shell"}.get(kind, kind) != spoken:
            found.add(path, "language-differs", first, f"{path}: is listed as {kind} but its shebang is {first}")
    pkgbuilds = {}
    for path in sorted(p for p in files if classes.get(p) == "pkgbuild"):
        for name in re.findall(r"^(?:pkgname|pkgbase)=\(?'?\"?([\w.+-]+)", read(path), re.MULTILINE):
            pkgbuilds.setdefault(name, path)
    for path in sorted(p for p in files if suffix(p) == ".spec"):
        check_spec(found, path, pkgbuilds)


def opaque(path):
    with open(path, "rb") as f:
        data = f.read()
    counts = collections.Counter(data)
    entropy = -sum(n / len(data) * math.log2(n / len(data)) for n in counts.values()) if data else 0
    if len(data) >= OPAQUE_MIN and entropy >= OPAQUE_ENTROPY:
        return f"{entropy:.1f} bits per byte, as compressed or encrypted data has"
    encoded = ENCODED.search(data.decode("latin-1"))
    return f"{len(encoded[0])} characters of encoded data at byte {encoded.start()}" if encoded else None


def check_spec(found, path, pkgbuilds):
    """A spec that compiles runs nothing but the lines SPEC_BUILD_LINE allows, and a PKGBUILD the gates build makes a package of its name."""
    text = read(path)
    for macro in SPEC_FLAGS_MACRO.finditer(text):
        found.add(path, "spec-flags", macro[0], f"{path}: {macro[0]} changes the distribution's compiler flags or build type")
    steps, current = [], None
    for number, line in enumerate(text.splitlines(), 1):
        section = SPEC_SECTION.match(line)
        current = section[1] if section else current
        if not section and current in ("prep", "conf", "build", "install"):
            steps.append((number, line))
    requires = [line.split(":", 1)[1] for line in text.splitlines() if re.match(r"BuildRequires\s*:", line)]
    if not any(SPEC_COMPILES.search(re.sub(r"%\{?[?!]*_*", " ", line.split("#", 1)[0])) for line in [*requires, *(line for _n, line in steps)]):
        return
    for number, line in steps:
        if not SPEC_BUILD_LINE.fullmatch(line):
            found.add(path, "spec-build-step", line, f"{path}:{number}: {line.strip()}: a spec that compiles runs only %autosetup, %cmake -S <directory>, %cmake_build and %cmake_install")
    name = re.search(r"^Name:\s*(\S+)", text, re.MULTILINE)
    if not pkgbuilds.get(name[1] if name else ""):
        found.add(path, "spec-unmatched", "unmatched", f"{path}: no PKGBUILD builds a package named {name[1] if name else '(no Name)'}, so the gates build nothing like it")


def shell_scripts(files, classes):
    for path in sorted(files):
        head = head_of(path)
        first = head.decode("utf-8", "replace").split("\n", 1)[0]
        shell = interpreter(first)
        if shell in OTHER_SHELLS:
            yield path, None
        elif path.endswith(SHELL_SUFFIXES) or shell in LINTED_SHELLS:
            yield path, []
        elif first.startswith("#!") or b"\0" in head or path.endswith(".install") or os.path.basename(path) == "PKGBUILD":
            continue
        elif classes.get(path) in ("sh", "bash"):
            yield path, [f"--shell={classes[path]}"]
        elif re.search(rb"#\s*shellcheck\s+shell=", head):
            yield path, []
        elif os.stat(path).st_mode & stat.S_IXUSR:
            # an executable file with no shebang is run by a shell, and every shell reads sh
            yield path, ["--shell=sh"]


def scriptlets(found, path):
    # the spec's own line numbers survive, so a finding names the line in the spec
    lines, kept, current = read(path).splitlines(), [], None
    for number, line in enumerate(lines, 1):
        section = SPEC_SECTION.match(line)
        if section:
            options = section[2].split()
            current = section[1] if SPEC_SCRIPTLET.match(section[1]) else None
            shell = options[options.index("-p") + 1] if "-p" in options[:-1] else "/bin/sh"
            if current and shell not in SPEC_SHELLS:
                found.add(path, "unlintable-shell", line, f"{path}:{number}: %{current} runs {shell}, which no gate lints")
                current = None
            kept.append("")
        elif current and re.match(r"%(?:if|else|elif|endif)\b", line):
            kept.append("")
        else:
            # a macro becomes one plain word, which is all shellcheck needs to read the line around it
            kept.append(re.sub(r"%\{[?!]*(\w+)[^}]*\}", r"rpm_\1", line) if current else "")
    return "\n".join(kept) + "\n"


def gate_shell(found, _args):
    require("shellcheck", "shellcheck-py")
    files = tracked()
    batches = collections.defaultdict(list)
    for path, options in shell_scripts(files, manifest()):
        if options is None:
            found.add(path, "unlintable-shell", first_line(path), f"{path}: its shebang names a shell shellcheck cannot read; write it for sh or bash")
        else:
            batches[tuple(options)].append(path)
    batches["--shell=bash",] += sorted(p for p in files if p.endswith(".install"))
    batches["--shell=bash", f"--exclude={PKGBUILD_EXCLUDES}"] += sorted(p for p in files if os.path.basename(p) == "PKGBUILD")
    specs = sorted(p for p in files if p.endswith(".spec"))
    # shellcheck has no switch to ignore its inline directives, so it reads copies that have none
    copies = copies_of([p for paths in batches.values() for p in paths], per_line(without_disable))
    for path in specs:
        extracted = scriptlets(found, path)
        scriptlet_writes(found, path, extracted)
        write(os.path.join(copies, path), without_disable(extracted))
    batches["--shell=sh",] += specs
    pinned = [f"--rcfile={os.path.abspath(SHELLCHECK_RC)}", "--format=json1"]
    for options, paths in batches.items():
        if not paths:
            continue
        result = run(["shellcheck", *pinned, *options, *paths], cwd=copies)
        try:
            comments = json.loads(result.stdout)["comments"]
        except (ValueError, KeyError):
            die(f"shellcheck gave no report: {result.stderr.strip()}")
        for c in comments:
            text = source_text(c["file"], c["line"], c["endLine"]) or c["message"]
            found.add(c["file"], f"SC{c['code']}", text, f"{c['file']}:{c['line']}: SC{c['code']} {c['message']}")
        suppressions(found, paths, SHELLCHECK_DIRECTIVE)


def gate_python(found, _args):
    require("ruff", "ruff")
    classes = manifest()
    paths = sorted(p for p in tracked() if p.endswith(".py") or language(first_line(p)) == "python" or classes.get(p) == "python")
    # one config for every file and no inline suppression, so a nested config or a comment cannot change the result
    result = run(["ruff", "check", "--no-cache", "--config", RUFF_CONFIG, "--ignore-noqa", "--output-format=json", *paths])
    try:
        diagnostics = json.loads(result.stdout)
    except ValueError:
        die(f"ruff gave no report: {result.stderr.strip()}")
    for d in diagnostics:
        path = os.path.relpath(d["filename"])
        code = d["code"] or "invalid-syntax"
        text = source_text(path, d["location"]["row"], d["end_location"]["row"]) or d["message"]
        found.add(path, code, text, f"{path}:{d['location']['row']}: {code} {d['message']}")
    suppressions(found, paths, PYTHON_SUPPRESSION)


def gate_lua(found, _args):
    version = run(["luacheck", "--version"]).stdout if shutil.which("luacheck") else ""
    if f"Luacheck: {LUACHECK}" not in version:
        die(f"luacheck {LUACHECK} is required; the CI workflow shows where to get it")
    classes = manifest()
    paths = sorted(p for p in tracked() if p.endswith(".lua") or language(first_line(p)) == "lua" or classes.get(p) == "lua")
    # luacheck has no switch to ignore inline options, and it applies a config's per-directory rules relative to the config
    copies = copies_of(paths, per_line(without_luacheck))
    shutil.copy(LUACHECK_RC, copies)
    result = run(["luacheck", "--config", LUACHECK_RC, "--no-default-config", "--formatter=plain", "--codes", "--no-color", *paths], cwd=copies)
    if result.returncode > 2:
        die(f"luacheck could not run: {result.stdout.strip()} {result.stderr.strip()}")
    for line in result.stdout.splitlines():
        match = LUACHECK_LINE.match(line)
        if match:
            found.add(match[1], match[4], source_text(match[1], int(match[2])) or match[5], line)
    suppressions(found, paths, LUA_SUPPRESSION)


# ---------- C++: build each package the way it ships, with every compile and link recorded


def toolchain(found, what):
    missing = [tool for tool in TOOLCHAIN if not shutil.which(tool)]
    if missing:
        found.add("toolchain", "cannot-run", "cannot run", f"toolchain: {', '.join(missing)} missing, so {what} cannot be built or checked")
    return not missing


def handed_to_builder(work):
    # the build user owns only what the build writes; the shim, its wrappers and the records stay the gate's
    for name in BUILDER_DIRS:
        os.makedirs(os.path.join(work, name), exist_ok=True)
    # the build user is neither the owner nor in the group, so it gets the other bits: here, to pass through
    os.chmod(work, 0o701)
    if os.geteuid() == 0:
        for name in BUILDER_DIRS:
            for directory, _names, files in os.walk(os.path.join(work, name)):
                for entry in [".", *files]:
                    os.chown(os.path.join(directory, entry), BUILDER, BUILDER)


def shim(work):
    """Compiler wrappers for one build, each running the shim with the real driver and the socket it sends its record to."""
    wrappers = os.path.join(work, "bin")
    os.makedirs(wrappers)
    shutil.copy(SHIM, work)
    reals = {}
    for name in SHIMMED:
        real = shutil.which(name)
        if not real:
            continue
        reals[name] = real
        command = [sys.executable, "-I", os.path.join(work, "shim.py"), real, os.path.join(work, "records.sock")]
        scrub = f"unset {' '.join(SCRUBBED)}\nfor name in $(env | sed -n 's/^\\(LD_[A-Za-z0-9_]*\\)=.*/\\1/p'); do unset \"$name\"; done\n"
        write(os.path.join(wrappers, name), f'#!/bin/sh\n{scrub}exec {shlex.join(command)} "$@"\n')
        os.chmod(os.path.join(wrappers, name), 0o705)
    return wrappers, reals


class Recorder:
    """The records the shim sends while a build runs. The build can add a record over the socket, but never edit or delete one."""

    def __init__(self, work):
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(os.path.join(work, "records.sock"))
        # connecting needs write access to the socket; the build user cannot remove it from the gate's directory
        if os.geteuid() == 0:
            os.chown(os.path.join(work, "records.sock"), BUILDER, BUILDER)
        self.server.listen(256)
        self.server.settimeout(0.2)
        self.messages, self.readers, self.stopped = [], [], threading.Event()
        self.acceptor = threading.Thread(target=self.accept, daemon=True)
        self.acceptor.start()

    def accept(self):
        while not self.stopped.is_set():
            try:
                self.read_from(self.server.accept()[0])
            except TimeoutError:
                continue

    def read_from(self, conn):
        reader = threading.Thread(target=self.read, args=(conn,), daemon=True)
        self.readers.append(reader)
        reader.start()

    def read(self, conn):
        with conn:
            pid = struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[0]
            conn.settimeout(60)
            chunks = []
            try:
                while chunk := conn.recv(1 << 20):
                    chunks.append(chunk)
            except OSError:
                chunks = None
        self.messages.append((pid, None if chunks is None else b"".join(chunks)))

    def close(self):
        """Every message sent before the build ended, including connections still waiting to be accepted."""
        self.stopped.set()
        self.acceptor.join()
        self.server.setblocking(False)
        while True:
            try:
                self.read_from(self.server.accept()[0])
            except BlockingIOError:
                break
        self.server.close()
        for reader in self.readers:
            reader.join(timeout=120)
        return self.messages


def fits(value, shape):
    """Whether a record from the shim has the shape the gate reads, so a malformed one is a finding and not a crash."""
    if isinstance(shape, list):
        return isinstance(value, list) and all(fits(v, shape[0]) for v in value)
    if isinstance(shape, dict) and "*" in shape:
        return isinstance(value, dict) and all(isinstance(k, str) and fits(v, shape["*"]) for k, v in value.items())
    if isinstance(shape, dict):
        return isinstance(value, dict) and all(
            fits(value[k.rstrip("?")], v) if k.rstrip("?") in value else k.endswith("?") for k, v in shape.items()
        )
    return isinstance(value, shape)


OBJECT_SHAPE = {"sha256": str, "lto": bool, "defines": [str]}
RECORD_SHAPE = {
    "cwd": str, "compiler": str, "argv": [str], "options": [str], "jobs": [[str]], "status": int, "diagnostics": str, "sources": int,
    "preprocessed?": str, "objects?": {"*": OBJECT_SHAPE},
    "link?": {"output": str, "build_id": (str, type(None)), "code": (str, type(None)), "inputs": [{
        "path": str, "missing?": bool, "uid?": int, "mode?": int, "kind?": str, "sha256?": str, "lto?": bool,
        "members?": [{"name": str, "sha256": str, "lto": bool}],
    }]},
}


def parsed_records(messages, shims):
    """The well-formed records from processes that ran the shim, in a fixed order, and a finding for every other message."""
    records, problems = [], []
    for pid, data in messages:
        try:
            record = json.loads(data.decode("utf-8", "surrogateescape")) if data is not None else None
        except ValueError:
            record = None
        if shims is not None and pid not in shims:
            problems.append(("forged-record", f"process {pid}, which never ran the shim, sent a record"))
        elif not fits(record, RECORD_SHAPE):
            problems.append(("malformed-record", f"process {pid} sent a record the gate cannot read: {(data or b'')[:120]!r}"))
        else:
            records.append(record)
    records.sort(key=lambda r: json.dumps(r, sort_keys=True))
    return records, problems


def srcinfo(pkgbuild, start, wrappers):
    result = run(as_builder(["makepkg", "--printsrcinfo"]), cwd=start, env=builder_env(os.path.join(os.path.dirname(start), "home"), wrappers))
    info = collections.defaultdict(list)
    for line in result.stdout.splitlines():
        key, sep, value = line.strip().partition(" = ")
        if sep:
            info[key].append(value)
    if not info.get("pkgbase"):
        die(f"makepkg cannot read {pkgbuild}: {result.stderr.strip()}")
    return info


def as_builder(argv):
    # makepkg will not run as root, and a build user cannot write the gate's own files
    return ["setpriv", f"--reuid={BUILDER}", f"--regid={BUILDER}", "--clear-groups", *argv] if os.geteuid() == 0 else argv


def programs(log):
    """From an strace -f log: each program a process ran, in order, and each process's parent."""
    parents, runs, pending = {}, [], {}
    for line in read(log).splitlines():
        spawn = SPAWN.match(line)
        if spawn:
            parents[int(spawn[2])] = int(spawn[1])
            continue
        call = EXEC.match(line)
        if not call:
            continue
        pid = int(call[1])
        if call[2] is not None and line.endswith("<unfinished ...>"):
            pending[pid] = C_STRING.findall(call[2])
            continue
        strings = C_STRING.findall(call[2]) if call[2] is not None else pending.pop(pid, None)
        if strings and line.endswith(" = 0"):
            runs.append((pid, strings[0], strings[1:]))
    return parents, runs


def shim_processes(work, reals, parents, runs):
    """The processes that ran the gate's shim on a real compiler, and a finding for any tool that ran outside one."""
    shim_path, wrappers = os.path.join(work, "shim.py"), os.path.join(work, "bin")
    image, shims, problems = {}, set(), []

    def under_shim(pid):
        seen = set()
        while pid is not None and pid not in seen:
            seen.add(pid)
            if shim_path in image.get(pid, ("", []))[1]:
                return True
            pid = parents.get(pid)
        return False

    for pid, path, args in runs:
        image[pid] = (path, args)
        if under_shim(pid) and not trusted(path, work):
            problems.append(("untrusted-tool", f"process {pid} under the compiler shim ran {path}, a program the build user could have written"))
        if shim_path in args:
            real = args[args.index(shim_path) + 1] if args.index(shim_path) + 1 < len(args) else ""
            if real in reals.values():
                shims.add(pid)
            else:
                problems.append(("unshimmed", f"process {pid} ran the shim on {real}, which is not a compiler the gate wrapped"))
        elif os.path.dirname(path) != wrappers and TOOL.fullmatch(os.path.basename(path)) and not probe(args[1:]) and not under_shim(parents.get(pid)):
            problems.append(("unshimmed", f"{path} ran outside the gate's compiler shim: {' '.join(args[:6])}"))
    return shims, problems


def trusted(path, work):
    """A program only root could have written or put in place: root's, not writable by others, in directories only root can change."""
    real = os.path.realpath(path)
    if not os.path.isabs(path) or real == work or real.startswith(work + "/"):
        return False
    while True:
        try:
            status = os.stat(real)
        except OSError:
            return False
        sticky = stat.S_ISDIR(status.st_mode) and status.st_mode & stat.S_ISVTX
        if status.st_uid != 0 or (status.st_mode & 0o022 and not sticky):
            return False
        if real == "/":
            return True
        real = os.path.dirname(real)


def probe(args):
    """A call that names no input and no output, such as CMake asking the linker for its version or its options."""
    words = iter(args)
    for word in words:
        if word == "-m":
            next(words, None)
        elif word == "-" or not word.startswith("-") or word.startswith(("-o", "--output", "@")):
            return False
    return True


def recorded_build(work, reals, argv, traced=True, **kwargs):
    """Run a build as the build user under strace; keep the records from processes that ran the shim, and a finding for anything else.
    Untraced, every record is kept, which is sound only for a build that ships no ELF file."""
    recorder = Recorder(work)
    log = os.path.join(work, "trace.log")
    trace = ["strace", "-f", "-qq", "--seccomp-bpf", "-e", "trace=execve,execveat,fork,vfork,clone,clone3", "-e", "signal=none", "-s", "4096", "-o", log]
    result = run([*trace, "--", *as_builder(argv)] if traced else as_builder(argv), **kwargs)
    messages = recorder.close()
    if not traced:
        records, bad = parsed_records(messages, None)
        return result, records, bad
    parents, runs = programs(log) if os.path.exists(log) else ({}, [])
    if not runs:
        return result, [], [("cannot-run", f"strace could not trace the build: {result.stderr.strip()[-400:]}")]
    shims, problems = shim_processes(work, reals, parents, runs)
    records, bad = parsed_records(messages, shims)
    return result, records, problems + bad


def builder_env(home, wrappers, **extra):
    # nothing from the gate's own environment, so a build cannot behave differently under CI; CC and CXX reach tests/run, which clears the rest
    path, compilers = f"{wrappers}:/usr/local/bin:/usr/bin:/bin", {"CC": os.path.join(wrappers, "cc"), "CXX": os.path.join(wrappers, "c++")}
    return {"PATH": path, "HOME": home, "LANG": "C.UTF-8", **compilers, **extra}


def makepkg_conf(work):
    conf = os.path.join(work, "makepkg.conf")
    write(
        conf,
        "source /etc/makepkg.conf\n"
        # the distribution's flags are emptied, so what is checked is what the repository itself asks for
        'CFLAGS="" CXXFLAGS="" CPPFLAGS="" LDFLAGS="" LTOFLAGS="" DEBUG_CFLAGS="" DEBUG_CXXFLAGS=""\n'
        f'MAKEFLAGS="-j{os.cpu_count()}"\n'
        "OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug !lto)\n"
        # check() runs between build() and package(), as it does when the package ships, so what it changes is audited too
        "BUILDENV=(!distcc !color !ccache check !sign)\n"
        "PKGEXT=.pkg.tar\nSRCEXT=.src.tar\n",
    )
    return conf


class Package:
    def __init__(self, pkgbuild, work, info, result, records, problems):
        self.pkgbuild, self.info, self.result, self.records, self.problems = pkgbuild, info, result, records, problems
        self.out = os.path.join(work, "out")
        self.pkgbase = info["pkgbase"][0]
        self.srcdir = os.path.realpath(os.path.join(work, "build", self.pkgbase, "src"))
        self.top = os.path.join(self.srcdir, f"{os.path.basename(info['url'][0])}-{info['pkgver'][0]}") if info.get("url") else self.srcdir
        self.pkgdirs = {name: os.path.join(work, "build", self.pkgbase, "pkg", name) for name in info["pkgname"]}

    def place(self, path):
        """Name a path from the build as the gates report it: a tracked file by its path, a file the build wrote as @<pkgbase>/<path>."""
        real = os.path.realpath(path)
        relative = os.path.relpath(real, self.top)
        if not relative.startswith(".."):
            return relative if relative in tracked() else f"@{self.pkgbase}/{relative}"
        relative = os.path.relpath(real, self.srcdir)
        return None if relative.startswith("..") else f"@{self.pkgbase}/@src/{relative}"


@functools.cache
def exported(top):
    archive = os.path.join(scratch(), "export.tar.gz")
    # a release tarball: the tracked files and nothing else, so no .git and no file the checkout happens to have
    with tarfile.open(archive, "w:gz") as tar:
        for path in sorted(tracked()):
            tar.add(path, arcname=f"{top}/{path}", recursive=False)
    return archive


@functools.cache
def package(pkgbuild, case):
    """The package built under the trace, check() included. Some tests fail under ptrace, as the main package's lock tests do,
    so a package whose build fails is built again untraced, and that build counts only if it ships no ELF file."""
    built = build_package(pkgbuild, case, traced=True)
    if built.result.returncode == 0:
        return built
    untraced = build_package(pkgbuild, case, traced=False)
    if untraced.result.returncode != 0 or any(next(elf_files(d), None) for d in untraced.pkgdirs.values()):
        return built
    print(f"note cpp-harden: {pkgbuild}: makepkg failed under the trace and passed without it, and the package ships no ELF file, so the untraced build is judged")
    return untraced


def build_package(pkgbuild, case, traced):
    work = scratch()
    start = os.path.join(work, "start")
    os.makedirs(start)
    here = os.path.dirname(pkgbuild)
    for path in tracked():
        if os.path.dirname(path) == here:
            shutil.copy(path, start)
    wrappers, reals = shim(work)
    handed_to_builder(work)
    info = srcinfo(pkgbuild, start, wrappers)
    for source in info.get("source", []):
        name, sep, _url = source.partition("::")
        if not sep and "://" not in source:
            continue
        if not sep or not info.get("url"):
            die(f"{pkgbuild}: a remote source needs a name:: and the PKGBUILD a url, so the gate can stand the tree in for it")
        shutil.copy(exported(f"{os.path.basename(info['url'][0])}-{info['pkgver'][0]}"), os.path.join(start, name))
    handed_to_builder(work)
    env = builder_env(os.path.join(work, "home"), wrappers, BUILDDIR=os.path.join(work, "build"), PKGDEST=os.path.join(work, "out"), SRCDEST=start, **({"FIXTURE_BAD": case} if case else {}))
    command = ["makepkg", "--config", makepkg_conf(work), "--nodeps", "--skipinteg", "--noconfirm", "--noprogressbar"]
    result, records, problems = recorded_build(work, reals, command, traced, cwd=start, env=env)
    return Package(pkgbuild, work, info, result, records, problems)


def packages(found, only):
    if not toolchain(found, "the packages"):
        return []
    classes = manifest()
    return [package(p, "") for p in sorted(tracked()) if os.path.basename(p) == "PKGBUILD" and classes.get(p) == "pkgbuild" and (not only or p in only)]


# ---------- the preprocessor's view of one compile


class Unit:
    """One compile the shim saw: its source, how GCC ran it, and what its preprocessed text shows."""

    def __init__(self, record, built):
        self.record, self.built = record, built
        compiles = [job for job in record["jobs"] if os.path.basename(job[0]) in ("cc1plus", "cc1")]
        self.cc1 = compiles[0] if compiles else []
        text = record["preprocessed"]
        primary = LINEMARKER.match(text.split("\n", 1)[0])
        self.source = os.path.join(record["cwd"], unescape(primary[2])) if primary else record["cwd"]
        self.name = built.place(self.source) or self.source
        self.text = text


def unescape(name):
    return re.sub(r"\\(.)", r"\1", name)


def lexed(text):
    """Comments out and string contents blanked, with every line kept in place; and each comment with the line it starts on."""
    code, comments, at, line = [], [], 0, 0
    for match in LEXEME.finditer(text):
        code.append(text[at : match.start()])
        line += text.count("\n", at, match.start())
        lexeme, breaks = match[0], match[0].count("\n")
        if match["comment"] is not None:
            comments.append((line, lexeme))
            code.append(" " + "\n" * breaks)
        else:
            code.append('""' + "\n" * breaks)
        line += breaks
        at = match.end()
    code.append(text[at:])
    return "".join(code).split("\n"), comments


def balanced(text, start, opening, closing):
    depth = 0
    for i in range(start, len(text)):
        depth += text[i] == opening
        depth -= text[i] == closing
        if depth == 0:
            return i
    return len(text)


def view(found, unit, seen):
    """Walk the preprocessed text: macro state at every #include, system headers inside the tree, and the tree's own lines."""
    raw = unit.text.split("\n")
    code, comments = lexed(unit.text)
    built, macros, builtins = unit.built, {}, {}
    places, region, where, inside, number, ready = [None] * len(code), None, None, None, 0, False
    # GCC marks a system macro's expansion with flag 3 and then returns to the file without it; a file still
    # marked 3 when it ends was made a system header from inside, by #pragma GCC system_header
    stack, system = [], {}

    def leave():
        left = stack.pop() if stack else None
        if left and system.get(left) and (left, "system") not in seen:
            seen.add((left, "system"))
            found.add(left, "system-header-in-tree", "system header", f"{left}: compiled as a system header, so GCC hides its warnings")

    tracked_macros = {"_FORTIFY_SOURCE", "__USE_FORTIFY_LEVEL", "_GLIBCXX_ASSERTIONS", "NDEBUG"}
    # glibc's features.h sets __USE_FORTIFY_LEVEL, so once the unit has left it an undefined level is fortify turned off
    glibc = False
    # the optimize or target pragma in force, if any, and the push_options not yet popped
    options = (None, ())
    origin = {}

    def report(rule, detail):
        # once per source, however many builds compile it
        if (unit.name, rule) not in seen:
            seen.add((unit.name, rule))
            found.add(unit.name, rule, rule, f"{unit.name}: {detail}")

    def check(at):
        level = macros.get("_FORTIFY_SOURCE")
        used = macros.get("__USE_FORTIFY_LEVEL")
        if not level or not level.isdigit() or int(level) < FORTIFY_LEVEL or ((used is not None or glibc) and (not used or not used.isdigit() or int(used) < FORTIFY_LEVEL)):
            report("fortify-off", f"_FORTIFY_SOURCE is {level} (__USE_FORTIFY_LEVEL {used}) at {at}{origin.get('_FORTIFY_SOURCE', '')}")
        if "_GLIBCXX_ASSERTIONS" not in macros:
            report("assertions-off", f"_GLIBCXX_ASSERTIONS is not defined at {at}{origin.get('_GLIBCXX_ASSERTIONS', '')}")
        if "NDEBUG" in macros:
            report("ndebug", f"NDEBUG is defined at {at}{origin.get('NDEBUG', '')}")

    for g, line in enumerate(code):
        if line.startswith("#"):
            marker = LINEMARKER.match(raw[g])
            if marker:
                name, flags = unescape(marker[2]), marker[3].split()
                glibc |= "2" in flags and os.path.basename(where or "") == "features.h"
                previous, region = region, {"<built-in>": "built-in", "<command-line>": "command-line"}.get(name, "source")
                entered = built.place(os.path.join(unit.record["cwd"], name)) if region == "source" else None
                if region == "source" and previous == "command-line":
                    ready = True
                    check(f"the start of {entered or name}")
                    stack[:] = [entered]
                elif region == "source" and ready and "1" in flags:
                    check(f"{where}:{number - 1} where it includes {entered or name}")
                    stack.append(entered)
                elif region == "source" and ready and "2" in flags:
                    leave()
                if region == "source" and ready and stack and stack[-1]:
                    system[stack[-1]] = "3" in flags
                inside, where, number = entered, entered or name, int(marker[1])
                continue
            macro = MACRO.match(line)
            if macro:
                defined, name, value = macro[1] == "define", macro[2], (macro[3] or "").strip()
                if region == "built-in" and defined:
                    builtins[name] = value
                if name in tracked_macros:
                    if defined:
                        macros[name] = value
                    else:
                        macros.pop(name, None)
                    origin[name] = f", set at {where}:{number}" if region == "source" else " from the command line"
            pragma = PRAGMA.match(line)
            if pragma and pragma[1] == "GCC" and region == "source":
                options = pragmas(options, pragma[2], (where, number, raw[g]))
        places[g] = (inside, number) if inside else None
        number += 1
    check("the end of the unit")
    # an optimize or target pragma still in force when the unit ends, from any header, applies to all the code after it
    if options[0] or options[1]:
        where_set, at, text = options[0] or options[1][-1][1]
        found.add(unit.name, "pragma-unbalanced", text, f"{unit.name}: {' '.join(text.split())} at {where_set}:{at} is still in force at the end of the unit")
    while stack:
        leave()

    for rule, ok in (
        ("unoptimized", "__OPTIMIZE__" in builtins),
        ("stack-protector-off", "__SSP_STRONG__" in builtins or "__SSP_ALL__" in builtins),
        ("not-pic", "__PIC__" in builtins or "__PIE__" in builtins),
        ("cf-protection-off", platform.machine() != "x86_64" or builtins.get("__CET__") == "3"),
        ("stack-clash-off", last_switch(unit.cc1, "-fstack-clash-protection", "-fno-stack-clash-protection")),
        # -mmanual-endbr leaves __CET__ and the IBT note in place and drops the endbr64 from every function not marked cf_check
        ("manual-endbr", not last_switch(unit.cc1, "-mmanual-endbr", "-mno-manual-endbr")),
    ):
        if not ok:
            report(rule, f"compiled with {rule.replace('-off', ' off').replace('-', ' ')}")
    for name in REQUIRED_WARNINGS:
        if not last_switch(unit.cc1, f"-W{name}", f"-Wno-{name}"):
            report(f"warning-missing:-W{name}", f"compiled without -W{name}")
    for flag in warnings_off(unit.cc1):
        # counted once per package, so a new source that shares the package's flags adds nothing
        if (built.pkgbuild, flag) not in seen:
            seen.add((built.pkgbuild, flag))
            found.add(built.pkgbuild, f"warning-off:{flag}", flag, f"{unit.name}: compiled with {flag}")

    chunks = collections.defaultdict(list)
    for g, place in enumerate(places):
        if place:
            chunks[place[0]].append((place[1], code[g], raw[g]))
    for path, lines in chunks.items():
        scan(found, path, lines, seen)
    for g, comment in comments:
        place = places[g] if g < len(places) else None
        if place and NOLINT.search(comment) and (place, "nolint") not in seen:
            seen.add((place, "nolint"))
            found.add(place[0], "suppression: " + " ".join(raw[g].split()), raw[g], f"{place[0]}:{place[1]}: {raw[g].strip()}")
    return {p for p in (place[0] for place in places if place)}


def pragmas(options, name, place):
    current, pushed = options
    if name == "push_options":
        return current, (*pushed, (current, place))
    if name == "pop_options":
        return (pushed[-1][0], pushed[:-1]) if pushed else options
    if name == "reset_options":
        return None, pushed
    return (place, pushed) if name in ("optimize", "target") else options


def scan(found, path, lines, seen):
    for number, code, raw in lines:
        pragma = PRAGMA.match(code)
        if not pragma or (path, number) in seen:
            continue
        seen.add((path, number))
        text = " ".join(raw.split())
        if pragma[2] in WEAKENING_PRAGMAS:
            found.add(path, f"source-weakens: #pragma {pragma[1]} {pragma[2]}", text, f"{path}:{number}: {text}")
        elif pragma[2] == "diagnostic" and pragma[3] in ("ignored", "warning"):
            found.add(path, f"suppression: {text}", text, f"{path}:{number}: {text}")
    text = "\n".join(code for _number, code, _raw in lines)
    starts = [0]
    for _ in lines[:-1]:
        starts.append(text.index("\n", starts[-1]) + 1)
    for match in ATTRIBUTE.finditer(text):
        opening = match.end() - 1
        body = text[opening : balanced(text, opening, *("()" if match[0] != "[[" else "[]"))]
        for name in WEAKENING_ATTRIBUTE.finditer(body):
            index = max(i for i, start in enumerate(starts) if start <= match.start())
            number = lines[index][0]
            if (path, number, name[1]) not in seen:
                seen.add((path, number, name[1]))
                found.add(path, f"source-weakens: attribute {name[1]}", lines[index][2], f"{path}:{number}: {lines[index][2].strip()}")


def last_switch(args, on, off):
    state = False
    for arg in args:
        state = True if arg == on else False if arg == off else state
    return state


def warnings_off(args):
    last = {}
    for arg in args:
        if arg in {"-w", "-fpermissive"}:
            last[arg] = arg
        elif arg.startswith("-W") and not arg.startswith(("-Wl,", "-Wa,", "-Wp,", "-Wno-error", "-Werror")):
            name = arg.removeprefix("-Wno-").removeprefix("-W")
            last[name] = arg
    return sorted({flag for flag in last.values() if flag in ("-w", "-fpermissive") or flag.startswith("-Wno-")})


# ---------- what the package ships


def elf_files(directory):
    for base, _names, files in os.walk(directory):
        for name in files:
            path = os.path.join(base, name)
            if not os.path.islink(path) and os.path.isfile(path):
                with open(path, "rb") as f:
                    head = f.read(8)
                if head.startswith(OBJECT_MAGIC):
                    yield path, head


def audit(found, built, units_by_object, links_by_build_id):
    """Every ELF a package installs: how it is linked, and which compiles went into it."""
    shipped = set()
    for pkgname, pkgdir in built.pkgdirs.items():
        for path, head in elf_files(pkgdir):
            key = f"@{pkgname}/{os.path.relpath(path, pkgdir)}"
            if not head.startswith(b"\x7fELF"):
                found.add(key, "unattributed", "archive", f"{key}: an archive in the package; the gate audits only ELF files it can trace to a compile")
                continue
            check_elf(found, key, path)
            check_needed(found, key, path, built)
            build_id = re.search(r"Build ID:\s*(\w+)", run(["readelf", "-nW", path]).stdout)
            # a build ID can be set by hand, so what the file loads, code and data, has to be what that link wrote
            code = run([sys.executable, "-I", SHIM, "--loaded-digest", path]).stdout.strip()
            links = [link for link in links_by_build_id.get(build_id[1] if build_id else None, []) if link["link"]["code"] == code]
            if not links:
                found.add(key, "unattributed", "no link", f"{key}: no link this build ran made it (build ID {build_id[1] if build_id else 'missing'})")
            for link in links:
                for unit in units_of(found, key, link, units_by_object):
                    shipped.add(id(unit))
    return shipped


def units_of(found, key, link, units_by_object):
    own, inputs = link.get("unit"), link["link"]["inputs"]
    missing = [i for i in inputs if i.get("missing")]
    if missing and (not own or len(missing) != 1):
        found.add(key, "unattributed", "temporary objects", f"{key}: links {len(missing)} temporary objects the gate cannot trace")
    elif own:
        yield own
    for entry in inputs:
        if entry.get("missing") or "sha256" not in entry:
            continue
        objects = entry.get("members", [entry]) if entry["kind"] in ("rel", "archive") else []
        if entry["kind"] in ("thin-archive", "exec") or (entry["kind"] == "archive" and not objects):
            found.add(key, "unattributed", entry["kind"], f"{key}: links {entry['path']}, which the gate cannot trace to a compile")
        for obj in objects:
            units = units_by_object.get(obj["sha256"], [])
            if obj.get("lto"):
                found.add(key, "unattributed", "lto", f"{key}: links LTO code from {entry['path']}; the gate sees only what each compile was asked for, not what LTO makes of it")
            elif units:
                yield from units
            else:
                found.add(key, "unattributed", "unknown object", f"{key}: links {entry['path']} {obj.get('name', '')}, which no compile the gate saw produced".rstrip())


@functools.cache
def installed():
    """The local pacman database: the packages that provide each name, what each depends on, and the package that owns each library file."""
    db = os.path.join(run(["pacman-conf", "DBPath"]).stdout.strip() or "/var/lib/pacman", "local")
    providers, depends, owners = collections.defaultdict(set), {}, {}
    for entry in sorted(os.listdir(db)):
        if not os.path.isfile(os.path.join(db, entry, "desc")):
            continue
        fields, current = collections.defaultdict(list), None
        for line in read(os.path.join(db, entry, "desc")).splitlines():
            current = line[1:-1] if line.startswith("%") and line.endswith("%") else current
            if current and line and not line.startswith("%"):
                fields[current].append(line)
        name = fields["NAME"][0]
        for provided in [name, *fields["PROVIDES"]]:
            providers[re.split(r"[<>=]", provided)[0]].add(name)
        depends[name] = [re.split(r"[<>=:]", d)[0].strip() for d in fields["DEPENDS"]]
        for line in read(os.path.join(db, entry, "files")).splitlines():
            if ".so" in line:
                owners["/" + line] = name
    return providers, depends, owners


@functools.cache
def provided_by(declared):
    """Every package the declared dependencies bring in, through each one's own dependencies."""
    providers, depends, _owners = installed()
    seen, todo = set(), list(declared)
    while todo:
        for name in providers.get(todo.pop(), ()):
            if name not in seen:
                seen.add(name)
                todo += depends.get(name, [])
    return frozenset(seen)


@functools.cache
def loader_paths():
    paths = collections.defaultdict(set)
    for line in run(["ldconfig", "-p"]).stdout.splitlines():
        entry = re.match(r"\s+(\S+) \(.*\) => (\S+)$", line)
        if entry:
            paths[entry[1]] |= {entry[2], os.path.realpath(entry[2])}
    return paths


def check_needed(found, key, path, built):
    """Each library the ELF needs is one the package ships or one a dependency it declares installs."""
    shipped = {name for pkgdir in built.pkgdirs.values() for _base, _dirs, files in os.walk(pkgdir) for name in files}
    allowed = provided_by(tuple(sorted(set(built.info.get("depends", [])))))
    owners = installed()[2]
    for soname in re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", run(["readelf", "-dW", path]).stdout):
        if "/" in soname or (soname not in shipped and not any(owners.get(p) in allowed for p in loader_paths().get(soname, ()))):
            found.add(key, "needed-undeclared", soname, f"{key}: needs {soname}, which neither the package nor a dependency it declares provides")


def archives(found, built):
    """Each package archive makepkg wrote, as it installs: no setuid, setgid, world-writable or non-root file, and a scriptlet that writes no program or library."""
    elf_dirs = {"/" + os.path.dirname(os.path.relpath(path, pkgdir)) for pkgdir in built.pkgdirs.values() for path, _head in elf_files(pkgdir)}
    for archive in sorted(os.listdir(built.out)):
        pkgname = archive.rsplit("-", 3)[0]
        with tarfile.open(os.path.join(built.out, archive)) as tar:
            for member in tar.getmembers():
                key = f"@{pkgname}/{member.name.rstrip('/')}"
                problems = {
                    "mode-setid": member.mode & (stat.S_ISUID | stat.S_ISGID),
                    "mode-world-writable": member.mode & stat.S_IWOTH and not member.issym(),
                    "owner-not-root": member.uid != 0 or member.gid != 0,
                }
                for rule in (rule for rule, hit in problems.items() if hit and not member.name.startswith(".")):
                    found.add(key, rule, rule, f"{key}: {rule} (mode {member.mode:o}, owner {member.uid}:{member.gid})")
                if member.name == ".INSTALL":
                    install = os.path.join(os.path.dirname(built.pkgbuild), built.info.get("install", [""])[0])
                    scriptlet_writes(found, install if install in tracked() else key, tar.extractfile(member).read().decode("utf-8", "replace"), elf_dirs)


def scriptlet_writes(found, path, text, extra_dirs=()):
    """A scriptlet line that names a program or library directory anywhere but as the command it runs."""
    extra = re.compile("|".join(rf"(?<![\w./$-]){re.escape(d)}(?![\w.-])" for d in sorted(extra_dirs) if d != "/")) if extra_dirs else None
    for number, line in enumerate(text.splitlines(), 1):
        code = line.split("#", 1)[0] if not line.lstrip().startswith("#") else ""
        hits = [*PROTECTED.finditer(code), *(extra.finditer(code) if extra else ())]
        if any(not COMMAND_WORD.search(code[: hit.start()]) for hit in hits):
            found.add(path, "scriptlet-writes-shipped", line, f"{path}:{number}: {line.strip()}: a scriptlet may run what the package installs, never write where programs and libraries live")


def check_elf(found, key, path):
    header, segments, dynamic = (run(["readelf", option, path]).stdout for option in ("-hW", "-lW", "-dW"))
    notes, symbols = run(["readelf", "-nW", path]).stdout, run(["readelf", "-sW", "--dyn-syms", path]).stdout
    stack = re.search(r"GNU_STACK.*?\b(R?W?E?)\s+0x\w+\s*$", segments, re.MULTILINE)
    imports = {m[1] for m in re.finditer(r"\bUND\s+(\w+)(?:@\S*)?\s*(?:\(\d+\))?$", symbols, re.MULTILINE)}
    problems = {
        "elf-not-pie": not re.search(r"Type:\s+DYN", header),
        "elf-no-relro": "GNU_RELRO" not in segments,
        "elf-lazy-binding": not re.search(r"BIND_NOW|Flags:.*\bNOW\b", dynamic),
        "elf-executable-stack": not stack or "E" in stack[1],
        "elf-no-cet": platform.machine() == "x86_64" and not re.search(r"x86 feature: .*IBT.*SHSTK", notes),
        "elf-runpath": re.search(r"\((?:RPATH|RUNPATH)\)", dynamic),
        "elf-textrel": re.search(r"\(TEXTREL\)|Flags:.*\bTEXTREL\b", dynamic),
    }
    for rule, hit in problems.items():
        if hit:
            found.add(key, rule, rule, f"{key}: fails {rule}")
    for name in sorted(imports & ALWAYS_FORTIFIED):
        found.add(key, f"elf-unfortified:{name}", name, f"{key}: imports plain {name}, which fortify always replaces, so some code in it was built without fortify")


def analyse(found, built):
    """Shipped ELFs, the compiles behind them, and every compile of a tracked source."""
    for rule, detail in built.problems:
        found.add(built.pkgbuild, rule, rule, f"{built.pkgbuild}: {detail}")
    if built.result.returncode != 0:
        found.add(built.pkgbuild, "build-failed", "makepkg failed", f"{built.pkgbuild}: makepkg failed\n{tail(built.result, built)}")
        return [], set()
    # records come sorted, and every record that matches an object or a build ID is judged, so no order decides which one counts
    units, units_by_object, links = [], collections.defaultdict(list), collections.defaultdict(list)
    for record in built.records:
        for option in (o for o in record["options"] if OVERRIDE.fullmatch(o)):
            found.add(built.pkgbuild, "driver-override", option, f"{built.pkgbuild}: a compile ran with {option}, which changes the programs GCC runs or what it tells them")
    for record in built.records:
        unit = Unit(record, built) if "preprocessed" in record else None
        if unit:
            units.append(unit)
            for obj in record.get("objects", {}).values():
                units_by_object[obj["sha256"]].append(unit)
        for path, obj in record.get("objects", {}).items():
            for name in obj["defines"]:
                where = unit.name if unit else built.place(path) or path
                found.add(where, f"defines-guard:{name}", name, f"{where}: defines {name}, so a failed stack or fortify check calls the package's own code instead of aborting")
        if record.get("link", {}).get("build_id"):
            links[record["link"]["build_id"]].append({**record, "unit": unit})
    shipped = audit(found, built, units_by_object, links)
    archives(found, built)
    checked = [u for u in units if id(u) in shipped or u.name in tracked()]
    seen, read_by = set(), set()
    for unit in checked:
        read_by |= view(found, unit, seen)
    check_warnings(found, built)
    return checked, read_by


def tail(result, built=None):
    text = result.stdout + result.stderr
    if built:
        text = text.replace(built.top + "/", "")
    lines = text.replace(os.getcwd() + "/", "").splitlines()
    headlines = [line for line in lines[:-25] if re.search(r"ERROR: \w+Sanitizer|runtime error:|\berror:", line)]
    return "\n".join([*headlines[:10], *lines[-25:]])


def check_warnings(found, built):
    seen = set()
    for record in built.records:
        for line in record.get("diagnostics", "").splitlines():
            match = COMPILER_WARNING.match(line)
            if not match or match.groups() in seen:
                continue
            seen.add(match.groups())
            # a warning in a header outside the repository still comes from the package's code
            where = built.place(os.path.join(record["cwd"], match[1]))
            text = (source_text(where, int(match[2])) if where else None) or match[4]
            found.add(where or built.pkgbuild, match[5] or "warning", text, f"{where or match[1]}:{match[2]}: {match[4]}")


@functools.cache
def harden_findings(pkgbuild, case):
    found = Findings()
    built = package(pkgbuild, case)
    return found, built, *analyse(found, built)


def gate_cpp_harden(found, args):
    read_by = set()
    for built in packages(found, args.pkgbuild):
        result, _built, _units, reads = harden_findings(built.pkgbuild, "")
        merge(found, result)
        read_by |= reads
    if not blocked(found) and not args.pkgbuild:
        classes = manifest()
        for directory in sorted(gated_dirs(tracked())):
            for path in sorted(p for p in tracked() if p.startswith(directory + "/") and p.lower().endswith(CPP_SUFFIXES)):
                if path not in read_by and path not in classes:
                    found.add(path, "not-built", "not built", f"{path}: no package's build reads it; build it there, or list it in {MANIFEST}")


def blocked(found):
    return any(key[1] in BLOCKING_RULES for key in found.counts)


def merge(found, other):
    for key, count in other.counts.items():
        found.counts[key] += count
        found.texts[key] = other.texts[key]
        found.details[key] += other.details[key]


def tidy_units(found, built, units):
    require("clang-tidy", "clang-tidy")
    # each source once, from a compile whose directory is still there: check()'s test builds remove theirs
    by_source = {}
    for unit in sorted(units, key=lambda u: not os.path.isdir(u.record["cwd"])):
        by_source.setdefault(unit.source, unit)
    units = list(by_source.values())
    database = scratch()
    entries = [{"directory": u.record["cwd"], "arguments": [u.record["compiler"], *u.record["argv"]], "file": u.source} for u in units]
    write(os.path.join(database, "compile_commands.json"), json.dumps(entries))
    command = ["clang-tidy", "-p", database, f"--config-file={os.path.abspath(TIDY_CONFIG)}", f"--header-filter=^{re.escape(built.srcdir)}/", "--quiet"]
    # the compile commands are GCC's, and clang must not fail on a warning flag only GCC has
    command += ["--extra-arg=-Wno-unknown-warning-option", "--extra-arg=-Wno-error"]
    with concurrent.futures.ThreadPoolExecutor(os.cpu_count()) as pool:
        reports = list(pool.map(lambda unit: run([*command, unit.source]), units))
    seen = set()
    for unit, report in zip(units, reports, strict=True):
        lines = [line for line in report.stdout.splitlines() if TIDY_LINE.match(line)]
        if report.returncode != 0 and not any("clang-diagnostic-error" in line for line in lines):
            found.add(unit.name, "tidy-failed", "tidy failed", f"{unit.name}: clang-tidy stopped with status {report.returncode} and no compile error to show for it\n{tail(report, built)}")
        for line in lines:
            match = TIDY_LINE.match(line)
            where = built.place(match[1])
            if line in seen or not where:
                continue
            seen.add(line)
            found.add(where, match[5], source_text(where, int(match[2])) or match[4], f"{where}:{match[2]}: {match[4]} [{match[5]}]")


def gate_cpp_tidy(found, args):
    for built in packages(found, args.pkgbuild):
        result, _built, units, _reads = harden_findings(built.pkgbuild, "")
        if blocked(result):
            found.add(built.pkgbuild, "not-judged", "not judged", f"{built.pkgbuild}: cpp-harden cannot see all of this package's code, so clang-tidy does not judge it")
        elif units:
            tidy_units(found, built, units)


# ---------- sanitizers: the plugins' tests under ASan and UBSan


def sanitizers(args):
    on, recovers = set(), False
    for arg in args:
        if arg.startswith("-fsanitize="):
            on |= set(arg.split("=", 1)[1].split(","))
        elif arg.startswith("-fno-sanitize="):
            removed = set(arg.split("=", 1)[1].split(","))
            on = set() if "all" in removed else on - removed - ({"undefined"} if removed else set())
        elif arg.startswith("-fsanitize-recover"):
            recovers = True
        elif arg == "-fno-sanitize-recover=all":
            recovers = False
    return on, recovers


def sanitize(found, project, *options):
    work = scratch()
    wrappers, reals = shim(work)
    handed_to_builder(work)
    build = os.path.join(os.path.realpath(work), "build")
    env = builder_env(os.path.join(work, "home"), wrappers)
    configure = ["cmake", "-S", os.path.abspath(project), "-B", build, "-DCMAKE_BUILD_TYPE=RelWithDebInfo", "-DHYPR_DE_SANITIZE=ON", *options]
    script = 'cmake "$@" && exec cmake --build "$0" --parallel'
    result, records, problems = recorded_build(work, reals, ["sh", "-c", script, build, *configure[1:]], env=env)
    for rule, detail in problems:
        found.add(project, rule, rule, f"{project}: {detail}")
    if result.returncode != 0:
        found.add(project, "build-failed", "sanitizer build failed", f"{project}: the sanitizer build failed\n{tail(result)}")
        return
    for record in records:
        if "preprocessed" not in record:
            continue
        compiles = [job for job in record["jobs"] if os.path.basename(job[0]) in ("cc1plus", "cc1")]
        on, recovers = sanitizers(compiles[0] if compiles else [])
        source = LINEMARKER.match(record["preprocessed"].split("\n", 1)[0])
        name = os.path.relpath(os.path.realpath(os.path.join(record["cwd"], unescape(source[2])))) if source else project
        if name in tracked() and (not {"address", "undefined"} <= on or recovers):
            found.add(name, "sanitizer-off", f"{sorted(on)} {recovers}", f"{name}: built with sanitizers {sorted(on)}{' that recover' if recovers else ''}")
    tests = run(as_builder(["ctest", "--test-dir", build, "--output-on-failure", "--no-tests=error"]), env=env)
    if "No tests were found" in tests.stdout + tests.stderr:
        found.add(project, "no-tests", "no tests", f"{project}: registers no test with add_test, so nothing ran under the sanitizers")
    elif tests.returncode != 0:
        found.add(project, "tests-failed", "tests failed", f"{project}: tests failed under ASan and UBSan\n{tail(tests)}")


def gate_cpp_sanitize(found, _args):
    if not toolchain(found, "the plugins' sanitizer builds"):
        return
    for directory in sorted(gated_dirs(tracked())):
        sanitize(found, directory)


def gate_cpp_selftest(found, _args):
    if not toolchain(found, "the self-test"):
        return

    def caught(case, gate):
        findings = Findings()
        if gate == "cpp-sanitize":
            sanitize(findings, FIXTURE, f"-DFIXTURE_BAD={case}")
            return findings.counts
        result, built, units, _reads = harden_findings(FIXTURE_PKGBUILD, case)
        if gate == "cpp-tidy" and units:
            tidy_units(findings, built, units)
        return findings.counts if gate == "cpp-tidy" else result.counts

    cases = sorted({(case, gate) for case, gate, _path, _rule in SELFTEST} | {("", "cpp-harden")})
    with concurrent.futures.ThreadPoolExecutor(os.cpu_count()) as pool:
        results = dict(zip(cases, pool.map(lambda entry: caught(*entry), cases), strict=True))
    for case, gate, path, rule in SELFTEST:
        if (path, rule) not in {key[:2] for key in results[case, gate]}:
            found.add(FIXTURE, f"missed:{case}", f"{gate} {path} {rule}", f"{gate} did not report {rule} at {path} for the fixture's {case} case; it reported {sorted(results[case, gate])}")
    for key in results["", "cpp-harden"]:
        found.add(FIXTURE, "clean-reported", " ".join(key), f"cpp-harden reported {key} for the clean fixture, which has none")


# ---------- the RPM the scene-plugin workflow builds on Fedora


# "FAIL: stack-prot test because ..." and "MAYB: test: notes, reason: ..."
ANNOCHECK_LINE = re.compile(r"^Hardened: \S+: (?:FAIL|MAYB): (?:test: (?P<maybe>[\w-]+)(?:, reason: (?P<why>.*?))?|(?P<test>[\w-]+) test because (?P<because>.*?))\s*$")


def gate_rpm(found, args):
    """Every binary RPM given: its modes as it installs, the ELF checks cpp-harden makes, and annocheck's per-compile notes."""
    rpms = sorted(p for p in args.rpms if not p.endswith(".src.rpm"))
    missing = [tool for tool in ("rpm", "rpm2cpio", "cpio", "readelf", "annocheck") if not shutil.which(tool)]
    if missing or not rpms:
        found.add("rpm", "cannot-run", "cannot run", f"rpm: {', '.join(missing) + ' missing' if missing else 'no RPM given with --rpms'}, so no RPM is audited")
        return
    root = scratch()
    for path in rpms:
        payload = subprocess.run(["rpm2cpio", path], capture_output=True, check=False)
        unpack = subprocess.run(["cpio", "-idm", "--quiet"], input=payload.stdout, cwd=root, capture_output=True, check=False)
        if payload.returncode or unpack.returncode:
            found.add(path, "cannot-run", "cannot unpack", f"{path}: cannot unpack: {(payload.stderr + unpack.stderr).decode(errors='replace').strip()}")
    for path in (p for p in rpms if not re.search(r"-debug(?:info|source)-", os.path.basename(p))):
        name = run(["rpm", "-qp", "--qf", "%{NAME}", path]).stdout
        files = run(["rpm", "-qp", "--qf", "[%{FILENAMES}\t%{FILEMODES}\t%{FILEUSERNAME}\t%{FILEGROUPNAME}\n]", path]).stdout
        for line in files.splitlines():
            installed, mode, user, group = line.split("\t")
            key, mode = f"@{name}{installed}", int(mode)
            problems = {
                "mode-setid": mode & (stat.S_ISUID | stat.S_ISGID),
                "mode-world-writable": mode & stat.S_IWOTH and not stat.S_ISLNK(mode),
                "owner-not-root": user != "root" or group != "root",
            }
            for rule in (rule for rule, hit in problems.items() if hit):
                found.add(key, rule, rule, f"{key}: {rule} (mode {mode:o}, owner {user}:{group})")
            unpacked = os.path.join(root, installed.lstrip("/"))
            if stat.S_ISREG(mode) and head_of(unpacked).startswith(b"\x7fELF"):
                check_elf(found, key, unpacked)
                annocheck(found, key, unpacked, os.path.join(root, "usr/lib/debug"))


def annocheck(found, key, path, debug):
    """Fedora's GCC records how each compile ran in annobin notes, which rpmbuild moves into the debuginfo package."""
    result = run(["annocheck", f"--debug-dir={debug}", path])
    tests = [match for match in map(ANNOCHECK_LINE.match, result.stdout.splitlines()) if match]
    for match in tests:
        test = match["test"] or match["maybe"]
        found.add(key, f"annocheck:{test}", test, f"{key}: annocheck {test}: {match['because'] or match['why'] or 'failed'}")
    if result.returncode and not tests:
        found.add(key, "cannot-run", "annocheck failed", f"{key}: annocheck failed with no test named\n{tail(result)}")


def parse_baseline(text):
    entries = {}
    for number, line in enumerate(text.splitlines(), 1):
        fields = line.split("\t")
        if len(fields) != 6 or not fields[4].isdigit() or digest(fields[5]) != fields[3]:
            die(f"{BASELINE}:{number}: expected gate, path, rule, the hash of the text, a count and the text, separated by tabs")
        gate, path, rule, key, count, text = fields
        entries[gate, path, rule, key] = (int(count), text)
    return entries


GATES = {
    "classify": gate_classify,
    "shell": gate_shell,
    "python": gate_python,
    "lua": gate_lua,
    "cpp-harden": gate_cpp_harden,
    "cpp-sanitize": gate_cpp_sanitize,
    "cpp-tidy": gate_cpp_tidy,
    "cpp-selftest": gate_cpp_selftest,
    "rpm": gate_rpm,
}


def successor(text, candidates, lines):
    """The candidate an edit made of a line with this text: the one most like it, when no other lines of the file are more like it."""
    windows = sorted({normalised("\n".join(lines[i : i + n])) for n in range(1, 5) for i in range(len(lines) - n + 1)})

    def likeness(other):
        return difflib.SequenceMatcher(None, text, other, autojunk=False).ratio()

    best = max(windows, key=likeness, default=None)
    return best if best in candidates and likeness(best) >= SAME_LINE else None


def judge(gate, found, baseline, args):
    original = {key[1:]: count for key, (count, _text) in baseline.items() if key[0] == gate}
    texts = {**{key[1:]: text for key, (_count, text) in baseline.items() if key[0] == gate}, **found.texts}
    allowed = dict(original)
    # an edited line keeps its finding: what a baselined text no longer uses moves to the text its line became
    for old in sorted(key for key in original if found.counts[key] < original[key] and key[0] in tracked()):
        new = {texts[key]: key for key in found.counts if key[:2] == old[:2] and found.counts[key] > allowed.get(key, 0)}
        text = successor(texts[old], new, source_lines(old[0])) if new else None
        if text:
            shift = min(allowed[old] - found.counts[old], found.counts[new[text]] - allowed.get(new[text], 0))
            allowed[old] -= shift
            allowed[new[text]] = allowed.get(new[text], 0) + shift
    # a run that builds only some packages cannot tell that a finding is gone, any more than a gate that cannot see all the code
    failures, grown, silent = 0, 0, blocked(found) or bool(args.pkgbuild)
    for key in sorted(set(found.counts) | set(allowed)):
        recorded = gate not in UNBASELINED_GATES and key[1] not in UNBASELINED_RULES
        have, limit = found.counts[key], allowed.get(key, 0) if recorded else 0
        if args.update and recorded and have == limit != original.get(key, 0):
            baseline[gate, *key] = (have, texts[key])
        # what a gate that cannot see all the code no longer finds is not news; the line that says why it cannot see is
        if have == limit or (silent and have < limit):
            continue
        if args.update and recorded and (have < limit or args.allow_growth):
            baseline[gate, *key] = (have, texts[key])
            continue
        failures += 1
        if have > limit:
            grown += recorded
            print("\n".join(found.details[key]))
            print(f"FAIL {gate}: {key[0]} {key[1]}: {have} found, the baseline allows {limit}: {texts[key]}")
        else:
            print(f"FAIL {gate}: {key[0]} {key[1]}: the baseline allows {limit} but only {have} remain; lower it with --update: {texts[key]}")
    if grown:
        print(f"     A new finding above: fix it, or record it with tests/gates/check.sh {gate} --update --allow-growth and give the reason on a line that starts with Gate-change: in a commit or the pull request body.")
    if not failures:
        print(f"ok   {gate}: nothing beyond the baseline ({sum(found.counts.values())} recorded)")
    return failures


def main():
    parser = argparse.ArgumentParser(description="Safety gates with a baseline that only shrinks.")
    parser.add_argument("gates", nargs="+", choices=[*GATES, "all"])
    parser.add_argument("--update", action="store_true", help="lower the baseline to what is found now")
    parser.add_argument("--allow-growth", action="store_true", help="with --update, also record new findings, which the pull request must justify")
    parser.add_argument("--rpms", nargs="*", default=[], help="for the rpm gate: the RPMs to audit, with their debuginfo")
    parser.add_argument("--pkgbuild", action="append", default=[], help="build only this PKGBUILD for the C++ gates, as attacks.py does for the package a case changes; CI builds every one")
    args = parser.parse_args()
    os.chdir(ROOT)
    baseline = parse_baseline(read(BASELINE)) if os.path.exists(BASELINE) else {}
    failures = 0
    for gate in [g for g in GATES if g != "rpm"] if "all" in args.gates else args.gates:
        found = Findings()
        GATES[gate](found, args)
        failures += judge(gate, found, baseline, args)
    if args.update:
        rows = sorted((*key, count, text) for key, (count, text) in baseline.items() if count)
        with open(BASELINE, "w", encoding="utf-8") as f:
            f.writelines("\t".join(map(str, row)) + "\n" for row in rows)
    sys.exit(1 if failures else 0)


main()

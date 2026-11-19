import argparse
import atexit
import collections
import concurrent.futures
import functools
import json
import os
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

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
UNBASELINED_RULES = {"build-failed", "tidy-failed", "not-built", "unattributed", "unlintable-shell", "pkgbuild-source"}
# what a file the gates cannot place by its suffix or its plugin is, so that none goes unchecked by default
CLASSES = {
    "sh": "shell script that sh runs or sources",
    "bash": "shell script that bash runs or sources",
    "python": "Python script",
    "lua": "Lua script",
    "pkgbuild": "makepkg build script; its package is built and audited",
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
WEAKENING_ATTRIBUTE = re.compile(r"\b(?:__)?(optimize|target|no_stack_protector|no_sanitize\w*|no_address_safety_analysis)(?:__)?\b")
NOLINT = re.compile(r"\bNOLINT(?:NEXTLINE|BEGIN|END)?\b")
REQUIRED_WARNINGS = ["all", "extra", "conversion", "shadow"]
# what Safety.cmake sets; glibc turns it into __USE_FORTIFY_LEVEL only when optimising
FORTIFY_LEVEL = 3
# glibc sends these to their __*_chk form whenever fortify is on, so a plain import is code fortify never saw
ALWAYS_FORTIFIED = {"printf", "fprintf", "vprintf", "vfprintf", "sprintf", "vsprintf", "vsnprintf", "dprintf", "vdprintf", "syslog", "vsyslog"}
SHIMMED = ("c++", "g++", "gcc", "cc")

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
]


class Findings:
    def __init__(self):
        self.counts = collections.Counter()
        self.details = collections.defaultdict(list)
        self.skipped = []

    def add(self, path, rule, detail, weight=1):
        self.counts[path, rule] += weight
        self.details[path, rule].append(detail)


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


def require(tool, package):
    pin = re.search(rf"^{re.escape(package)}==(\d+\.\d+\.\d+)", read(REQUIREMENTS), re.MULTILINE)
    if not pin:
        die(f"{REQUIREMENTS} does not pin {package}")
    found = run([tool, "--version"]).stdout if shutil.which(tool) else ""
    if not re.search(rf"(?<![\d.]){re.escape(pin.group(1))}(?![\d.])", found):
        die(f"{tool} {pin.group(1)} is required; install it with: python3 -m pip install -r {REQUIREMENTS}")


@functools.cache
def tracked():
    listed = run(["git", "ls-files", "--cached", "--others", "--exclude-standard"]).stdout.splitlines()
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
                found.add(path, "suppression", f"{path}:{number}: {line.strip()}")


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


def manifest():
    entries = {}
    for number, line in enumerate(read(MANIFEST).splitlines(), 1):
        fields = line.split("\t")
        if len(fields) != 2:
            die(f"{MANIFEST}:{number}: expected a path and a class separated by a tab")
        entries[fields[0]] = fields[1]
    return entries


def gated_dirs(files):
    return {os.path.dirname(p) for p in files if re.fullmatch(r"plugins/[^/]+/CMakeLists\.txt", p)}


def needs_class(path, gated):
    inside = any(path.startswith(d + "/") for d in gated)
    if os.path.basename(path) == "CMakeLists.txt":
        return os.path.dirname(path) not in gated
    return suffix(path) not in KNOWN_SUFFIXES or (path.lower().endswith(CPP_SUFFIXES) and not inside)


def gate_classify(found, _args):
    files, classes = tracked(), manifest()
    gated = gated_dirs(files)
    for path, kind in sorted(classes.items()):
        if path not in files:
            found.add(path, "missing", f"{path}: listed in {MANIFEST} but not in the tree")
        elif kind not in CLASSES:
            found.add(path, "invalid", f"{path}: unknown class '{kind}'; one of {', '.join(CLASSES)}")
        elif kind == "cpp-fixture" and not path.startswith("tests/gates/"):
            found.add(path, "invalid", f"{path}: only the gates' own fixtures under tests/gates are cpp-fixture")
    for path in sorted(files):
        if head_of(path).startswith(OBJECT_MAGIC):
            found.add(path, "binary", f"{path}: a committed object, library or executable; build it from source in a package instead")
        kind = classes.get(path)
        if kind is None:
            if needs_class(path, gated):
                found.add(path, "unclassified", f"{path}: add it to {MANIFEST} with one of: {', '.join(CLASSES)}")
            continue
        first = first_line(path)
        if kind in ("data", "make") and (first.startswith("#!") or os.stat(path).st_mode & stat.S_IXUSR):
            found.add(path, "code-marked-data", f"{path}: is listed as {kind} but has a shebang or the executable bit")
        spoken = language(first)
        if spoken and {"sh": "shell", "bash": "shell"}.get(kind, kind) != spoken:
            found.add(path, "language-differs", f"{path}: is listed as {kind} but its shebang is {first}")


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
                found.add(path, "unlintable-shell", f"{path}:{number}: %{current} runs {shell}, which no gate lints")
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
            found.add(path, "unlintable-shell", f"{path}: its shebang names a shell shellcheck cannot read; write it for sh or bash")
        else:
            batches[tuple(options)].append(path)
    batches["--shell=bash",] += sorted(p for p in files if p.endswith(".install"))
    batches["--shell=bash", f"--exclude={PKGBUILD_EXCLUDES}"] += sorted(p for p in files if os.path.basename(p) == "PKGBUILD")
    specs = sorted(p for p in files if p.endswith(".spec"))
    # shellcheck has no switch to ignore its inline directives, so it reads copies that have none
    copies = copies_of([p for paths in batches.values() for p in paths], per_line(without_disable))
    for path in specs:
        write(os.path.join(copies, path), without_disable(scriptlets(found, path)))
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
            found.add(c["file"], f"SC{c['code']}", f"{c['file']}:{c['line']}: SC{c['code']} {c['message']}")
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
        found.add(path, code, f"{path}:{d['location']['row']}: {code} {d['message']}")
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
            found.add(match[1], match[4], line)
    suppressions(found, paths, LUA_SUPPRESSION)


# ---------- C++: build each package the way it ships, with every compile and link recorded


def toolchain(found, what):
    missing = [tool for tool in ("makepkg", "cmake", "readelf", "c++", "fakeroot") if not shutil.which(tool)]
    if not missing:
        return True
    if os.environ.get("CI"):
        die(f"{', '.join(missing)} missing, and CI may not skip {what}")
    print(f"skipped: {', '.join(missing)} missing, so {what} was not built or checked")
    found.skipped.append(what)
    return False


def as_builder(argv):
    # makepkg will not run as root, and a build user cannot write the gate's own files
    return ["setpriv", "--reuid=65534", "--regid=65534", "--clear-groups", *argv] if os.geteuid() == 0 else argv


def handed_to_builder(path):
    if os.geteuid() == 0:
        for directory, _names, files in os.walk(path):
            for name in [".", *files]:
                os.chown(os.path.join(directory, name), 65534, 65534)


def shim(work):
    """Compiler wrappers for one build, and the directory its compiles and links are recorded in."""
    wrappers, records = os.path.join(work, "bin"), os.path.join(work, "records")
    os.makedirs(wrappers)
    os.makedirs(records)
    shutil.copy(SHIM, work)
    for name in SHIMMED:
        real = shutil.which(name)
        if not real:
            continue
        wrapper = os.path.join(wrappers, name)
        command = [sys.executable, "-I", os.path.join(work, "shim.py"), real, records]
        write(wrapper, f'#!/bin/sh\nexec {shlex.join(command)} "$@"\n')
        os.chmod(wrapper, 0o700)
    return wrappers, records


def records_in(directory):
    found = []
    for name in sorted(os.listdir(directory)):
        if name.endswith(".json"):
            with open(os.path.join(directory, name), encoding="utf-8") as f:
                found.append(json.load(f))
    return found


def srcinfo(pkgbuild, start, wrappers):
    result = run(as_builder(["makepkg", "--printsrcinfo"]), cwd=start, env=builder_env(start, wrappers))
    info = collections.defaultdict(list)
    for line in result.stdout.splitlines():
        key, sep, value = line.strip().partition(" = ")
        if sep:
            info[key].append(value)
    if not info.get("pkgbase"):
        die(f"makepkg cannot read {pkgbuild}: {result.stderr.strip()}")
    return info


def builder_env(home, wrappers, **extra):
    # nothing from the gate's own environment, so a build cannot behave differently under CI
    return {"PATH": f"{wrappers}:/usr/local/bin:/usr/bin:/bin", "HOME": home, "LANG": "C.UTF-8", **extra}


def makepkg_conf(work):
    conf = os.path.join(work, "makepkg.conf")
    write(
        conf,
        "source /etc/makepkg.conf\n"
        # the distribution's flags are emptied, so what is checked is what the repository itself asks for
        'CFLAGS="" CXXFLAGS="" CPPFLAGS="" LDFLAGS="" LTOFLAGS="" DEBUG_CFLAGS="" DEBUG_CXXFLAGS=""\n'
        f'MAKEFLAGS="-j{os.cpu_count()}"\n'
        "OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug !lto)\n"
        "BUILDENV=(!distcc !color !ccache !check !sign)\n"
        "PKGEXT=.pkg.tar\nSRCEXT=.src.tar\n",
    )
    return conf


class Package:
    def __init__(self, pkgbuild, work, info, result, records):
        self.pkgbuild, self.info, self.result, self.records = pkgbuild, info, result, records
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
    work = scratch()
    start = os.path.join(work, "start")
    os.makedirs(start)
    here = os.path.dirname(pkgbuild)
    for path in tracked():
        if os.path.dirname(path) == here:
            shutil.copy(path, start)
    wrappers, records = shim(work)
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
    env = builder_env(work, wrappers, BUILDDIR=os.path.join(work, "build"), PKGDEST=os.path.join(work, "out"), SRCDEST=start, **({"FIXTURE_BAD": case} if case else {}))
    command = ["makepkg", "--config", makepkg_conf(work), "--nodeps", "--skipinteg", "--nocheck", "--noconfirm", "--noprogressbar"]
    result = run(as_builder(command), cwd=start, env=env)
    return Package(pkgbuild, work, info, result, records_in(records))


def packages(found):
    if not toolchain(found, "the packages"):
        return []
    classes = manifest()
    return [package(p, "") for p in sorted(tracked()) if os.path.basename(p) == "PKGBUILD" and classes.get(p) == "pkgbuild"]


# ---------- the preprocessor's view of one compile


class Unit:
    """One compile the shim saw: its source, how GCC ran it, and what its preprocessed text shows."""

    def __init__(self, record, built):
        self.record, self.built = record, built
        compiles = [job for job in record["jobs"] if os.path.basename(job[0]) in ("cc1plus", "cc1")]
        self.cc1 = compiles[0] if compiles else []
        text = read(record["preprocessed"])
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
            found.add(left, "system-header-in-tree", f"{left}: compiled as a system header, so GCC hides its warnings")

    tracked_macros = {"_FORTIFY_SOURCE", "__USE_FORTIFY_LEVEL", "_GLIBCXX_ASSERTIONS", "NDEBUG"}
    origin = {}
    reported = set()

    def report(rule, detail):
        if rule not in reported:
            reported.add(rule)
            found.add(unit.name, rule, f"{unit.name}: {detail}")

    def check(at):
        level = macros.get("_FORTIFY_SOURCE")
        used = macros.get("__USE_FORTIFY_LEVEL")
        if not level or not level.isdigit() or int(level) < FORTIFY_LEVEL or (used is not None and (not used.isdigit() or int(used) < FORTIFY_LEVEL)):
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
        places[g] = (inside, number) if inside else None
        number += 1
    check("the end of the unit")
    while stack:
        leave()

    for rule, ok in (
        ("unoptimized", "__OPTIMIZE__" in builtins),
        ("stack-protector-off", "__SSP_STRONG__" in builtins or "__SSP_ALL__" in builtins),
        ("not-pic", "__PIC__" in builtins or "__PIE__" in builtins),
        ("cf-protection-off", platform.machine() != "x86_64" or builtins.get("__CET__") == "3"),
        ("stack-clash-off", last_switch(unit.cc1, "-fstack-clash-protection", "-fno-stack-clash-protection")),
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
            found.add(built.pkgbuild, f"warning-off:{flag}", f"{unit.name}: compiled with {flag}")

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
            found.add(place[0], "suppression: " + " ".join(raw[g].split()), f"{place[0]}:{place[1]}: {raw[g].strip()}")
    return {p for p in (place[0] for place in places if place)}


def scan(found, path, lines, seen):
    for number, code, raw in lines:
        pragma = PRAGMA.match(code)
        if not pragma or (path, number) in seen:
            continue
        seen.add((path, number))
        text = " ".join(raw.split())
        if pragma[2] in WEAKENING_PRAGMAS:
            found.add(path, f"source-weakens: #pragma {pragma[1]} {pragma[2]}", f"{path}:{number}: {text}")
        elif pragma[2] == "diagnostic" and pragma[3] in ("ignored", "warning"):
            found.add(path, f"suppression: {text}", f"{path}:{number}: {text}")
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
                found.add(path, f"source-weakens: attribute {name[1]}", f"{path}:{number}: {lines[index][2].strip()}")


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
                found.add(key, "unattributed", f"{key}: an archive in the package; the gate audits only ELF files it can trace to a compile")
                continue
            check_elf(found, key, path)
            build_id = re.search(r"Build ID:\s*(\w+)", run(["readelf", "-nW", path]).stdout)
            link = links_by_build_id.get(build_id[1]) if build_id else None
            # a build ID can be set by hand, so the code itself has to be what that link wrote
            code = run([sys.executable, "-I", SHIM, "--code-digest", path]).stdout.strip()
            if not link or link["link"]["code"] != code:
                found.add(key, "unattributed", f"{key}: no link this build ran made it (build ID {build_id[1] if build_id else 'missing'})")
                continue
            for unit in units_of(found, key, link, units_by_object):
                shipped.add(id(unit))
    return shipped


def units_of(found, key, link, units_by_object):
    own, inputs = link.get("unit"), link["link"]["inputs"]
    missing = [i for i in inputs if i.get("missing")]
    if missing and (not own or len(missing) != 1):
        found.add(key, "unattributed", f"{key}: links {len(missing)} temporary objects the gate cannot trace")
    elif own:
        yield own
    for entry in inputs:
        if entry.get("missing") or "sha256" not in entry:
            continue
        objects = entry.get("members", [entry]) if entry["kind"] in ("rel", "archive") else []
        if entry["kind"] in ("thin-archive", "exec") or (entry["kind"] == "archive" and not objects):
            found.add(key, "unattributed", f"{key}: links {entry['path']}, which the gate cannot trace to a compile")
        for obj in objects:
            unit = units_by_object.get(obj["sha256"])
            if obj.get("lto"):
                found.add(key, "unattributed", f"{key}: links LTO code from {entry['path']}; the gate sees only what each compile was asked for, not what LTO makes of it")
            elif unit:
                yield unit
            else:
                found.add(key, "unattributed", f"{key}: links {entry['path']} {obj.get('name', '')}, which no compile the gate saw produced".rstrip())


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
            found.add(key, rule, f"{key}: fails {rule}")
    for name in sorted(imports & ALWAYS_FORTIFIED):
        found.add(key, f"elf-unfortified:{name}", f"{key}: imports plain {name}, which fortify always replaces, so some code in it was built without fortify")


def analyse(found, built):
    """Shipped ELFs, the compiles behind them, and every compile of a tracked source."""
    if built.result.returncode != 0:
        found.add(built.pkgbuild, "build-failed", f"{built.pkgbuild}: makepkg failed\n{tail(built.result, built)}")
        return [], set()
    units, units_by_object, links = [], {}, {}
    for record in built.records:
        unit = Unit(record, built) if record.get("preprocessed") else None
        if unit:
            units.append(unit)
            for digest in (o["sha256"] for o in record.get("objects", {}).values()):
                units_by_object[digest] = unit
        if record.get("link", {}).get("build_id"):
            links[record["link"]["build_id"]] = {**record, "unit": unit}
    shipped = audit(found, built, units_by_object, links)
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
            found.add(where or built.pkgbuild, match[5] or "warning", f"{where or match[1]}:{match[2]}: {match[4]}")


@functools.cache
def harden_findings(pkgbuild, case):
    found = Findings()
    built = package(pkgbuild, case)
    return found, built, *analyse(found, built)


def gate_cpp_harden(found, _args):
    read_by = set()
    for built in packages(found):
        result, _built, _units, reads = harden_findings(built.pkgbuild, "")
        merge(found, result)
        read_by |= reads
    if not found.skipped:
        classes = manifest()
        for directory in sorted(gated_dirs(tracked())):
            for path in sorted(p for p in tracked() if p.startswith(directory + "/") and p.lower().endswith(CPP_SUFFIXES)):
                if path not in read_by and path not in classes:
                    found.add(path, "not-built", f"{path}: no package's build reads it; build it there, or list it in {MANIFEST}")


def merge(found, other):
    for key, count in other.counts.items():
        found.counts[key] += count
        found.details[key] += other.details[key]


def tidy_units(found, built, units):
    require("clang-tidy", "clang-tidy")
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
            found.add(unit.name, "tidy-failed", f"{unit.name}: clang-tidy stopped with status {report.returncode} and no compile error to show for it\n{tail(report, built)}")
        for line in lines:
            match = TIDY_LINE.match(line)
            where = built.place(match[1])
            if line in seen or not where:
                continue
            seen.add(line)
            found.add(where, match[5], f"{where}:{match[2]}: {match[4]} [{match[5]}]")


def gate_cpp_tidy(found, _args):
    for built in packages(found):
        _result, _built, units, _reads = harden_findings(built.pkgbuild, "")
        if units:
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
    wrappers, records = shim(work)
    build = os.path.realpath(os.path.join(work, "build"))
    env = {**os.environ, "PATH": f"{wrappers}:{os.environ.get('PATH', '/usr/bin')}"}
    result = run(["cmake", "-S", project, "-B", build, "-DCMAKE_BUILD_TYPE=RelWithDebInfo", "-DHYPR_DE_SANITIZE=ON", *options], env=env)
    if result.returncode == 0:
        result = run(["cmake", "--build", build, "--parallel"], env=env)
    if result.returncode != 0:
        found.add(project, "build-failed", f"{project}: the sanitizer build failed\n{tail(result)}")
        return
    for record in records_in(records):
        if not record.get("preprocessed"):
            continue
        compiles = [job for job in record["jobs"] if os.path.basename(job[0]) in ("cc1plus", "cc1")]
        on, recovers = sanitizers(compiles[0] if compiles else [])
        source = LINEMARKER.match(read(record["preprocessed"]).split("\n", 1)[0])
        name = os.path.relpath(os.path.realpath(os.path.join(record["cwd"], unescape(source[2])))) if source else project
        if name in tracked() and (not {"address", "undefined"} <= on or recovers):
            found.add(name, "sanitizer-off", f"{name}: built with sanitizers {sorted(on)}{' that recover' if recovers else ''}")
    tests = run(["ctest", "--test-dir", build, "--output-on-failure", "--no-tests=error"], env=env)
    if "No tests were found" in tests.stdout + tests.stderr:
        found.add(project, "no-tests", f"{project}: registers no test with add_test, so nothing ran under the sanitizers")
    elif tests.returncode != 0:
        found.add(project, "tests-failed", f"{project}: tests failed under ASan and UBSan\n{tail(tests)}")


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
        if (path, rule) not in results[case, gate]:
            found.add(FIXTURE, f"missed:{case}", f"{gate} did not report {rule} at {path} for the fixture's {case} case; it reported {sorted(results[case, gate])}")
    for key in results["", "cpp-harden"]:
        found.add(FIXTURE, "clean-reported", f"cpp-harden reported {key} for the clean fixture, which has none")


def parse_baseline(text):
    entries = {}
    for line in text.splitlines():
        gate, path, rule, count = line.split("\t")
        entries[gate, path, rule] = int(count)
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
}


def judge(gate, found, baseline, args):
    allowed = {key[1:]: count for key, count in baseline.items() if key[0] == gate}
    failures = 0
    if found.skipped:
        print(f"skipped {gate}: {', '.join(found.skipped)}")
        return 0
    for key in sorted(set(found.counts) | set(allowed)):
        recorded = gate not in UNBASELINED_GATES and key[1] not in UNBASELINED_RULES
        have, limit = found.counts[key], allowed.get(key, 0) if recorded else 0
        if have == limit:
            continue
        if args.update and recorded and (have < limit or args.allow_growth):
            baseline[gate, *key] = have
            continue
        failures += 1
        if have > limit:
            print("\n".join(found.details[key]))
            print(f"FAIL {gate}: {key[0]} {key[1]}: {have} found, the baseline allows {limit}")
        else:
            print(f"FAIL {gate}: {key[0]} {key[1]}: the baseline allows {limit} but only {have} remain; lower it with --update")
    if not failures:
        print(f"ok   {gate}: nothing beyond the baseline ({sum(found.counts.values())} recorded)")
    return failures


def main():
    parser = argparse.ArgumentParser(description="Safety gates with a baseline that only shrinks.")
    parser.add_argument("gates", nargs="+", choices=[*GATES, "all"])
    parser.add_argument("--update", action="store_true", help="lower the baseline to what is found now")
    parser.add_argument("--allow-growth", action="store_true", help="with --update, also record new findings, which the pull request must justify")
    parser.add_argument("--tree", default=ROOT, help="judge this checkout with these gates; CI judges a pull request with its base branch's gates")
    args = parser.parse_args()
    os.chdir(os.path.realpath(args.tree))
    baseline = parse_baseline(read(BASELINE)) if os.path.exists(BASELINE) else {}
    failures = 0
    for gate in GATES if "all" in args.gates else args.gates:
        found = Findings()
        GATES[gate](found, args)
        failures += judge(gate, found, baseline, args)
    if args.update:
        rows = sorted((*key, count) for key, count in baseline.items() if count)
        with open(BASELINE, "w", encoding="utf-8") as f:
            f.writelines("\t".join(map(str, row)) + "\n" for row in rows)
    sys.exit(1 if failures else 0)


main()

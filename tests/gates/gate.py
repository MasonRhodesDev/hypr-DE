import argparse
import atexit
import collections
import concurrent.futures
import json
import os
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASELINE = "tests/gates/baseline.tsv"
MANIFEST = "tests/gates/classified.tsv"
REQUIREMENTS = "tests/gates/requirements.txt"
SHELLCHECK_RC = ".shellcheckrc"
RUFF_CONFIG = "ruff.toml"
LUACHECK_RC = ".luacheckrc"
LUACHECK = "1.2.0"
TIDY_CONFIG = "plugins/.clang-tidy"
FIXTURE = "tests/gates/cpp-fixture"
FIXTURE_SIBLING = "tests/gates/cpp-fixture-sibling/sibling.hpp"

# a finding from these gates, or under these rules, is never recorded in the baseline, so it always fails
UNBASELINED_GATES = {"cpp-selftest", "classify"}
UNBASELINED_RULES = {"build-failed", "tidy-failed", "not-built"}
# what a file the gates cannot place by its suffix or its plugin is, so that none goes unchecked by default
CLASSES = {
    "sh": "shell script that sh runs or sources",
    "bash": "shell script that bash runs or sources",
    "python": "Python script",
    "pkgbuild": "makepkg build script",
    "make": "Makefile",
    "data": "read, never run",
    "cpp-test": "C or C++ that only a test script builds; never shipped",
    "cpp-fixture": "C or C++ the gates build to test themselves",
}

SHELL_SHEBANG = re.compile(r"^#!.*?(?<![\w.-])(?:ba|da|a|k)?sh(?![\w.-])")
SHELL_SUFFIXES = (".sh", ".bash")
PYTHON_SHEBANG = re.compile(r"^#!.*\bpython")
# makepkg assigns srcdir and pkgdir and reads pkgname and the rest itself, so shellcheck sees neither side
PKGBUILD_EXCLUDES = "SC2034,SC2154"
SHELLCHECK_DIRECTIVE = re.compile(r"#\s*shellcheck\s+([^#\n]*\bdisable=[^#\n]*)(?:#.*)?")
# written in two parts so that this line is not a suppression by its own rule
PYTHON_SUPPRESSION = re.compile(r"#.*\b(?:no" + r"qa|ruff\s*:)", re.IGNORECASE)
LUA_SUPPRESSION = re.compile(r"--.*\bluacheck\s*:")
CPP_SUFFIXES = (".c", ".cc", ".cpp", ".cxx", ".c++", ".h", ".hh", ".hpp", ".hxx", ".h++", ".inc", ".inl", ".ipp", ".tpp", ".tcc", ".ixx", ".cppm")
# source that turns off a hardening flag, assertions or optimisation-dependent checks for what follows it
SOURCE_WEAKENING = re.compile(
    r"^\s*(?:#|%:|\?\?=)\s*(?:undef\s+(?:_GLIBCXX_ASSERTIONS|_FORTIFY_SOURCE)|define\s+(?:NDEBUG|_FORTIFY_SOURCE))\b"
    r"|(?:#|%:|\?\?=)\s*pragma\s+GCC\s+(?:optimize|push_options|target)\b|_Pragma\s*\(\s*\"GCC\s+optimize"
    r"|\b(?:__attribute__\s*\(\(\s*|(?:gnu|__gnu__)::)(?:__)?optimize(?:__)?\b"
)
CONFIGURE_CONTENT = re.compile(r"""\bfile\s*\(\s*CONFIGURE\b.*?\bCONTENT\s+(?:"((?:[^"\\]|\\.)*)"|\[(=*)\[(.*?)\]\2\])""", re.DOTALL | re.IGNORECASE)
CONFIGURE_FILE = re.compile(r"""\bconfigure_file\s*\(\s*"?([^\s)"]+)""", re.IGNORECASE)
CPP_SUPPRESSION = re.compile(
    r"NOLINT|(?:#|%:|\?\?=)\s*pragma\s+(?:GCC|clang)\b|_Pragma\b|\bno_sanitize|\bno_stack_protector\b|\bsystem_header\b|^\s*(?:#|%:)\s*(?:line\b|\d)"
)

HARDENING_FLAGS = ["-Wall", "-Wextra", "-Wconversion", "-Wshadow", "-fstack-protector-strong", "-fstack-clash-protection", "-D_GLIBCXX_ASSERTIONS"]
REQUIRED_FLAGS = {
    "harden": [*HARDENING_FLAGS, "-D_FORTIFY_SOURCE=3"],
    # fortify hides overflows from AddressSanitizer, so Safety.cmake leaves it out of this build
    "sanitize": [*HARDENING_FLAGS, "-fsanitize=address,undefined", "-fno-sanitize-recover=all"],
}
WEAKENING_FLAG = re.compile(
    r"-Wno-.+|-w|-fpermissive|-O0|-fno-stack-protector|-fstack-protector(?:-explicit)?|-fno-stack-clash-protection|-fcf-protection=none"
    r"|-fno-sanitize=.*|-fsanitize-recover(?:=.*)?|-U_GLIBCXX_ASSERTIONS|-D_GLIBCXX_ASSERTIONS=.*"
)
WEAKENING_SAMPLES = [
    "#undef _GLIBCXX_ASSERTIONS",
    "  %:  undef _FORTIFY_SOURCE",
    "#define NDEBUG",
    "#define _FORTIFY_SOURCE 1",
    '__attribute__((optimize("O0"))) int f();',
    '[[gnu::optimize("O0")]] int g();',
    '#pragma GCC optimize("O0")',
    '_Pragma("GCC optimize(\\"O0\\")")',
    "#pragma GCC push_options",
]
TEMPLATE_SAMPLE = {
    "CMakeLists.txt": 'file(CONFIGURE OUTPUT a.hpp CONTENT "#pragma GCC diagnostic ignored \\"-Wshadow\\"\n")\n'
    "file(CONFIGURE OUTPUT b.hpp CONTENT [=[\n#undef _FORTIFY_SOURCE\n]=])\nconfigure_file(c.h.in c.h)\n",
    "c.h.in": "#define NDEBUG\n",
}
COMPILER_WARNING = re.compile(r"^(.+?):(\d+):(\d+): warning: (.*?)(?: \[(-W[^\]]+)\])?$")
TIDY_LINE = re.compile(r"^(.+?):(\d+):(\d+): (?:warning|error): (.*) \[([\w.,-]+)\]$")
LUACHECK_LINE = re.compile(r"^(.+?):(\d+):(\d+): \((\w+)\) (.*)$")
SELFTEST = [
    ("WARNING", "cpp-harden", f"{FIXTURE}/src/fixture.cpp", "-Wconversion"),
    ("NOWARN", "cpp-harden", FIXTURE, "flag-weakens:-Wno-conversion"),
    ("WEAKSTACK", "cpp-harden", FIXTURE, "flag-weakens:-fstack-protector"),
    ("NOASSERT", "cpp-harden", FIXTURE, "flag-weakens:-U_GLIBCXX_ASSERTIONS"),
    ("NOSAFETY", "cpp-harden", FIXTURE, "flag-missing:-fstack-protector-strong"),
    ("GENERATED", "cpp-harden", f"{FIXTURE}/@build/generated/generated.hpp", 'suppression: #pragma GCC diagnostic ignored "-Wconversion"'),
    ("TEMPLATE", "cpp-tidy", f"{FIXTURE}/@build/generated/template.hpp", "cppcoreguidelines-pro-type-reinterpret-cast"),
    ("SIBLING", "cpp-harden", FIXTURE_SIBLING, "-Wconversion"),
    ("OVERFLOW", "cpp-sanitize", FIXTURE, "tests-failed"),
    ("UNDEFINED", "cpp-sanitize", FIXTURE, "tests-failed"),
    ("NOSANITIZE", "cpp-sanitize", FIXTURE, "flag-weakens:-fno-sanitize=all"),
    ("TIDY", "cpp-tidy", f"{FIXTURE}/src/fixture.cpp", "cppcoreguidelines-pro-type-reinterpret-cast"),
    ("SIBLING", "cpp-tidy", FIXTURE_SIBLING, "bugprone-narrowing-conversions"),
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


def tracked():
    listed = run(["git", "ls-files", "--cached", "--others", "--exclude-standard"]).stdout.splitlines()
    files = [p for p in listed if os.path.isfile(p) and not os.path.islink(p)]
    if not files:
        die("git lists no files; run the gates from a checkout")
    return files


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
        copy = os.path.join(copies, path)
        os.makedirs(os.path.dirname(copy), exist_ok=True)
        with open(copy, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.writelines(rewrite(line) for line in read(path).splitlines(keepends=True))
    return copies


def suppressions(found, paths, directive):
    for path in paths:
        for number, line in numbered(path):
            if directive.search(line):
                found.add(path, "suppression", f"{path}:{number}: {line.strip()}")


def head_of(path):
    with open(path, "rb") as f:
        return f.read(4096).decode("utf-8", "replace")


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
    name = os.path.basename(path)
    inside = any(path.startswith(d + "/") for d in gated)
    return "." not in name or (name == "CMakeLists.txt" and os.path.dirname(path) not in gated) or (path.lower().endswith(CPP_SUFFIXES) and not inside)


def gate_classify(found, _args):
    files, classes = tracked(), manifest()
    gated = gated_dirs(files)
    for path, kind in sorted(classes.items()):
        if path not in files:
            found.add(path, "missing", f"{path}: listed in {MANIFEST} but not in the tree")
        elif kind not in CLASSES:
            found.add(path, "invalid", f"{path}: unknown class '{kind}'; one of {', '.join(CLASSES)}")
    for path in files:
        kind = classes.get(path)
        if kind is None:
            if needs_class(path, gated):
                found.add(path, "unclassified", f"{path}: add it to {MANIFEST} with one of: {', '.join(CLASSES)}")
            continue
        first = head_of(path).split("\n", 1)[0]
        if kind in ("data", "make") and (first.startswith("#!") or os.stat(path).st_mode & stat.S_IXUSR):
            found.add(path, "code-marked-data", f"{path}: is listed as {kind} but has a shebang or the executable bit")
        shebang = "sh" if SHELL_SHEBANG.match(first) else "python" if PYTHON_SHEBANG.match(first) else None
        if shebang and {"sh": "bash"}.get(kind, kind) != {"sh": "bash"}.get(shebang, shebang):
            found.add(path, "language-differs", f"{path}: is listed as {kind} but its shebang is {first}")


def shell_scripts(files, classes):
    for path in files:
        head = head_of(path)
        first = head.split("\n", 1)[0]
        if path.endswith(SHELL_SUFFIXES) or SHELL_SHEBANG.match(first):
            yield path, []
        elif first.startswith("#!") or "\0" in head or path.endswith(".install") or os.path.basename(path) == "PKGBUILD":
            continue
        elif classes.get(path) in ("sh", "bash"):
            yield path, [f"--shell={classes[path]}"]
        elif re.search(r"#\s*shellcheck\s+shell=", head):
            yield path, []
        elif os.stat(path).st_mode & stat.S_IXUSR:
            # an executable file with no shebang is run by a shell, and every shell reads sh
            yield path, ["--shell=sh"]


def gate_shell(found, _args):
    require("shellcheck", "shellcheck-py")
    files = tracked()
    batches = collections.defaultdict(list)
    for path, options in shell_scripts(files, manifest()):
        batches[tuple(options)].append(path)
    batches["--shell=bash",] += [p for p in files if p.endswith(".install")]
    batches["--shell=bash", f"--exclude={PKGBUILD_EXCLUDES}"] += [p for p in files if os.path.basename(p) == "PKGBUILD"]
    # shellcheck has no switch to ignore its inline directives, so it reads copies that have none
    copies = copies_of([p for paths in batches.values() for p in paths], without_disable)
    pinned = [f"--rcfile={os.path.join(ROOT, SHELLCHECK_RC)}", "--format=json1"]
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
    paths = [p for p in tracked() if p.endswith(".py") or PYTHON_SHEBANG.match(head_of(p)) or classes.get(p) == "python"]
    # one config for every file and no inline suppression, so a nested config or a comment cannot change the result
    result = run(["ruff", "check", "--no-cache", "--config", RUFF_CONFIG, "--ignore-noqa", "--output-format=json", *paths])
    try:
        diagnostics = json.loads(result.stdout)
    except ValueError:
        die(f"ruff gave no report: {result.stderr.strip()}")
    for d in diagnostics:
        path = os.path.relpath(d["filename"], ROOT)
        code = d["code"] or "invalid-syntax"
        found.add(path, code, f"{path}:{d['location']['row']}: {code} {d['message']}")
    suppressions(found, paths, PYTHON_SUPPRESSION)


def gate_lua(found, _args):
    version = run(["luacheck", "--version"]).stdout if shutil.which("luacheck") else ""
    if f"Luacheck: {LUACHECK}" not in version:
        die(f"luacheck {LUACHECK} is required; the CI workflow shows where to get it")
    paths = [p for p in tracked() if p.endswith(".lua")]
    # luacheck has no switch to ignore inline options, and it applies a config's per-directory rules relative to the config
    copies = copies_of(paths, without_luacheck)
    shutil.copy(LUACHECK_RC, copies)
    result = run(["luacheck", "--config", LUACHECK_RC, "--no-default-config", "--formatter=plain", "--codes", "--no-color", *paths], cwd=copies)
    if result.returncode > 2:
        die(f"luacheck could not run: {result.stdout.strip()} {result.stderr.strip()}")
    for line in result.stdout.splitlines():
        match = LUACHECK_LINE.match(line)
        if match:
            found.add(match[1], match[4], line)
    suppressions(found, paths, LUA_SUPPRESSION)


def cpp_projects(found):
    plugins = sorted(os.path.dirname(p) for p in tracked() if re.fullmatch(r"plugins/[^/]+/CMakeLists\.txt", p))
    wants_hyprland = re.compile(r"pkg_check_modules\s*\([^)]*\bhyprland\b")
    have_hyprland = shutil.which("pkg-config") and run(["pkg-config", "--exists", "hyprland"]).returncode == 0
    for project in [*plugins, FIXTURE]:
        if have_hyprland or not wants_hyprland.search(read(os.path.join(project, "CMakeLists.txt"))):
            yield project
        elif os.environ.get("CI"):
            die(f"{project} needs Hyprland's headers, and CI may not skip it")
        else:
            print(f"skipped: no Hyprland headers, so {project} was not built or checked")
            found.skipped.append(project)


def packaged(project):
    options, env = [], {}
    for path in sorted(p for p in tracked() if os.path.basename(p) == "PKGBUILD"):
        for line in read(path).replace("\\\n", " ").splitlines():
            try:
                words = shlex.split(line, comments=True)
            except ValueError:
                continue
            if "cmake" not in words:
                continue
            command = words[words.index("cmake") :]
            if "-S" in command[:-1] and os.path.normpath(command[command.index("-S") + 1]) == project:
                options += [w for w in command if w.startswith("-D")]
                env.update(w.split("=", 1) for w in words[: words.index("cmake")] if "=" in w)
    return options, env


def configure(project, *options, env=None):
    for tool in ("cmake", "c++"):
        if not shutil.which(tool):
            die(f"{tool} is required for the C++ gates")
    # the fixture copies its stand-in for a third-party header next to the build directory, so both go under one scratch
    build = os.path.join(scratch(), "build")
    command = ["cmake", "-S", project, "-B", build, "-DCMAKE_BUILD_TYPE=RelWithDebInfo", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"]
    return build, run([*command, *options], env={**os.environ, **(env or {})})


def tail(result):
    lines = (result.stdout + result.stderr).replace(ROOT + "/", "").splitlines()
    headlines = [line for line in lines[:-25] if re.search(r"ERROR: \w+Sanitizer|runtime error:|\berror:", line)]
    return "\n".join([*headlines[:10], *lines[-25:]])


def in_repo(path):
    relative = os.path.relpath(os.path.realpath(path), ROOT)
    return None if relative.startswith("..") else relative


def translation_units(build):
    with open(os.path.join(build, "compile_commands.json"), encoding="utf-8") as f:
        units = json.load(f)
    return [(in_repo(u["file"]), shlex.split(u["command"])) for u in units if in_repo(u["file"])]


def check_flags(found, project, build, mode):
    required = [*REQUIRED_FLAGS[mode], *(["-fcf-protection"] if platform.machine() in ("x86_64", "i686") else [])]
    units = translation_units(build)
    if not units:
        found.add(project, "no-sources", f"{project}: the build compiles nothing from this repository")
    for path, flags in units:
        for flag in required:
            if flag not in flags:
                found.add(project, f"flag-missing:{flag}", f"{path}: compiled without {flag}")
        if "-fPIC" not in flags and "-fPIE" not in flags:
            found.add(project, "flag-missing:-fPIC", f"{path}: compiled without -fPIC or -fPIE")
        fortified = max((i for i, flag in enumerate(flags) if flag == "-D_FORTIFY_SOURCE=3"), default=-1)
        for i, flag in enumerate(flags):
            undone = i > fortified and re.match(r"-[DU]_FORTIFY_SOURCE", flag)
            if WEAKENING_FLAG.fullmatch(flag) or undone:
                found.add(project, f"flag-weakens:{flag}", f"{path}: compiled with {flag}")


def check_warnings(found, project, build, output):
    seen = set()
    for line in output.splitlines():
        match = COMPILER_WARNING.match(line)
        if not match or match.groups() in seen:
            continue
        seen.add(match.groups())
        path = os.path.join(build, match[1])
        # a warning in a header outside the repository still comes from code in the project
        where = in_repo(path) or project
        found.add(where, match[5] or "warning", f"{in_repo(path) or os.path.normpath(path)}:{match[2]}: {match[4]}")


# the build directory is random, so a file written into it is named by its place under the build
def generated(build, path):
    relative = os.path.relpath(os.path.realpath(path), os.path.realpath(build))
    if relative.startswith("..") or relative.split(os.sep)[0] == "CMakeFiles":
        return None
    return relative


def read_by(project, build):
    for directory, _names, files in os.walk(build):
        for name in files:
            if name.endswith(".d"):
                words = read(os.path.join(directory, name)).replace("\\\n", " ").split()
                for word in words:
                    path = os.path.join(build, word)
                    if word.endswith(":"):
                        continue
                    if in_repo(path):
                        yield in_repo(path), path
                    elif generated(build, path):
                        yield os.path.join(project, "@build", generated(build, path)), path


def check_lines(found, path, lines):
    for number, line in lines:
        # the whole line is the rule, so widening a recorded suppression is a new line in the baseline
        if CPP_SUPPRESSION.search(line):
            found.add(path, "suppression: " + " ".join(line.split()), f"{path}:{number}: {line.strip()}")
        for match in SOURCE_WEAKENING.finditer(line):
            found.add(path, "source-weakens: " + " ".join(match[0].split()), f"{path}:{number}: {line.strip()}")


def templates(path):
    text = read(path)
    for match in CONFIGURE_CONTENT.finditer(text):
        body, start = (match[1], match.start(1)) if match[1] is not None else (match[3], match.start(3))
        first = text.count("\n", 0, start) + 1
        yield None, [(first + i, line) for i, line in enumerate(body.splitlines())]
    for match in CONFIGURE_FILE.finditer(text):
        source = os.path.normpath(os.path.join(os.path.dirname(path), match[1].replace("${CMAKE_CURRENT_SOURCE_DIR}/", "")))
        yield source, None


def check_sources(found, sources, cmake_files):
    for name, path in sorted(sources.items()):
        check_lines(found, name, numbered(path))
    for path in cmake_files:
        for source, lines in templates(path):
            if lines:
                check_lines(found, path, lines)
            elif os.path.isfile(source) and source not in sources:
                check_lines(found, source, numbered(source))


def elf_files(build):
    for directory, names, files in os.walk(build):
        names[:] = [n for n in names if n != "CMakeFiles"]
        for name in files:
            path = os.path.join(directory, name)
            with open(path, "rb") as f:
                if f.read(4) == b"\x7fELF":
                    yield path


def check_elf(found, project, build):
    if not shutil.which("readelf"):
        die("readelf is required for the C++ gates")
    binaries = list(elf_files(build))
    if not binaries:
        found.add(project, "no-binaries", f"{project}: the build links nothing")
    for path in binaries:
        name = os.path.basename(path)
        header = run(["readelf", "-hW", path]).stdout
        segments = run(["readelf", "-lW", path]).stdout
        dynamic = run(["readelf", "-dW", path]).stdout
        notes = run(["readelf", "-nW", path]).stdout
        stack = re.search(r"GNU_STACK.*?\b(R?W?E?)\s+0x\w+\s*$", segments, re.MULTILINE)
        problems = {
            "elf-not-pie": re.search(r"Type:\s+EXEC", header),
            "elf-no-relro": "GNU_RELRO" not in segments,
            "elf-lazy-binding": not re.search(r"BIND_NOW|Flags:.*\bNOW\b", dynamic),
            "elf-executable-stack": not stack or "E" in stack[1],
            "elf-no-cet": platform.machine() == "x86_64" and not re.search(r"x86 feature: .*IBT.*SHSTK", notes),
        }
        for rule, hit in problems.items():
            if hit:
                found.add(project, rule, f"{project}: {name} fails {rule}")
    return binaries


def built(found, project, mode, *options, env=None):
    build, result = configure(project, *options, env=env)
    if result.returncode == 0:
        check_flags(found, project, build, mode)
        result = run(["cmake", "--build", build, "--parallel"])
    if result.returncode != 0:
        found.add(project, "build-failed", f"{project}: the {mode} build failed\n{tail(result)}")
        return None, result
    return build, result


def harden(found, project, *options):
    # the build a package ships, with nothing injected, is the one that is checked
    package_options, env = packaged(project)
    build, result = built(found, project, "harden", *package_options, *options, env=env)
    if not build:
        return [], {}
    check_warnings(found, project, build, result.stdout + result.stderr)
    return check_elf(found, project, build), dict(read_by(project, build))


def sanitize(found, project, *options):
    build, _result = built(found, project, "sanitize", "-DHYPR_DE_SANITIZE=ON", *options)
    if not build:
        return
    tests = run(["ctest", "--test-dir", build, "--output-on-failure", "--no-tests=error"])
    if "No tests were found" in tests.stdout + tests.stderr:
        found.add(project, "no-tests", f"{project}: registers no test with add_test, so nothing ran under the sanitizers")
    elif tests.returncode != 0:
        found.add(project, "tests-failed", f"{project}: tests failed under ASan and UBSan\n{tail(tests)}")


def tidy(found, project, *options):
    require("clang-tidy", "clang-tidy")
    build, result = configure(project, *options)
    if result.returncode != 0:
        found.add(project, "build-failed", f"{project}: could not configure for clang-tidy\n{tail(result)}")
        return
    # a header the build writes from a template in this repository is checked like one in the tree
    headers = f"^({re.escape(ROOT)}|{re.escape(os.path.realpath(build))})/"
    command = ["clang-tidy", "-p", build, f"--config-file={TIDY_CONFIG}", f"--header-filter={headers}", "--quiet"]
    # the compile commands are GCC's, and clang must not fail on a warning flag only GCC has
    command += ["--extra-arg=-Wno-unknown-warning-option", "--extra-arg=-Wno-error"]
    paths = [path for path, _flags in translation_units(build)]
    with concurrent.futures.ThreadPoolExecutor(os.cpu_count()) as pool:
        reports = list(pool.map(lambda path: run([*command, path]), paths))
    seen = set()
    for path, report in zip(paths, reports, strict=True):
        lines = [line for line in report.stdout.splitlines() if TIDY_LINE.match(line)]
        if report.returncode != 0 and not any("clang-diagnostic-error" in line for line in lines):
            found.add(path, "tidy-failed", f"{path}: clang-tidy stopped with status {report.returncode} and no compile error to show for it\n{tail(report)}")
        for line in lines:
            match = TIDY_LINE.match(line)
            where = in_repo(match[1]) or (generated(build, match[1]) and os.path.join(project, "@build", generated(build, match[1])))
            if line in seen or not where:
                continue
            seen.add(line)
            found.add(where, match[5], f"{where}:{match[2]}: {match[4]} [{match[5]}]")


def gate_cpp_harden(found, _args):
    # a file with no C++ suffix still counts once a build reads it
    sources = {p: p for p in tracked() if p.lower().endswith(CPP_SUFFIXES)}
    classes, built_by = manifest(), {}
    for project in cpp_projects(found):
        built_by[project] = harden(found, project)[1]
        sources |= built_by[project]
    for project, reads in built_by.items():
        for path in sorted(p for p in sources if p.startswith(project + "/") and "/@build/" not in p):
            if path not in reads and path not in classes:
                found.add(path, "not-built", f"{path}: {project}'s build does not read it; build it there, or list it in {MANIFEST}")
    check_sources(found, sources, sorted(p for p in tracked() if os.path.basename(p) == "CMakeLists.txt" or p.endswith(".cmake")))


def gate_cpp_sanitize(found, _args):
    for project in cpp_projects(found):
        sanitize(found, project)


def gate_cpp_tidy(found, _args):
    for project in cpp_projects(found):
        tidy(found, project)


def gate_cpp_selftest(found, _args):
    runners = {"cpp-harden": harden, "cpp-sanitize": sanitize, "cpp-tidy": tidy}

    def caught(case, gate, _path, _rule):
        findings = Findings()
        result = runners[gate](findings, FIXTURE, f"-DFIXTURE_BAD={case}")
        if gate == "cpp-harden":
            check_sources(findings, result[1], [])
        return findings.counts

    with concurrent.futures.ThreadPoolExecutor(os.cpu_count()) as pool:
        results = list(pool.map(lambda entry: caught(*entry), SELFTEST))
    for (case, gate, path, rule), counts in zip(SELFTEST, results, strict=True):
        if (path, rule) not in counts:
            found.add(FIXTURE, f"missed:{case}", f"{gate} did not report {rule} at {path} for the fixture's {case} case")
    for sample in WEAKENING_SAMPLES:
        findings = Findings()
        check_lines(findings, "sample", [(1, sample)])
        if not any(rule.startswith("source-weakens: ") for _path, rule in findings.counts):
            found.add(FIXTURE, "missed:source-weakens", f"cpp-harden did not report {sample!r} as weakening")
    sample = scratch()
    for name, text in TEMPLATE_SAMPLE.items():
        with open(os.path.join(sample, name), "w", encoding="utf-8") as f:
            f.write(text)
    findings = Findings()
    check_sources(findings, {}, [os.path.join(sample, "CMakeLists.txt")])
    if sorted(rule.partition(":")[0] for _path, rule in findings.counts) != ["source-weakens", "source-weakens", "suppression"]:
        found.add(FIXTURE, "missed:templates", f"cpp-harden read the template sample as {sorted(findings.counts)}")
    clean = Findings()
    for binary in harden(clean, FIXTURE)[0]:
        if "__stack_chk_fail" not in run(["readelf", "-sW", "--dyn-syms", binary]).stdout:
            found.add(FIXTURE, "missed:stack-protector", f"{os.path.basename(binary)} has no stack protector")


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
    for key in sorted(set(found.counts) | set(allowed)):
        if any(key[0] == project or key[0].startswith(project + "/") for project in found.skipped):
            continue
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
    args = parser.parse_args()
    os.chdir(ROOT)
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

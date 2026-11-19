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
REQUIREMENTS = "tests/gates/requirements.txt"
SHELLCHECK_RC = ".shellcheckrc"
RUFF_CONFIG = "ruff.toml"
LUACHECK_RC = ".luacheckrc"
LUACHECK = "1.2.0"
SAFETY = "plugins/cmake/Safety.cmake"
TIDY_CONFIG = "plugins/.clang-tidy"
FIXTURE = "tests/gates/cpp-fixture"
FIXTURE_SIBLING = "tests/gates/cpp-fixture-sibling/sibling.hpp"

# a finding from these gates, or under these rules, is never recorded in the baseline, so it always fails
UNBASELINED_GATES = {"cpp-selftest"}
UNBASELINED_RULES = {"build-failed", "tidy-failed"}

SHELL_SHEBANG = re.compile(r"^#!.*?(?<![\w.-])(?:ba|da|a|k)?sh(?![\w.-])")
SHELL_SUFFIXES = (".sh", ".bash")
SHELL_CONTENT = re.compile(r"^\s*(?:export\s+\w+=|set\s+-[a-zA-Z]|\w+\s*\(\)\s*\{|(?:if|while)\s+\[|(?:fi|done|esac)\s*$)", re.MULTILINE)
# the suffix says what a file is, and a Makefile exports variables the way a shell does
NAMED_OTHERWISE = re.compile(r"(?:^|/)(?:[^/]*\.[^/]*|Makefile)$")
PYTHON_SHEBANG = re.compile(r"^#!.*\bpython")
# makepkg assigns srcdir and pkgdir and reads pkgname and the rest itself, so shellcheck sees neither side
PKGBUILD_EXCLUDES = "SC2034,SC2154"
SHELLCHECK_DIRECTIVE = re.compile(r"#\s*shellcheck\s+([^#\n]*\bdisable=[^#\n]*)(?:#.*)?")
# written in two parts so that this line is not a suppression by its own rule
PYTHON_SUPPRESSION = re.compile(r"#.*\b(?:no" + r"qa|ruff\s*:)", re.IGNORECASE)
LUA_SUPPRESSION = re.compile(r"--.*\bluacheck\s*:")
CPP_SUFFIXES = (".c", ".cc", ".cpp", ".cxx", ".c++", ".h", ".hh", ".hpp", ".hxx", ".h++", ".inc", ".inl", ".ipp", ".tpp", ".tcc", ".ixx", ".cppm")
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
COMPILER_WARNING = re.compile(r"^(.+?):(\d+):(\d+): warning: (.*?)(?: \[(-W[^\]]+)\])?$")
TIDY_LINE = re.compile(r"^(.+?):(\d+):(\d+): (?:warning|error): (.*) \[([\w.,-]+)\]$")
LUACHECK_LINE = re.compile(r"^(.+?):(\d+):(\d+): \((\w+)\) (.*)$")
SELFTEST = [
    ("WARNING", "cpp-harden", f"{FIXTURE}/src/fixture.cpp", "-Wconversion"),
    ("NOWARN", "cpp-harden", FIXTURE, "flag-weakens:-Wno-conversion"),
    ("WEAKSTACK", "cpp-harden", FIXTURE, "flag-weakens:-fstack-protector"),
    ("NOASSERT", "cpp-harden", FIXTURE, "flag-weakens:-U_GLIBCXX_ASSERTIONS"),
    ("NOSAFETY", "cpp-harden", FIXTURE, "safety-not-included"),
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


def shell_scripts(files):
    for path in files:
        head = head_of(path)
        first = head.split("\n", 1)[0]
        if path.endswith(SHELL_SUFFIXES) or SHELL_SHEBANG.match(first):
            yield path, []
        elif first.startswith("#!") or "\0" in head or path.endswith(".install") or os.path.basename(path) == "PKGBUILD":
            continue
        elif re.search(r"#\s*shellcheck\s+shell=", head):
            yield path, []
        elif os.stat(path).st_mode & stat.S_IXUSR or (SHELL_CONTENT.search(head) and not NAMED_OTHERWISE.search(path)):
            # with no shebang and no suffix a shell runs it or sources it, and every shell reads sh
            yield path, ["--shell=sh"]


def gate_shell(found, _args):
    require("shellcheck", "shellcheck-py")
    files = tracked()
    batches = collections.defaultdict(list)
    for path, options in shell_scripts(files):
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
    paths = [p for p in tracked() if p.endswith(".py") or PYTHON_SHEBANG.match(head_of(p))]
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


def configure(project, *options, inject=True):
    for tool in ("cmake", "c++"):
        if not shutil.which(tool):
            die(f"{tool} is required for the C++ gates")
    # the fixture copies its stand-in for a third-party header next to the build directory, so both go under one scratch
    build = os.path.join(scratch(), "build")
    injected = [f"-DCMAKE_PROJECT_INCLUDE={os.path.join(ROOT, SAFETY)}"] if inject else []
    command = ["cmake", "-S", project, "-B", build, "-DCMAKE_BUILD_TYPE=RelWithDebInfo", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"]
    return build, run([*command, *injected, *options])


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


def check_packaged_flags(found, project, *options):
    build, result = configure(project, *options, inject=False)
    if result.returncode != 0:
        found.add(project, "build-failed", f"{project}: could not configure the way a package builds it\n{tail(result)}")
        return
    missing = sorted({flag for _path, flags in translation_units(build) for flag in REQUIRED_FLAGS["harden"] if flag not in flags})
    if missing:
        include = os.path.relpath(SAFETY, project)
        found.add(project, "safety-not-included", f"{project}: its own CMakeLists.txt compiles without {' '.join(missing)}; add include({include}) after project()")


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


def read_by(build):
    for directory, _names, files in os.walk(build):
        for name in files:
            if name.endswith(".d"):
                words = read(os.path.join(directory, name)).replace("\\\n", " ").split()
                yield from filter(None, (in_repo(os.path.join(build, word)) for word in words if not word.endswith(":")))


def check_suppressions(found, sources):
    for path in sorted(sources):
        for number, line in numbered(path):
            if CPP_SUPPRESSION.search(line):
                # the whole line is the rule, so widening a recorded suppression is a new line in the baseline
                found.add(path, "suppression: " + " ".join(line.split()), f"{path}:{number}: {line.strip()}")


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


def built(found, project, mode, *options):
    build, result = configure(project, *options)
    if result.returncode == 0:
        check_flags(found, project, build, mode)
        result = run(["cmake", "--build", build, "--parallel"])
    if result.returncode != 0:
        found.add(project, "build-failed", f"{project}: the {mode} build failed\n{tail(result)}")
        return None, result
    return build, result


def harden(found, project, *options):
    check_packaged_flags(found, project, *options)
    build, result = built(found, project, "harden", *options)
    if not build:
        return [], set()
    check_warnings(found, project, build, result.stdout + result.stderr)
    return check_elf(found, project, build), set(read_by(build))


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
    command = ["clang-tidy", "-p", build, f"--config-file={TIDY_CONFIG}", f"--header-filter=^{re.escape(ROOT)}/", "--quiet"]
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
            if line in seen or not in_repo(match[1]):
                continue
            seen.add(line)
            where = in_repo(match[1])
            found.add(where, match[5], f"{where}:{match[2]}: {match[4]} [{match[5]}]")


def gate_cpp_harden(found, _args):
    # a file with no C++ suffix still counts once a build reads it
    sources = {p for p in tracked() if p.lower().endswith(CPP_SUFFIXES)}
    for project in cpp_projects(found):
        sources |= harden(found, project)[1]
    check_suppressions(found, sources)


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
        runners[gate](findings, FIXTURE, f"-DFIXTURE_BAD={case}")
        return findings.counts

    with concurrent.futures.ThreadPoolExecutor(os.cpu_count()) as pool:
        results = list(pool.map(lambda entry: caught(*entry), SELFTEST))
    for (case, gate, path, rule), counts in zip(SELFTEST, results, strict=True):
        if (path, rule) not in counts:
            found.add(FIXTURE, f"missed:{case}", f"{gate} did not report {rule} at {path} for the fixture's {case} case")
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

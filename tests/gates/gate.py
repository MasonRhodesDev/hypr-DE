import argparse
import atexit
import collections
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASELINE = "tests/gates/baseline.tsv"
REQUIREMENTS = "tests/gates/requirements.txt"
LUACHECK = "1.2.0"
SAFETY = "plugins/cmake/Safety.cmake"
TIDY_CONFIG = "plugins/.clang-tidy"
FIXTURE = "tests/gates/cpp-fixture"

SHELL_SHEBANG = re.compile(r"^#!\s*(?:/usr)?/bin/(?:env\s+)?(?:ba|da|a)?sh\b")
PYTHON_SHEBANG = re.compile(r"^#!.*\bpython")
# makepkg assigns srcdir and pkgdir and reads pkgname and the rest itself, so shellcheck sees neither side
PKGBUILD_EXCLUDES = "SC2034,SC2154"
CPP_SUFFIXES = (".cpp", ".hpp", ".cc", ".h", ".inc")

REQUIRED_FLAGS = [
    "-Wall",
    "-Wextra",
    "-Wconversion",
    "-Wshadow",
    "-Werror",
    "-fstack-protector-strong",
    "-fstack-clash-protection",
    "-D_FORTIFY_SOURCE=3",
]
WEAKENING_FLAG = re.compile(r"^(?:-Wno-.+|-w|-fpermissive|-fno-stack-protector|-fno-stack-clash-protection|-fcf-protection=none)$")
TIDY_LINE = re.compile(r"^(.+?):(\d+):(\d+): (?:warning|error): (.*) \[([\w.,-]+)\]$")
LUACHECK_LINE = re.compile(r"^(.+?):(\d+):(\d+): \((\w+)\) (.*)$")
SELFTEST = {
    "WARNING": ("cpp-harden", "build-failed"),
    "NOWARN": ("cpp-harden", "flag-weakens:-Wno-conversion"),
    "OVERFLOW": ("cpp-sanitize", "tests-failed"),
    "UNDEFINED": ("cpp-sanitize", "tests-failed"),
    "TIDY": ("cpp-tidy", "cppcoreguidelines-pro-type-reinterpret-cast"),
}


class Findings:
    def __init__(self):
        self.counts = collections.Counter()
        self.details = collections.defaultdict(list)

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


def shebang(path):
    with open(path, "rb") as f:
        return f.readline(200).decode("utf-8", "replace")


def gate_shell(found, _args):
    require("shellcheck", "shellcheck-py")
    pkgbuilds = [p for p in tracked() if os.path.basename(p) == "PKGBUILD"]
    install_scripts = [p for p in tracked() if p.endswith(".install")]
    scripts = [p for p in tracked() if SHELL_SHEBANG.match(shebang(p)) or p.endswith(".sh")]
    batches = [(scripts, []), (install_scripts, ["--shell=bash"]), (pkgbuilds, ["--shell=bash", f"--exclude={PKGBUILD_EXCLUDES}"])]
    for paths, options in batches:
        if not paths:
            continue
        result = run(["shellcheck", "--format=json1", *options, *paths])
        try:
            comments = json.loads(result.stdout)["comments"]
        except (ValueError, KeyError):
            die(f"shellcheck gave no report: {result.stderr.strip()}")
        for c in comments:
            found.add(c["file"], f"SC{c['code']}", f"{c['file']}:{c['line']}: SC{c['code']} {c['message']}")
        for path in paths:
            for number, line in numbered(path):
                if re.search(r"#\s*shellcheck\s+disable=", line):
                    found.add(path, "inline-disable", f"{path}:{number}: {line.strip()}")


def gate_python(found, _args):
    require("ruff", "ruff")
    paths = [p for p in tracked() if p.endswith(".py") or PYTHON_SHEBANG.match(shebang(p))]
    result = run(["ruff", "check", "--no-cache", "--output-format=json", *paths])
    try:
        diagnostics = json.loads(result.stdout)
    except ValueError:
        die(f"ruff gave no report: {result.stderr.strip()}")
    for d in diagnostics:
        path = os.path.relpath(d["filename"], ROOT)
        code = d["code"] or "invalid-syntax"
        found.add(path, code, f"{path}:{d['location']['row']}: {code} {d['message']}")
    for path in paths:
        for number, line in numbered(path):
            if re.search(r"#\s*noqa\b", line):
                found.add(path, "inline-noqa", f"{path}:{number}: {line.strip()}")


def gate_lua(found, _args):
    version = run(["luacheck", "--version"]).stdout if shutil.which("luacheck") else ""
    if f"Luacheck: {LUACHECK}" not in version:
        die(f"luacheck {LUACHECK} is required; the CI workflow shows where to get it")
    paths = [p for p in tracked() if p.endswith(".lua")]
    result = run(["luacheck", "--formatter=plain", "--codes", "--no-color", *paths])
    if result.returncode > 2:
        die(f"luacheck could not run: {result.stdout.strip()} {result.stderr.strip()}")
    for line in result.stdout.splitlines():
        match = LUACHECK_LINE.match(line)
        if match:
            found.add(match[1], match[4], line)
    for path in paths:
        for number, line in numbered(path):
            if re.search(r"--\s*luacheck:", line):
                found.add(path, "inline-luacheck", f"{path}:{number}: {line.strip()}")


def cpp_projects():
    plugins = sorted(os.path.dirname(p) for p in tracked() if re.fullmatch(r"plugins/[^/]+/CMakeLists\.txt", p))
    return [*plugins, FIXTURE]


def scratch():
    root = tempfile.mkdtemp(prefix="hypr-de-gates-")
    atexit.register(shutil.rmtree, root, ignore_errors=True)
    return root


def configure(project, *options):
    for tool in ("cmake", "c++"):
        if not shutil.which(tool):
            die(f"{tool} is required for the C++ gates")
    build = scratch()
    safety = os.path.join(ROOT, SAFETY)
    command = ["cmake", "-S", project, "-B", build, "-DCMAKE_BUILD_TYPE=RelWithDebInfo", f"-DCMAKE_PROJECT_INCLUDE={safety}", *options]
    result = run([*command, "-DHYPR_DE_WERROR=ON"])
    return build, result


def tail(result):
    lines = (result.stdout + result.stderr).replace(ROOT + "/", "").splitlines()
    headlines = [line for line in lines[:-25] if re.search(r"ERROR: \w+Sanitizer|runtime error:|\berror:", line)]
    return "\n".join([*headlines[:10], *lines[-25:]])


def translation_units(project, build):
    with open(os.path.join(build, "compile_commands.json"), encoding="utf-8") as f:
        units = json.load(f)
    inside = os.path.join(ROOT, project) + os.sep
    return [(os.path.relpath(u["file"], ROOT), shlex.split(u["command"])) for u in units if u["file"].startswith(inside)]


def check_flags(found, project, build):
    required = [*REQUIRED_FLAGS, *(["-fcf-protection"] if platform.machine() in ("x86_64", "i686") else [])]
    units = translation_units(project, build)
    if not units:
        found.add(project, "no-sources", f"{project}: the build compiles nothing from this directory")
    for path, flags in units:
        for flag in required:
            if flag not in flags:
                found.add(project, f"flag-missing:{flag}", f"{path}: compiled without {flag}")
        if "-fPIC" not in flags and "-fPIE" not in flags:
            found.add(project, "flag-missing:-fPIC", f"{path}: compiled without -fPIC or -fPIE")
        fortified = max((i for i, flag in enumerate(flags) if flag == "-D_FORTIFY_SOURCE=3"), default=-1)
        for i, flag in enumerate(flags):
            undone = i > fortified and re.match(r"-[DU]_FORTIFY_SOURCE", flag)
            if WEAKENING_FLAG.match(flag) or undone:
                found.add(project, f"flag-weakens:{flag}", f"{path}: compiled with {flag}")


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


def harden(found, project, *options):
    build, result = configure(project, *options)
    if result.returncode == 0:
        result = run(["cmake", "--build", build, "--parallel"])
    if result.returncode != 0:
        found.add(project, "build-failed", f"{project}: the hardened build with -Werror failed\n{tail(result)}")
        return []
    check_flags(found, project, build)
    return check_elf(found, project, build)


def sanitize(found, project, *options):
    build, result = configure(project, "-DHYPR_DE_SANITIZE=ON", *options)
    if result.returncode == 0:
        result = run(["cmake", "--build", build, "--parallel"])
    if result.returncode != 0:
        found.add(project, "build-failed", f"{project}: the sanitizer build failed\n{tail(result)}")
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
    seen = set()
    header_filter = "^" + re.escape(os.path.join(ROOT, project)) + "/"
    for path, _flags in translation_units(project, build):
        command = ["clang-tidy", "-p", build, f"--config-file={TIDY_CONFIG}", f"--header-filter={header_filter}", "--quiet"]
        # the compile commands are GCC's, and clang must not fail on a warning flag only GCC has
        report = run([*command, "--extra-arg=-Wno-unknown-warning-option", "--extra-arg=-Wno-error", path])
        for line in report.stdout.splitlines():
            match = TIDY_LINE.match(line)
            if not match or line in seen:
                continue
            seen.add(line)
            where = os.path.relpath(match[1], ROOT)
            found.add(where, match[5], f"{where}:{match[2]}: {match[4]} [{match[5]}]")
    for path in tracked():
        if path.startswith(project + "/") and path.endswith(CPP_SUFFIXES):
            for number, line in numbered(path):
                if "NOLINT" in line:
                    found.add(path, "inline-nolint", f"{path}:{number}: {line.strip()}")


def gate_cpp_harden(found, _args):
    for project in cpp_projects():
        harden(found, project)


def gate_cpp_sanitize(found, _args):
    for project in cpp_projects():
        sanitize(found, project)


def gate_cpp_tidy(found, _args):
    for project in cpp_projects():
        tidy(found, project)


def gate_cpp_selftest(found, _args):
    runners = {"cpp-harden": harden, "cpp-sanitize": sanitize, "cpp-tidy": tidy}
    for case, (gate, rule) in SELFTEST.items():
        caught = Findings()
        runners[gate](caught, FIXTURE, f"-DFIXTURE_BAD={case}")
        if not any(rule in key[1] for key in caught.counts):
            found.add(FIXTURE, f"missed:{case}", f"{gate} did not report {rule} for the fixture's {case} case")
    clean = Findings()
    for binary in harden(clean, FIXTURE):
        if "__stack_chk_fail" not in run(["readelf", "-sW", "--dyn-syms", binary]).stdout:
            found.add(FIXTURE, "missed:stack-protector", f"{os.path.basename(binary)} has no stack protector")


def parse_baseline(text):
    entries = {}
    for line in text.splitlines():
        gate, path, rule, count = line.split("\t")
        entries[gate, path, rule] = int(count)
    return entries


def gate_baseline(found, args):
    base = args.base
    if not base or set(base) == {"0"}:
        print("baseline: no base revision given, nothing to compare")
        return
    if run(["git", "rev-parse", "--verify", "--quiet", f"{base}^{{commit}}"]).returncode != 0:
        die(f"base revision {base} is not in this clone; fetch it, or pass --base")
    old = run(["git", "show", f"{base}:{BASELINE}"])
    if old.returncode != 0:
        print(f"baseline: {base} has no {BASELINE}, so this change introduces it")
        return
    before = parse_baseline(old.stdout)
    for (gate, path, rule), count in parse_baseline(read(BASELINE)).items():
        allowed = before.get((gate, path, rule), 0)
        if count > allowed:
            found.add(BASELINE, "grew", f"{gate} {path} {rule}: {allowed} at {base}, {count} here; the baseline only shrinks")


GATES = {
    "shell": gate_shell,
    "python": gate_python,
    "lua": gate_lua,
    "cpp-harden": gate_cpp_harden,
    "cpp-sanitize": gate_cpp_sanitize,
    "cpp-tidy": gate_cpp_tidy,
    "cpp-selftest": gate_cpp_selftest,
    "baseline": gate_baseline,
}


def judge(gate, found, baseline, args):
    allowed = {key[1:]: count for key, count in baseline.items() if key[0] == gate}
    failures = 0
    for key in sorted(set(found.counts) | set(allowed)):
        have, limit = found.counts[key], allowed.get(key, 0)
        if have == limit:
            continue
        if args.update and (have < limit or args.allow_growth):
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
    parser.add_argument("--allow-growth", action="store_true", help="with --update, also record new findings (for a new gate only)")
    parser.add_argument("--base", default=os.environ.get("GATE_BASE", "origin/main"), help="revision the baseline may not grow against")
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

"""Attempts to ship unhardened or weakened code past the gates, each from a fresh clone of HEAD.

Each case makes one change, runs the named gates as CI does and passes only when
the gates print the expected FAIL line. A case with no expected line is one the
gates pass by design, with the reason beside it. Run it where the C++ gates run:

    python3 -I tests/gates/attacks.py [case ...]

The cases come from the reviews of the gates. Nothing here runs in CI; the
self-test (cpp-selftest) covers the same mechanisms on the gates' own fixture.
"""

import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
import tempfile

PLUGIN = "plugins/hypr-de-scene"
CM = f"{PLUGIN}/CMakeLists.txt"
SCENE = "packaging/hypr-de-scene/PKGBUILD"
CPP = ["cpp-harden"]
UNIT = rf"{PLUGIN}/src/\S+"
IMPL = r"@hypr-de-scene/usr/lib/hypr-de/hypr-de-scene-impl\.so"
BLOB = 'extern "C" int hypr_de_probe(char *s) { char b[8]; int n = 0; while (s[n]) { b[n] = s[n]; n++; } return b[0] + n; }'
EVASION = r"""#/**/undef _FORTIFY_SOURCE
#undef _GLIBCXX_ASS\
ERTIONS
__attribute__ ( ( optimize("O0") ) ) int gate_probe_a();
__attribute__((cold,
    optimize("O0"))) int gate_probe_b();
#pra\
gma GCC diagnostic ignored "-Wconversion"
inline int gate_probe_narrow(long v) { return v; }
"""

# name: (gates, change made with bash in the clone, FAIL lines that must appear; none means the gates pass by design)
CASES = {
    "a1": (CPP, f"""printf '\\nset_source_files_properties(src/Spec.cpp PROPERTIES COMPILE_OPTIONS "-O0;-U_FORTIFY_SOURCE")\\n' >>{CM}""",
           [rf"cpp-harden: {PLUGIN}/src/Spec\.cpp unoptimized", rf"cpp-harden: {PLUGIN}/src/Spec\.cpp fortify-off"]),
    "a2": (CPP, f"""sed -i 's|^include(../cmake/Safety.cmake)$|add_library(second SHARED src/Log.cpp)\\n&|' {CM}""",
           [rf"cpp-harden: {PLUGIN}/src/Log\.cpp fortify-off"]),
    "a3": (CPP, f"""printf '\\nadd_compile_options(-fno-stack-protector -U_FORTIFY_SOURCE)\\n' >>{CM}""", [rf"cpp-harden: {UNIT} stack-protector-off"]),
    # CMAKE_CXX_FLAGS come first on the command line, and Safety.cmake's -fstack-protector-strong after them wins
    "a4": (CPP, f"""sed -i 's|^  cmake -S plugins/hypr-de-scene|  export CXXFLAGS="-fno-stack-protector"\\n&|' {SCENE}""", []),
    "a5": (CPP, f"""sed -i 's|^  cmake -S plugins/hypr-de-scene -B build|  CXXFLAGS="-fno-stack-protector" &|' {SCENE}""", []),
    "a6": (CPP, f"""printf 'inline int gate_extra(long v) {{ return v; }}\\n' >{PLUGIN}/src/Extra.cpp; sed -i '1i #include "Extra.cpp"' {PLUGIN}/src/Spec.cpp""",
           [rf"cpp-harden: {PLUGIN}/src/Extra\.cpp -Wconversion"]),
    "a7": (CPP, f"""printf '\\nif(NOT DEFINED ENV{{CI}})\\n    target_compile_options(hypr-de-scene-impl PRIVATE -fno-stack-protector)\\nendif()\\n' >>{CM}""",
           [rf"cpp-harden: {UNIT} stack-protector-off"]),
    "a7b": (CPP, f"""printf '\\nif(NOT EXISTS "${{CMAKE_CURRENT_SOURCE_DIR}}/../../.git")\\n    target_compile_options(hypr-de-scene-impl PRIVATE -fno-stack-protector)\\nendif()\\n' >>{CM}""",
            [rf"cpp-harden: {UNIT} stack-protector-off"]),
    "a8": (CPP, f"""sed -i -e 's|^build() {{$|function build() {{|' -e "s|^  cmake -S plugins/hypr-de-scene|  sed -i '/Safety.cmake/d' {CM}\\n&|" {SCENE}""",
           [rf"cpp-harden: {UNIT} fortify-off"]),
    "a8b": (CPP, f"""sed -i 's|^build() {{$|build() {{ cd "$srcdir/hypr-DE-$pkgver" \\&\\& sed -i /Safety.cmake/d {CM} \\&\\& cmake -S {PLUGIN} -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \\&\\& cmake --build build; }}\\n_old_build() {{|' {SCENE}""",
            [rf"cpp-harden: {UNIT} fortify-off"]),
    "a9": (CPP, f"""printf '\\nset_target_properties(hypr-de-scene-impl PROPERTIES UNITY_BUILD ON UNITY_BUILD_BATCH_SIZE 1)\\ntarget_compile_options(hypr-de-scene-impl PRIVATE -fno-stack-protector -U_FORTIFY_SOURCE)\\n' >>{CM}""",
           [r"cpp-harden: @hypr-de-scene/build/CMakeFiles/hypr-de-scene-impl\.dir/Unity/unity_\d+_cxx\.cxx stack-protector-off"]),
    "a10": (CPP, f"""sed -i "s#^  cmake -S plugins/hypr-de-scene#  cd \\"\\$(sed -i '/Safety.cmake/d' {CM} | pwd)\\"\\n&#" {SCENE}""", [rf"cpp-harden: {UNIT} fortify-off"]),
    "b1": (CPP, f"""printf '\\ntarget_compile_options(hypr-de-scene-impl PRIVATE "SHELL:-U _FORTIFY_SOURCE" "SHELL:-U _GLIBCXX_ASSERTIONS")\\n' >>{CM}""",
           [rf"cpp-harden: {UNIT} fortify-off", rf"cpp-harden: {UNIT} assertions-off"]),
    "b2": (CPP, f"""printf '\\ntarget_compile_options(hypr-de-scene-impl PRIVATE -Wp,-U_FORTIFY_SOURCE -Wp,-U_GLIBCXX_ASSERTIONS)\\n' >>{CM}""",
           [rf"cpp-harden: {UNIT} fortify-off", rf"cpp-harden: {UNIT} assertions-off"]),
    "b3": (CPP, f"""printf -- '-fno-stack-protector\\n-O0\\n-U_FORTIFY_SOURCE\\n' >{PLUGIN}/flags.rsp; printf '\\ntarget_compile_options(hypr-de-scene-impl PRIVATE @${{CMAKE_CURRENT_SOURCE_DIR}}/flags.rsp)\\n' >>{CM}""",
           [rf"cpp-harden: {UNIT} stack-protector-off", rf"cpp-harden: {UNIT} unoptimized", rf"cpp-harden: {UNIT} fortify-off"]),
    "b5": (CPP, f"""printf 'inline int gate_narrow(long v) {{ return v; }}\\n' >{PLUGIN}/src/Hdr.hpp; sed -i '1i #include <Hdr.hpp>' {PLUGIN}/src/Spec.cpp; printf '\\ntarget_include_directories(hypr-de-scene-impl SYSTEM PRIVATE ${{CMAKE_CURRENT_SOURCE_DIR}}/src)\\n' >>{CM}""",
           [rf"cpp-harden: {PLUGIN}/src/Hdr\.hpp system-header-in-tree"]),
    "b5ctl": (CPP, f"""printf 'inline int gate_narrow(long v) {{ return v; }}\\n' >{PLUGIN}/src/Hdr.hpp; sed -i '1i #include "Hdr.hpp"' {PLUGIN}/src/Spec.cpp""",
              [rf"cpp-harden: {PLUGIN}/src/Hdr\.hpp -Wconversion"]),
    "b7": (CPP, f"""cat - {PLUGIN}/src/Spec.cpp >x <<'EOF'\n{EVASION}EOF\nmv x {PLUGIN}/src/Spec.cpp""",
           [rf"cpp-harden: {PLUGIN}/src/Spec\.cpp fortify-off", rf"cpp-harden: {PLUGIN}/src/Spec\.cpp assertions-off",
            rf"cpp-harden: {PLUGIN}/src/Spec\.cpp source-weakens: attribute optimize",
            rf'cpp-harden: {PLUGIN}/src/Spec\.cpp suppression: #pragma GCC diagnostic ignored "-Wconversion"', rf"cpp-harden: {PLUGIN}/src/Spec\.cpp -Wconversion"]),
    "b7b": (CPP, f"""sed -i '1i #define/**/NDEBUG\\n#include <cassert>\\n#undef NDEBUG' {PLUGIN}/src/Spec.cpp""", [rf"cpp-harden: {PLUGIN}/src/Spec\.cpp ndebug"]),
    "b8a": (CPP, f"""sed -i 's|^  cmake --build build$|  cmake --build build -- CXX_FLAGS="-O3 -DNDEBUG -std=c++26 -fPIC -pthread -DHWY_SHARED_DEFINE -ffp-contract=off -w"|' {SCENE}""",
            [rf"cpp-harden: {UNIT} ndebug", rf"cpp-harden: {UNIT} fortify-off", r"cpp-harden: packaging/hypr-de-scene/PKGBUILD warning-off:-w"]),
    "b8b": (CPP, f"""sed -i 's|^build() {{$|prepare() {{\\n  cd "$srcdir"; cd "hypr-DE-$pkgver" 2>/dev/null \\|\\| cd "$pkgname-$pkgver"\\n  sed -i /Safety.cmake/d {CM}\\n}}\\n\\nbuild() {{|' {SCENE}""",
            [rf"cpp-harden: {UNIT} fortify-off"]),
    "b9": (CPP, f"""printf '\\ntarget_link_options(hypr-de-scene-impl PRIVATE -Wl,-rpath,/tmp/hypr-de-plugins)\\n' >>{CM}""", [rf"cpp-harden: {IMPL} elf-runpath"]),
    "b10": (CPP, f"""printf '\\ntarget_link_options(hypr-de-scene-impl PRIVATE -Wl,-z,norelro -Wl,-z,lazy -Wl,-z,execstack)\\nset_target_properties(hypr-de-scene-impl PROPERTIES LIBRARY_OUTPUT_DIRECTORY ${{CMAKE_BINARY_DIR}}/CMakeFiles/out)\\n' >>{CM}""",
            [rf"cpp-harden: {IMPL} elf-no-relro", rf"cpp-harden: {IMPL} elf-lazy-binding", rf"cpp-harden: {IMPL} elf-executable-stack"]),
    "t1": (CPP, f"""printf '\\nset_target_properties(hypr-de-scene-impl PROPERTIES COMPILE_OPTIONS "-Wall")\\n' >>{CM}""",
           [rf"cpp-harden: {UNIT} warning-missing:-Wconversion", rf"cpp-harden: {UNIT} stack-clash-off"]),
    "t2": (CPP, f"""printf '\\ntarget_compile_options(hypr-de-scene-impl PRIVATE "$<$<CONFIG:Release>:-fno-stack-protector>" "$<$<COMPILE_LANGUAGE:CXX>:-U_FORTIFY_SOURCE>")\\n' >>{CM}""",
           [rf"cpp-harden: {UNIT} stack-protector-off"]),
    "t3": (CPP, f"""printf '\\nset_property(TARGET hypr-de-scene-impl PROPERTY LINK_OPTIONS "")\\n' >>{CM}""", [rf"cpp-harden: {IMPL} elf-lazy-binding"]),
    "d1": (CPP, f"""mkdir -p tools/probe
printf 'cmake_minimum_required(VERSION 3.27)\\nproject(probe LANGUAGES CXX)\\nadd_library(probe SHARED main.cpp)\\ntarget_compile_options(probe PRIVATE -fno-stack-protector -O0)\\n' >tools/probe/CMakeLists.txt
printf 'extern "C" int probe(long v) {{ int small = v; return small; }}\\n' >tools/probe/main.cpp
printf 'tools/probe/CMakeLists.txt\\tmake\\ntools/probe/main.cpp\\tcpp-test\\n' >>tests/gates/classified.tsv
sort -o tests/gates/classified.tsv tests/gates/classified.tsv
sed -i 's|^  cmake --build build$|&\\n  cmake -S tools/probe -B build-probe -DCMAKE_BUILD_TYPE=Release\\n  cmake --build build-probe|' {SCENE}""",
           [r"cpp-harden: tools/probe/main\.cpp unoptimized", r"cpp-harden: tools/probe/main\.cpp fortify-off"]),
    "d1b": (CPP, f"""mkdir -p tools/probe
printf 'cmake_minimum_required(VERSION 3.27)\\nproject(probe LANGUAGES CXX)\\nadd_library(probe SHARED main.cpp)\\ntarget_compile_options(probe PRIVATE -fno-stack-protector -O0)\\ninstall(TARGETS probe LIBRARY DESTINATION lib/hypr-de)\\n' >tools/probe/CMakeLists.txt
printf 'extern "C" int probe(long v) {{ int small = v; return small; }}\\n' >tools/probe/main.cpp
printf 'tools/probe/CMakeLists.txt\\tmake\\ntools/probe/main.cpp\\tcpp-test\\n' >>tests/gates/classified.tsv
sort -o tests/gates/classified.tsv tests/gates/classified.tsv
sed -i -e 's|^  cmake --build build$|&\\n  cmake -S tools/probe -B build-probe -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr\\n  cmake --build build-probe|' -e 's|^  DESTDIR="$pkgdir" cmake --install build$|&\\n  DESTDIR="$pkgdir" cmake --install build-probe|' {SCENE}""",
            [r"cpp-harden: @hypr-de-scene/usr/lib/hypr-de/libprobe\.so elf-lazy-binding", r"cpp-harden: tools/probe/main\.cpp stack-protector-off"]),
    "e1": (["classify", *CPP], f"""mkdir -p {PLUGIN}/prebuilt
printf '%s\\n' '{BLOB}' >/tmp/gate-blob-$$.cpp
c++ -shared -fPIC -O0 -fno-stack-protector -U_FORTIFY_SOURCE -Wl,-z,norelro -Wl,-z,lazy -Wl,-z,execstack -o {PLUGIN}/prebuilt/hypr-de-scene-impl.so /tmp/gate-blob-$$.cpp
rm -f /tmp/gate-blob-$$.cpp
printf '\\ninstall(FILES prebuilt/hypr-de-scene-impl.so DESTINATION lib/hypr-de)\\n' >>{CM}""",
           [rf"classify: {PLUGIN}/prebuilt/hypr-de-scene-impl\.so binary", rf"cpp-harden: {IMPL} unattributed"]),
    "e2": (CPP, f"""cat >{PLUGIN}/cc-wrap.py <<'EOF'
import subprocess
import sys

args = [a for a in sys.argv[1:] if a not in ("-fstack-protector-strong", "-D_FORTIFY_SOURCE=3")]
sys.exit(subprocess.run(args, check=False).returncode)
EOF
printf '\\nset_property(TARGET hypr-de-scene-impl PROPERTY RULE_LAUNCH_COMPILE "python3 ${{CMAKE_CURRENT_SOURCE_DIR}}/cc-wrap.py")\\n' >>{CM}""",
           [rf"cpp-harden: {UNIT} fortify-off"]),
    "e2b": (CPP, f"""cat >{PLUGIN}/cc-wrap.py <<'EOF'
import subprocess
import sys

sys.exit(subprocess.run(["/usr/bin/c++", *sys.argv[2:]], check=False).returncode)
EOF
printf '\\nset_property(TARGET hypr-de-scene-impl PROPERTY RULE_LAUNCH_COMPILE "python3 ${{CMAKE_CURRENT_SOURCE_DIR}}/cc-wrap.py")\\n' >>{CM}""",
            [rf"cpp-harden: {IMPL} unattributed"]),
    "e3": (CPP, f"""printf '%s\\n' '{BLOB}' >{PLUGIN}/src/probe.cpp.txt
cat >>{CM} <<'EOF'

add_custom_command(OUTPUT ${{CMAKE_CURRENT_BINARY_DIR}}/hypr-de-extra.so
    COMMAND c++ -x c++ -shared -fPIC -O0 -fno-stack-protector -Wl,-z,relro,-z,now,-z,noexecstack -fcf-protection -o ${{CMAKE_CURRENT_BINARY_DIR}}/hypr-de-extra.so ${{CMAKE_CURRENT_SOURCE_DIR}}/src/probe.cpp.txt
    DEPENDS src/probe.cpp.txt)
add_custom_target(extra ALL DEPENDS ${{CMAKE_CURRENT_BINARY_DIR}}/hypr-de-extra.so)
install(FILES ${{CMAKE_CURRENT_BINARY_DIR}}/hypr-de-extra.so DESTINATION lib/hypr-de)
EOF""",
           [rf"cpp-harden: {PLUGIN}/src/probe\.cpp\.txt unoptimized", rf"cpp-harden: {PLUGIN}/src/probe\.cpp\.txt stack-protector-off"]),
    "c1": (["classify", "shell"], """mkdir -p dist/lib
printf 'cleanup() { rm -rf $1/cache; }\\n' >dist/lib/util.lib
printf 'cleanup() { rm -rf $1/cache; }\\n' >dist/lib/util.zsh
printf '#!/usr/bin/env zsh\\nrm -rf $1/x\\n' >dist/lib/run.zsh
sed -i 's|^%files|%post\\nrm -rf $1/cache\\n\\n%files|' packaging/hypr-de-scene.spec""",
           [r"classify: dist/lib/util\.lib unclassified", r"classify: dist/lib/util\.zsh unclassified", r"shell: dist/lib/run\.zsh unlintable-shell",
            r"shell: packaging/hypr-de-scene\.spec SC2086"]),
    "c2": (["shell"], """sed -i 's|^%files|%post -p /usr/bin/zsh\\nrm -rf $1/cache\\n\\n%files|' packaging/hypr-de-scene.spec""",
           [r"shell: packaging/hypr-de-scene\.spec unlintable-shell"]),
}


def attempt(name, root):
    gates, change, expected = CASES[name]
    work = tempfile.mkdtemp(prefix=f"gate-attack-{name}-")
    try:
        clone = os.path.join(work, "clone")
        subprocess.run(["git", "clone", "-q", "--no-hardlinks", root, clone], check=True)
        made = subprocess.run(["bash", "-euc", change], cwd=clone, capture_output=True, text=True, check=False)
        if made.returncode:
            return False, f"MISS {name}\n     the change did not apply: {made.stderr.strip()}"
        subprocess.run(["git", "add", "-A"], cwd=clone, check=True)
        result = subprocess.run(["tests/gates/check.sh", *gates], cwd=clone, capture_output=True, text=True, check=False)
        lines = [line for line in result.stdout.splitlines() if line.startswith(("FAIL ", "gate:"))] + result.stderr.splitlines()[-3:]
        missing = [pattern for pattern in expected if not any(re.match(rf"FAIL {pattern}:", line) for line in lines)]
        shown = [line for line in lines if any(re.match(rf"FAIL {pattern}:", line) for pattern in expected)]
        ok = not missing and (result.returncode != 0 if expected else result.returncode == 0)
        report = [f"{'ok  ' if ok else 'MISS'} {name}", *(f"     {line}" for line in (shown if ok else lines))]
        report += [f"     expected, not seen: {pattern}" for pattern in missing]
        return ok, "\n".join(report)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main():
    root = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
    names = sys.argv[1:] or list(CASES)
    unknown = [name for name in names if name not in CASES]
    if unknown:
        sys.exit(f"unknown case: {' '.join(unknown)}; one of {' '.join(CASES)}")
    with concurrent.futures.ThreadPoolExecutor(max(1, (os.cpu_count() or 4) // 4)) as pool:
        results = list(pool.map(lambda name: attempt(name, root), names))
    for _ok, report in results:
        print(report, flush=True)
    failed = sum(not ok for ok, _report in results)
    print(f"{len(results) - failed}/{len(results)} cases as expected")
    sys.exit(1 if failed else 0)


main()

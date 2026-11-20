"""Attempts to ship unhardened or weakened code past the gates, each from a fresh clone of HEAD.

Each case makes one change, runs the named gates as CI does and passes only when
the gates print the expected FAIL line. A case with no expected line is one the
gates pass by design, with the reason beside it. A case's options can set the
environment ({work} is the case's scratch directory), leave its change out of
git ("add": False), fail on any FAIL line it does not expect ("exact"), name
other lines the output must hold ("out") or must not ("absent"), give the
rpm gate the RPMs the change built ("rpms"), name the tools it needs and is
not run without ("needs"), or drop the plugin's check()
("check": False), or name the one package the C++ gates build ("pkgbuild",
the plugin's by default). A case drops check() when its change breaks the plugin's own
tests, so check() would stop the build, as build-failed, before the line the
case is about; or, for r4, when check()'s test build would make the shipped
library's exact bytes through the shim and so attribute it. The gate "ratchet" runs HEAD's copy
of tests/gates/ratchet.py against HEAD, as CI runs the base branch's copy. The
C++ gates build only the plugin's package (--pkgbuild), the one every case
changes; CI builds every package. Run it where the C++ gates run:

    python3 -I tests/gates/attacks.py [case ...]

The rpm cases (h2a, h2b, h2ctl, h3a, h3b) need rpmbuild and annocheck, so
they print as not run there, apart from the tally; run them where the rpm job
in .github/workflows/scene-plugin.yml runs, with git, gcc, python3, rpm-build,
annobin-annocheck, binutils and cpio installed.

The cases come from the reviews of the gates. Nothing here runs in CI; the
self-test (cpp-selftest) covers the same mechanisms on the gates' own fixture.
"""

import concurrent.futures
import glob
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

RATCHET_ROW = """python3 - <<'EOF'
import hashlib
with open("tests/gates/baseline.tsv", "a", encoding="utf-8") as f:
    f.write("\\t".join(["shell", "dist/uwsm/env", "SC9999", hashlib.sha256(b"x").hexdigest()[:16], "1", "x"]) + "\\n")
EOF"""
GEOMETRY = f"{PLUGIN}/src/Geometry.cpp"
WALLPAPER = "dist/bin/hypr-de-set-wallpaper"
QUOTED = r"""sed -i 's/^\[ \$# -eq 1 \] || usage$/[ "$#" -eq 1 ] || usage/' dist/bin/hypr-de-set-wallpaper"""
# a cc1plus that drops the stack protector from every real compile and leaves the preprocessor alone, so -E and -### look clean
CC1PLUS = """#!/bin/sh
real=$(/usr/bin/gcc -print-prog-name=cc1plus)
case " $* " in *" -E "*) exec "$real" "$@" ;; esac
exec "$real" "$@" -fno-stack-protector
"""
# a step after the given line that flips a byte in a section of the built library after its link, before package() installs it
PATCH = """cat >../patch.py <<'PY'
import subprocess
import sys

path, wanted = sys.argv[1], sys.argv[2]
for line in subprocess.run(["readelf", "-SW", path], capture_output=True, text=True, check=True).stdout.splitlines():
    fields = line.replace("[ ", "[").split()
    if len(fields) > 5 and fields[1] == wanted:
        offset, size = int(fields[4], 16), int(fields[5], 16)
        with open(path, "r+b") as f:
            f.seek(offset + size // 2)
            byte = f.read(1)[0]
            f.seek(offset + size // 2)
            f.write(bytes([byte ^ 1]))
PY
cp ../patch.py packaging/hypr-de-scene/patch.py
sed -i 's|^source=(|source=(patch.py |; s|^sha256sums=(|sha256sums=(SKIP |' {scene}
sed -i 's|^  {after}$|&\\n  python3 "$srcdir/patch.py" build/hypr-de-scene-impl.so {section}|' {scene}"""

# round 6: a toy shared library built with Fedora's flags, for the rpm gate
TOY = """mkdir -p ../toy ../rpms
cat >../toy/toy.spec <<'SPEC'
%undefine _debugsource_packages
{macros}
Name: gate-toy
Version: 1
Release: 1
Summary: A shared library the rpm gate audits
License: MIT
BuildRequires: gcc

%description
A shared library the rpm gate audits.

%prep
%setup -q -c -T

%build
printf 'int gate_toy(int v) {{ return v * 2; }}\\n' >toy.c
%{{__cc}} %{{optflags}} {cflags} -fPIC -shared %{{build_ldflags}} -o libtoy.so toy.c

%install
{install}

%files
{files}
SPEC
rpmbuild -bb --quiet --define "_topdir $PWD/../rpmbuild" ../toy/toy.spec >../rpmbuild.log 2>&1 || {{ cat ../rpmbuild.log >&2; exit 1; }}
cp ../rpmbuild/RPMS/*/{pick} ../rpms/"""
LIBTOY = {"install": "install -Dm755 libtoy.so %{buildroot}%{_libdir}/libtoy.so", "files": "%{_libdir}/libtoy.so", "cflags": "", "macros": "", "pick": "*.rpm"}
RPM = {"rpms": "../rpms/*.rpm", "needs": ["rpmbuild", "annocheck"]}
SCENE_SPEC = "packaging/hypr-de-scene.spec"
# a test of the plugin's own, compiled alone by one line of a test script in check()
CLAMP = f"""printf '#include <algorithm>\\n\\nint main() {{ return std::clamp(3, 0, 2) == 2 ? 0 : 1; }}\\n' >{PLUGIN}/tests/clamp.cpp
printf '{PLUGIN}/tests/clamp.cpp\\tcpp-test\\n' >>tests/gates/classified.tsv
LC_ALL=C sort -o tests/gates/classified.tsv tests/gates/classified.tsv
cat >../clamp.sh <<'SH'
"$cxx" -std=c++23 -Wall -Wextra -Werror -o "$work/clamp" "$src/tests/clamp.cpp" || {{ echo "FAIL the clamp test does not compile"; exit 1; }}
"$work/clamp" || exit 1
SH
sed -i '/^"$work\\/geometry" || exit 1$/r ../clamp.sh' tests/scene-geometry.sh
grep -q clamp tests/scene-geometry.sh"""
# clang-format's wrap of a baselined statement
REWRAP = f"""python3 - <<'PY'
path = "{PLUGIN}/src/Scene.cpp"
text = open(path, encoding="utf-8").read()
line = "    const auto GROUND = CHyprColor(m_spec.background[0] / 255.F, m_spec.background[1] / 255.F, m_spec.background[2] / 255.F, ALPHA);"
assert line in text
wrapped = "    const auto GROUND = CHyprColor(m_spec.background[0] / 255.F, m_spec.background[1] / 255.F,\\n" + " " * 35 + "m_spec.background[2] / 255.F, ALPHA);"
open(path, "w", encoding="utf-8").write(text.replace(line, wrapped))
PY"""
# a one-line guard written out as a block, as a reviewer or shfmt would
SHELLWRAP = r"""python3 - <<'PY'
path = "dist/bin/hypr-de-set-wallpaper"
text = open(path, encoding="utf-8").read()
line = '[ -r "$WP" ] || { echo "hypr-de-set-wallpaper: cannot read $WP" >&2; exit 1; }\n'
assert line in text
open(path, "w", encoding="utf-8").write(text.replace(line, '[ -r "$WP" ] || {\n    echo "hypr-de-set-wallpaper: cannot read $WP" >&2\n    exit 1\n}\n'))
PY"""
K0 = """sed -i 's/^\\[ \\$# -eq 1 \\] || usage$/[[ $# -eq 1 ]] || usage\\n[ -n "$1" ] || usage/' dist/bin/hypr-de-set-wallpaper"""
# round 8: the formatters themselves, over the tree, each with the repo's own config or its default flags; the change fails
# if the formatter changes nothing. shfmt cannot parse tests/run (an associative array key with a slash), so it is left out.
CLANG_FORMAT = f"""clang-format -i {PLUGIN}/src/*
if git diff --quiet; then echo "the formatter changed nothing" >&2; exit 1; fi"""
SHFMT = """awk -F'\\t' '$1 == "shell" && $2 != "tests/run" { print $2 }' tests/gates/baseline.tsv | sort -u | xargs shfmt -w FLAGS
if git diff --quiet; then echo "the formatter changed nothing" >&2; exit 1; fi"""
# a new finding of a moved row's rule in its file, made in the same edit as the formatter's run
NEW_ACCESS = f"""sed -i 's|^    g_pHyprRenderer->blend(true);$|&\\n    static_cast<void>(m_spec.background[1]);|' {PLUGIN}/src/Scene.cpp
"""
NEW_CHAIN = """sed -i '/sleep during a running lock joins it/a [[ -n "${probe:-}" ]] && ok "probe" || bad "probe"' tests/lock-listener.sh
"""
GROWN = {"exact": True, "absent": [r"FAIL .*lower it with --update"], "out": [r".*--update --allow-growth"]}

# name: (gates, change made with bash in the clone, FAIL lines that must appear, and options); no lines means the gates pass by design
CASES = {
    "a1": (CPP, f"""printf '\\nset_source_files_properties(src/Spec.cpp PROPERTIES COMPILE_OPTIONS "-O0;-U_FORTIFY_SOURCE")\\n' >>{CM}""",
           [rf"cpp-harden: {PLUGIN}/src/Spec\.cpp unoptimized", rf"cpp-harden: {PLUGIN}/src/Spec\.cpp fortify-off"]),
    "a2": (CPP, f"""sed -i 's|^include(../cmake/Safety.cmake)$|add_library(second SHARED src/Log.cpp)\\n&|' {CM}
printf '\\ninstall(TARGETS second LIBRARY DESTINATION lib/hypr-de)\\n' >>{CM}""",
           [rf"cpp-harden: {PLUGIN}/src/Log\.cpp fortify-off"], {"check": False}),
    "a3": (CPP, f"""sed -i 's|^include(../cmake/Safety.cmake)$|&\\nadd_compile_options(-fno-stack-protector -U_FORTIFY_SOURCE)|' {CM}""",
           [rf"cpp-harden: {UNIT} stack-protector-off"]),
    # after the targets exist, add_compile_options changes nothing CMake builds
    "a3b": (CPP, f"""printf '\\nadd_compile_options(-fno-stack-protector -U_FORTIFY_SOURCE)\\n' >>{CM}""", []),
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
           [rf"cpp-harden: {PLUGIN}/src/Hdr\.hpp system-header-in-tree"], {"check": False}),
    "b5ctl": (CPP, f"""printf 'inline int gate_narrow(long v) {{ return v; }}\\n' >{PLUGIN}/src/Hdr.hpp; sed -i '1i #include "Hdr.hpp"' {PLUGIN}/src/Spec.cpp""",
              [rf"cpp-harden: {PLUGIN}/src/Hdr\.hpp -Wconversion"]),
    "b7": (CPP, f"""cat - {PLUGIN}/src/Spec.cpp >x <<'EOF'\n{EVASION}EOF\nmv x {PLUGIN}/src/Spec.cpp""",
           [rf"cpp-harden: {PLUGIN}/src/Spec\.cpp fortify-off", rf"cpp-harden: {PLUGIN}/src/Spec\.cpp assertions-off",
            rf"cpp-harden: {PLUGIN}/src/Spec\.cpp source-weakens: attribute optimize",
            rf'cpp-harden: {PLUGIN}/src/Spec\.cpp suppression: #pragma GCC diagnostic ignored "-Wconversion"']),
    "b7b": (CPP, f"""sed -i '1i #define/**/NDEBUG\\n#include <cassert>\\n#undef NDEBUG' {PLUGIN}/src/Spec.cpp""", [rf"cpp-harden: {PLUGIN}/src/Spec\.cpp ndebug"]),
    "b8a": (CPP, f"""sed -i 's|^  cmake --build build$|  cmake --build build -- CXX_FLAGS="-O3 -DNDEBUG -std=c++26 -fPIC -pthread -DHWY_SHARED_DEFINE -ffp-contract=off -w"|' {SCENE}""",
            [rf"cpp-harden: {UNIT} ndebug", rf"cpp-harden: {UNIT} fortify-off", r"cpp-harden: packaging/hypr-de-scene/PKGBUILD warning-off:-w"]),
    "b8b": (CPP, f"""sed -i 's|^build() {{$|prepare() {{\\n  cd "$srcdir"; cd "hypr-DE-$pkgver" 2>/dev/null \\|\\| cd "$pkgname-$pkgver"\\n  sed -i /Safety.cmake/d {CM}\\n}}\\n\\nbuild() {{|' {SCENE}""",
            [rf"cpp-harden: {UNIT} fortify-off"]),
    "b9": (CPP, f"""printf '\\ntarget_link_options(hypr-de-scene-impl PRIVATE -Wl,-rpath,/tmp/hypr-de-plugins)\\n' >>{CM}""", [rf"cpp-harden: {IMPL} elf-runpath"]),
    "b10": (CPP, f"""printf '\\ntarget_link_options(hypr-de-scene-impl PRIVATE -Wl,-z,norelro -Wl,-z,lazy -Wl,-z,execstack)\\nset_target_properties(hypr-de-scene-impl PROPERTIES LIBRARY_OUTPUT_DIRECTORY ${{CMAKE_BINARY_DIR}}/CMakeFiles/out)\\n' >>{CM}""",
            [rf"cpp-harden: {IMPL} elf-no-relro", rf"cpp-harden: {IMPL} elf-lazy-binding", rf"cpp-harden: {IMPL} elf-executable-stack"], {"check": False}),
    "t1": (CPP, f"""printf '\\nset_target_properties(hypr-de-scene-impl PROPERTIES COMPILE_OPTIONS "-Wall")\\n' >>{CM}""",
           [rf"cpp-harden: {UNIT} warning-missing:-Wconversion", rf"cpp-harden: {UNIT} stack-clash-off"]),
    "t2": (CPP, f"""printf '\\ntarget_compile_options(hypr-de-scene-impl PRIVATE "$<$<CONFIG:Release>:-fno-stack-protector>" "$<$<COMPILE_LANGUAGE:CXX>:-U_FORTIFY_SOURCE>")\\n' >>{CM}""",
           [rf"cpp-harden: {UNIT} stack-protector-off"]),
    "t3": (CPP, f"""printf '\\nset_property(TARGET hypr-de-scene-impl PROPERTY LINK_OPTIONS "")\\n' >>{CM}""", [rf"cpp-harden: {IMPL} elf-lazy-binding"]),
    # a library the package builds and never installs ships nothing, so its compiles are not held to the shipping set; d1b installs it
    "d1": (CPP, f"""mkdir -p tools/probe
printf 'cmake_minimum_required(VERSION 3.27)\\nproject(probe LANGUAGES CXX)\\nadd_library(probe SHARED main.cpp)\\ntarget_compile_options(probe PRIVATE -fno-stack-protector -O0)\\n' >tools/probe/CMakeLists.txt
printf 'extern "C" int probe(long v) {{ int small = v; return small; }}\\n' >tools/probe/main.cpp
printf 'tools/probe/CMakeLists.txt\\tmake\\ntools/probe/main.cpp\\tcpp-test\\n' >>tests/gates/classified.tsv
sort -o tests/gates/classified.tsv tests/gates/classified.tsv
sed -i 's|^  cmake --build build$|&\\n  cmake -S tools/probe -B build-probe -DCMAKE_BUILD_TYPE=Release\\n  cmake --build build-probe|' {SCENE}""",
           [], {"exact": True}),
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
    "f1": (CPP, f"""cat >{PLUGIN}/swap.sh <<'EOF'
id=$(readelf -nW "$1" | sed -n 's/.*Build ID: //p')
printf '%s\\n' '{BLOB}' >"$1.cpp"
/usr/bin/c++ -x c++ -shared -fPIC -O0 -fno-stack-protector -Wl,-z,relro,-z,now,-z,noexecstack "-Wl,--build-id=0x$id" -o "$1" "$1.cpp"
EOF
printf '\\nadd_custom_command(TARGET hypr-de-scene-impl POST_BUILD COMMAND sh ${{CMAKE_CURRENT_SOURCE_DIR}}/swap.sh $<TARGET_FILE:hypr-de-scene-impl>)\\n' >>{CM}""",
           [rf"cpp-harden: {IMPL} unattributed"], {"check": False}),
    # the warnings are read from what each compile wrote, so a build() that throws its output away keeps every count
    "w1": (CPP, f"""sed -i 's|^  cmake --build build$|  cmake --build build >/dev/null 2>\\&1|' {SCENE}""", []),
    "c1": (["classify", "shell"], """mkdir -p dist/lib
printf 'cleanup() { rm -rf $1/cache; }\\n' >dist/lib/util.lib
printf 'cleanup() { rm -rf $1/cache; }\\n' >dist/lib/util.zsh
printf '#!/usr/bin/env zsh\\nrm -rf $1/x\\n' >dist/lib/run.zsh
sed -i 's|^%files|%post\\nrm -rf $1/cache\\n\\n%files|' packaging/hypr-de-scene.spec""",
           [r"classify: dist/lib/util\.lib unclassified", r"classify: dist/lib/util\.zsh unclassified", r"shell: dist/lib/run\.zsh unlintable-shell",
            r"shell: packaging/hypr-de-scene\.spec SC2086"]),
    "c2": (["shell"], """sed -i 's|^%files|%post -p /usr/bin/zsh\\nrm -rf $1/cache\\n\\n%files|' packaging/hypr-de-scene.spec""",
           [r"shell: packaging/hypr-de-scene\.spec unlintable-shell"]),
    # round 4: a build step that rewrites the records or the shim, or speaks the socket from a process that never ran the shim
    "r1": (CPP, f"""cat >{PLUGIN}/tamper.sh <<'EOF'
sed -i '/^#define __VERSION__/a #define __SSP_STRONG__ 3' "$HOME"/records/*.i "$HOME"/../records/*.i 2>/dev/null
echo 'raise SystemExit(0)' >>"$HOME/../shim.py" 2>/dev/null
true
EOF
cat >>{CM} <<'EOF'

target_compile_options(hypr-de-scene-impl PRIVATE -fno-stack-protector)
add_custom_command(TARGET hypr-de-scene-impl POST_BUILD COMMAND sh ${{CMAKE_CURRENT_SOURCE_DIR}}/tamper.sh VERBATIM)
EOF""", [rf"cpp-harden: {UNIT} stack-protector-off"]),
    "r2": (CPP, f"""cat >{PLUGIN}/forge.py <<'EOF'
import json
import os
import socket

for message in (json.dumps({{"cwd": "/", "compiler": "/usr/bin/c++", "argv": [], "jobs": [], "status": 0, "diagnostics": "", "sources": 0}}).encode(), b"{{not json"):
    with socket.socket(socket.AF_UNIX) as conn:
        conn.connect(os.path.join(os.environ["HOME"], "..", "records.sock"))
        conn.sendall(message)
EOF
printf '\nadd_custom_command(TARGET hypr-de-scene-impl POST_BUILD COMMAND python3 ${{CMAKE_CURRENT_SOURCE_DIR}}/forge.py)\n' >>{CM}""",
           [rf"cpp-harden: {SCENE} forged-record"]),
    # a compiler named by path runs outside the shim: the trace says so once per package, and nothing else is printed
    "r4": (CPP, f"""sed -i 's|^  cmake -S plugins/hypr-de-scene -B build|& -DCMAKE_CXX_COMPILER=/usr/bin/g++|' {SCENE}""",
           [rf"cpp-harden: {SCENE} unshimmed", r"cpp-harden: @hypr-de-scene/usr/lib/hypr-de/\S+ unattributed"], {"exact": True, "check": False}),
    # --version, --help and a call with two sources go through the shim without failing the build or leaving a broken record
    "r5": (CPP, f"""cat >../r5.sh <<'EOF'
  c++ --version >/dev/null
  c++ --help >/dev/null
  printf 'int a() {{ return 1; }}\\n' >a.cpp
  printf 'int b() {{ return 2; }}\\n' >b.cpp
  c++ -c a.cpp b.cpp
EOF
sed -i '/^  cmake --build build$/r ../r5.sh' {SCENE}
printf '\nenable_language(ASM)\n' >>{CM}""", []),
    # an optimize pragma left open by a header outside the tree, included after the glibc headers
    "v1": (CPP, f"""chmod 755 ..
mkdir -p ../vendor/vendor
printf '#pragma GCC optimize ("O0")\\n' >../vendor/vendor/vendor.h
chmod -R a+rX ../vendor
sed -i '0,/#include <regex>/s||#include <regex>\\n#include <cstring>\\n#include <cstdlib>\\n#include <vendor/vendor.h>|' {PLUGIN}/src/Spec.cpp
printf '\\ntarget_include_directories(hypr-de-scene-impl PRIVATE %s/../vendor)\\n' "$PWD" >>{CM}""",
           [rf"cpp-harden: {PLUGIN}/src/Spec\.cpp pragma-unbalanced"], {"check": False}),
    "cet1": (CPP, f"""cat >>{PLUGIN}/src/Spec.cpp <<'EOF'

extern "C" __attribute__((nocf_check, used, visibility("default"))) int gate_probe_nocf(int v) {{ return v * 3; }}
EOF""", [rf"cpp-harden: {PLUGIN}/src/Spec\.cpp source-weakens: attribute nocf_check"], {"check": False}),
    "cet2": (CPP, f"""printf '\\ntarget_compile_options(hypr-de-scene-impl PRIVATE -mmanual-endbr)\\n' >>{CM}""", [rf"cpp-harden: {UNIT} manual-endbr"]),
    "m1": (CPP, f"""sed -i 's|^  install -Dm644 LICENSE.*$|&\\n  chmod 4755 "$pkgdir/usr/lib/hypr-de/hypr-de-scene.so"|' {SCENE}""",
           [r"cpp-harden: @hypr-de-scene/usr/lib/hypr-de/hypr-de-scene\.so mode-setid"]),
    "n1": (CPP, f"""cat >>{CM} <<'EOF'

add_library(helper SHARED src/Log.cpp)
target_include_directories(helper PRIVATE ${{headers_INCLUDE_DIRS}})
target_link_options(helper PRIVATE -Wl,-soname,/tmp/hypr-de-helper.so)
target_link_libraries(hypr-de-scene-impl PRIVATE helper)
EOF""", [rf"cpp-harden: {IMPL} needed-undeclared"]),
    "g1": (CPP, f"""printf '\\nextern "C" void __stack_chk_fail() {{}}\\n' >>{PLUGIN}/src/Spec.cpp""",
           [rf"cpp-harden: {PLUGIN}/src/Spec\.cpp defines-guard:__stack_chk_fail"]),
    # an install scriptlet that writes the library from a base64 blob shipped as data
    "s1": (["classify", *CPP], f"""printf '%s\\n' '#include <cstring>' 'extern "C" int gate_blob(char *s) {{ char b[8]; strcpy(b, s); return b[0]; }}' >../blob.cpp
c++ -shared -fPIC -O0 -x c++ ../blob.cpp -o ../blob.so
mkdir -p {PLUGIN}/data
base64 -w76 ../blob.so >{PLUGIN}/data/blob.txt
cat >packaging/hypr-de-scene/hypr-de-scene.install <<'EOF'
post_install() {{
    base64 -d /usr/share/hypr-de-scene/blob.txt >/usr/lib/hypr-de/hypr-de-scene-impl.so
}}

post_upgrade() {{
    post_install
}}
EOF
sed -i 's|^source=|install=hypr-de-scene.install\\nsource=|' {SCENE}
sed -i 's|^  install -Dm644 LICENSE.*$|&\\n  install -Dm644 plugins/hypr-de-scene/data/blob.txt "$pkgdir/usr/share/hypr-de-scene/blob.txt"|' {SCENE}""",
           [rf"classify: {PLUGIN}/data/blob\.txt opaque", r"cpp-harden: packaging/hypr-de-scene/hypr-de-scene\.install scriptlet-writes-shipped"]),
    "p1": (["classify"], f"""mkdir -p packaging/hypr-de-scene-git
sed -e 's|^pkgname=.*|pkgname=hypr-de-scene-git|' {SCENE} >packaging/hypr-de-scene-git/PKGBUILD
printf 'packaging/hypr-de-scene-git/PKGBUILD\\tdata\\n' >>tests/gates/classified.tsv
LC_ALL=C sort -o tests/gates/classified.tsv tests/gates/classified.tsv""",
           [r"classify: packaging/hypr-de-scene-git/PKGBUILD packaging-class"]),
    "p2": (["classify"], """sed -i 's|^%cmake -S plugins/hypr-de-scene$|& -DCMAKE_CXX_FLAGS=-fno-stack-protector|' packaging/hypr-de-scene.spec
sed -i 's|^%cmake_build$|sed -i /Safety.cmake/d plugins/hypr-de-scene/CMakeLists.txt\\n&|' packaging/hypr-de-scene.spec
sed -i '1i %global _hardened_build 0' packaging/hypr-de-scene.spec""",
           [r"classify: packaging/hypr-de-scene\.spec spec-build-step", r"classify: packaging/hypr-de-scene\.spec spec-flags"]),
    # one baselined warning fixed and another of the same rule added in the same file
    "k0": (["shell"], """sed -i 's/^\\[ \\$# -eq 1 \\] || usage$/[[ $# -eq 1 ]] || usage\\n[ -n "$1" ] || usage/' dist/bin/hypr-de-set-wallpaper""",
           [r"shell: dist/bin/hypr-de-set-wallpaper SC2292"]),
    "k1": (["ratchet"], """awk -F'\\t' 'BEGIN { OFS = "\\t" } NR == 1 { $5 = $5 + 1 } 1' tests/gates/baseline.tsv >x && mv x tests/gates/baseline.tsv""",
           [r"ratchet: baseline cpp-harden packaging/hypr-de-scene/PKGBUILD warning-off:-Wno-unused-parameter"]),
    "k2": (["ratchet"], """python3 - <<'EOF'
import hashlib
rows = open("tests/gates/baseline.tsv", encoding="utf-8").read().splitlines()
fields = rows[0].split("\\t")
fields[5] = "-Wno-shadow"
fields[3] = hashlib.sha256(fields[5].encode()).hexdigest()[:16]
rows[0] = "\\t".join(fields)
open("tests/gates/baseline.tsv", "w", encoding="utf-8").write("\\n".join(rows) + "\\n")
EOF""", [r"ratchet: baseline cpp-harden packaging/hypr-de-scene/PKGBUILD warning-off:-Wno-unused-parameter"]),
    "k3": (["ratchet"], """sed -i 's|^dist/uwsm/env\\tsh$|dist/uwsm/env\\tdata|' tests/gates/classified.tsv""", [r"ratchet: classified dist/uwsm/env"]),
    "k4": (["ratchet"], """printf 'disable=SC2086\\n' >>.shellcheckrc""", [r"ratchet: config \.shellcheckrc"]),
    # a new rule that baselines its existing hits passes with its reason, and fails without one
    "k5": (["ratchet"], RATCHET_ROW, [], {"env": {"GATE_CHANGE_REASONS": "Gate-change: SC9999 is new in this shellcheck; its one hit is baselined"}}),
    "k6": (["ratchet"], RATCHET_ROW, [r"ratchet: baseline shell dist/uwsm/env SC9999"]),
    "t9": (CPP, """mkdir ../nocmake
for f in /usr/bin/*; do [ "${f##*/}" = cmake ] || ln -s "$f" ../nocmake/; done""",
           [r"cpp-harden: toolchain cannot-run"], {"env": {"PATH": "{work}/nocmake"}, "exact": True}),
    # a file git does not track is not part of what a local run judges
    "u1": (["classify"], """printf 'x\\n' >scratch.out""", [], {"add": False}),
    # round 5, F1: a baselined finding follows its line through an edit, and the ratchet takes the row --update rewrites
    "f1a": (["cpp-harden", "cpp-tidy"], rf"""sed -i 's|^\( *return static_cast<int>(x + 0\.5);\)$|\1 // round half up|' {GEOMETRY}""", [], {"exact": True}),
    "f1b": (["shell"], QUOTED, [], {"exact": True}),
    "f1c": (["shell", "ratchet"], QUOTED + "\ntests/gates/check.sh shell --update >/dev/null || true", [], {"exact": True}),
    # F2: the PKGBUILD's cmake line may change its order and generator, or hold its options in an array
    "f2": (["classify"], f"""sed -i 's|^  cmake -S plugins/hypr-de-scene -B build .*$|  local _opts=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr)\\n  cmake -G "Unix Makefiles" -B build -S plugins/hypr-de-scene "${{_opts[@]}}"|' {SCENE}""",
           [], {"exact": True}),
    # F3: a new test source needs no reason, and a cpp-test row on a file that is not C or C++ fails
    "f3": (["classify", "ratchet"], f"""printf 'int main() {{ return 0; }}\\n' >{PLUGIN}/tests/clamp.cpp
printf '{PLUGIN}/tests/clamp.cpp\\tcpp-test\\n' >>tests/gates/classified.tsv
LC_ALL=C sort -o tests/gates/classified.tsv tests/gates/classified.tsv""", [], {"exact": True}),
    "f3b": (["classify"], f"""printf 'echo hi\\n' >{PLUGIN}/tests/helper
printf '{PLUGIN}/tests/helper\\tcpp-test\\n' >>tests/gates/classified.tsv
LC_ALL=C sort -o tests/gates/classified.tsv tests/gates/classified.tsv""", [rf"classify: {PLUGIN}/tests/helper invalid"]),
    # F4: a compiler stage from the build's own tree, through -B, or a specs file named in a response file
    "f4a": (CPP, f"""mkdir -p {PLUGIN}/tools
cat >{PLUGIN}/tools/cc1plus <<'EOF'
{CC1PLUS}EOF
chmod 755 {PLUGIN}/tools/cc1plus
printf '{PLUGIN}/tools/cc1plus\\tsh\\n' >>tests/gates/classified.tsv
LC_ALL=C sort -o tests/gates/classified.tsv tests/gates/classified.tsv
printf '\\ntarget_compile_options(hypr-de-scene-impl PRIVATE -B${{CMAKE_CURRENT_SOURCE_DIR}}/tools/)\\n' >>{CM}""",
            [rf"cpp-harden: {SCENE} driver-override", rf"cpp-harden: {SCENE} untrusted-tool"]),
    "f4b": (CPP, f"""printf '*cc1plus:\\n+ %%{{!E:-fno-stack-protector}}\\n\\n' >{PLUGIN}/weak.specs
printf '{PLUGIN}/weak.specs\\tdata\\n' >>tests/gates/classified.tsv
LC_ALL=C sort -o tests/gates/classified.tsv tests/gates/classified.tsv
cat >>{CM} <<'EOF'

file(WRITE ${{CMAKE_CURRENT_BINARY_DIR}}/opts.rsp "-specs=${{CMAKE_CURRENT_SOURCE_DIR}}/weak.specs\\n")
target_compile_options(hypr-de-scene-impl PRIVATE @${{CMAKE_CURRENT_BINARY_DIR}}/opts.rsp)
EOF""", [rf"cpp-harden: {SCENE} driver-override"]),
    # the wrappers drop GCC_EXEC_PREFIX, so the tree's cc1plus, which fails any compile it is given, never runs
    "f4c": (CPP, f"""triple=$(gcc -dumpmachine) version=$(gcc -dumpversion)
mkdir -p "{PLUGIN}/tools/$triple/$version"
printf '#!/bin/sh\\necho "the tree'"'"'s cc1plus ran" >&2\\nexit 1\\n' >"{PLUGIN}/tools/$triple/$version/cc1plus"
chmod 755 "{PLUGIN}/tools/$triple/$version/cc1plus"
printf '%s\\tsh\\n' "{PLUGIN}/tools/$triple/$version/cc1plus" >>tests/gates/classified.tsv
LC_ALL=C sort -o tests/gates/classified.tsv tests/gates/classified.tsv
sed -i 's|^  cmake -S plugins/hypr-de-scene|  export GCC_EXEC_PREFIX="$PWD/{PLUGIN}/tools/"\\n&|' {SCENE}""", [], {"exact": True}),
    # F5: features.h has set __USE_FORTIFY_LEVEL, and the source takes it away before string.h reads it
    "f5": (CPP, f"""sed -i '1i #include <features.h>\\n#undef __USE_FORTIFY_LEVEL\\n#include <string.h>' {GEOMETRY}""",
           [rf"cpp-harden: {PLUGIN}/src/Geometry\.cpp fortify-off"]),
    # F6: check() runs in the audited build, so its change to the built library's code shows
    "f6a": (CPP, PATCH.format(scene=SCENE, after="./tests/scene-plugin-build.sh", section=".text"), [rf"cpp-harden: {IMPL} unattributed"]),
    # and a change to its data after the link shows as well as one to its code
    "f6b": (CPP, PATCH.format(scene=SCENE, after="cmake --build build", section=".rodata"), [rf"cpp-harden: {IMPL} unattributed"]),
    # a check() that fails under the trace: the main package, which ships no ELF file, is judged from an untraced build,
    # and the plugin keeps its failure. f6c's check() is only that probe, so the main package's own tests cannot decide it
    "f6c": (CPP, """sed -i '/^check() {$/,/^}$/c check() {\\n  grep -q "^TracerPid:[[:space:]]*0$" /proc/self/status\\n}' packaging/PKGBUILD""", [],
            {"exact": True, "pkgbuild": "packaging/PKGBUILD", "out": [r"note cpp-harden: packaging/PKGBUILD: makepkg failed under the trace and passed without it"]}),
    "f6d": (CPP, f"""sed -i 's|^  ./tests/scene-plugin-build.sh$|&\\n  grep -q "^TracerPid:[[:space:]]*0$" /proc/self/status|' {SCENE}""",
            [rf"cpp-harden: {SCENE} build-failed"]),
    # F7: the gates, the workflows and CODEOWNERS are configuration, and the base's ratchet judges a pull request that rewrites it
    "f7a": (["ratchet"], """sed -i 's/"cannot-run", "forged-record"/"cannot-run"/' tests/gates/gate.py
sed -i '/^\\/tests\\/gates\\//d' .github/CODEOWNERS
sed -i '/# What the gates allow only shrinks/,$d' .github/workflows/safety-gates.yml""",
            [r"ratchet: config tests/gates/gate\.py", r"ratchet: config \.github/CODEOWNERS", r"ratchet: config \.github/workflows/safety-gates\.yml"]),
    "f7b": (["ratchet"], RATCHET_ROW + """
printf 'print("ok   ratchet: nothing the gates allow has grown")\\n' >tests/gates/ratchet.py""",
            [r"ratchet: baseline shell dist/uwsm/env SC9999", r"ratchet: config tests/gates/ratchet\.py"]),
    # F8: a loosening with its reason is a warning on the run and a line in its summary
    "f8": (["ratchet"], RATCHET_ROW, [], {"env": {"GATE_CHANGE_REASONS": "Gate-change: SC9999 is new", "GITHUB_ACTIONS": "true", "GITHUB_STEP_SUMMARY": "{work}/summary"},
                                          "out": [r"::warning title=Gate loosened::baseline shell dist/uwsm/env SC9999"]}),
    # F10: a spec's build sections hold only %autosetup, %cmake -S, %cmake_build and %cmake_install, %conf included
    "f10a": (["classify"], """sed -i 's|^%cmake -S plugins/hypr-de-scene$|%{__cmake} -S plugins/hypr-de-scene -DCMAKE_CXX_FLAGS=-fno-stack-protector|' packaging/hypr-de-scene.spec""",
             [r"classify: packaging/hypr-de-scene\.spec spec-build-step"]),
    "f10b": (["classify"], """sed -i 's|^%cmake_build$|%cmake_build -- CXX_FLAGS="-O0 -w"|' packaging/hypr-de-scene.spec""",
             [r"classify: packaging/hypr-de-scene\.spec spec-build-step"]),
    "f10c": (["classify"], """sed -i 's|^%build$|%conf\\n%cmake -S plugins/hypr-de-scene -DCMAKE_BUILD_TYPE=Debug\\n\\n%build|; /^%cmake -S plugins\\/hypr-de-scene$/d' packaging/hypr-de-scene.spec""",
             [r"classify: packaging/hypr-de-scene\.spec spec-build-step"]),
    # round 6, finding 1: a new test source compiled alone in check() is a test's compile, not one the package ships
    "h1": (["classify", "shell", "cpp-harden", "cpp-tidy", "ratchet"], CLAMP, [], {"exact": True}),
    # finding 2: without annobin's notes annocheck cannot see how a compile ran, so an RPM without them fails; a spec that turns them off fails classify
    "h2a": (["rpm"], TOY.format(**{**LIBTOY, "macros": "%undefine _annotated_build", "cflags": "-fno-stack-protector"}),
            [r"rpm: @gate-toy/usr/lib64/libtoy\.so annobin-missing"], RPM),
    # Fedora asks only whether _annotated_build is defined, so a 0 leaves the notes on and annocheck still sees the weakening
    "h2b": (["rpm"], TOY.format(**{**LIBTOY, "macros": "%global _annotated_build 0", "cflags": "-fno-stack-protector"}),
            [r"rpm: @gate-toy/usr/lib64/libtoy\.so annocheck:stack-prot"], RPM),
    "h2ctl": (["rpm"], TOY.format(**LIBTOY), [], {**RPM, "exact": True}),
    "h2c": (["classify"], f"""sed -i '1i %undefine _annotated_build' {SCENE_SPEC}""", [rf"classify: {SCENE_SPEC} spec-flags"]),
    "h2d": (["classify"], f"""sed -i '1i %global _annotated_build 0' {SCENE_SPEC}""", [rf"classify: {SCENE_SPEC} spec-flags"]),
    # finding 3: an audit of no ELF file is no audit: the debuginfo alone, or an architecture's RPM that ships none
    "h3a": (["rpm"], TOY.format(**{**LIBTOY, "pick": "*-debuginfo-*.rpm"}), [r"rpm: rpm cannot-run"], RPM),
    "h3b": (["rpm"], TOY.format(**{**LIBTOY, "macros": "%global debug_package %{nil}", "install": "install -Dm644 toy.c %{buildroot}%{_datadir}/gate-toy/toy.c",
                                   "files": "%{_datadir}/gate-toy/toy.c"}), [r"rpm: @gate-toy no-elf"], RPM),
    # finding 4: a formatter's re-wrap of a baselined statement keeps its rows, and --update writes rows the ratchet takes
    "h4a": (["cpp-tidy", "ratchet"], REWRAP + f"\ntests/gates/check.sh cpp-tidy --update --pkgbuild {SCENE} >/dev/null || true", [], {"exact": True, "check": False}),
    "h4b": (["shell", "ratchet"], SHELLWRAP + "\ntests/gates/check.sh shell --update >/dev/null || true", [], {"exact": True}),
    "h4c": (["shell"], SHELLWRAP, [], {"exact": True}),
    # and a fixed finding beside a new one of its rule fails once, with the one hint that fits
    "h4d": (["shell"], K0, [r"shell: dist/bin/hypr-de-set-wallpaper SC2292"], {"absent": [r"FAIL .*lower it with --update"], "out": [r".*--update --allow-growth"]}),
    # round 8: a whole formatter run over the tree keeps every row, in the gate CI runs and after --update in the ratchet, with no
    # Gate-change: reason, and a new finding of a moved row's rule in the same file and the same edit still fails with the growth hint
    "h4e": (["cpp-tidy"], CLANG_FORMAT, [], {"exact": True, "check": False, "needs": ["clang-format"]}),
    "h4f": (["cpp-tidy", "ratchet"], CLANG_FORMAT + f"\ntests/gates/check.sh cpp-tidy --update --pkgbuild {SCENE} >/dev/null || true", [],
            {"exact": True, "check": False, "needs": ["clang-format"]}),
    "h4g": (["cpp-tidy"], NEW_ACCESS + CLANG_FORMAT, [rf"cpp-tidy: {PLUGIN}/src/Scene\.cpp cppcoreguidelines-pro-bounds-avoid-unchecked-container-access"],
            {**GROWN, "check": False, "needs": ["clang-format"]}),
    "h4h": (["shell"], SHFMT.replace("FLAGS", ""), [], {"exact": True, "needs": ["shfmt"]}),
    "h4i": (["shell", "ratchet"], SHFMT.replace("FLAGS", "") + "\ntests/gates/check.sh shell --update >/dev/null || true", [], {"exact": True, "needs": ["shfmt"]}),
    "h4j": (["shell"], NEW_CHAIN + SHFMT.replace("FLAGS", ""), [r"shell: tests/lock-listener\.sh SC2015"], {**GROWN, "needs": ["shfmt"]}),
    "h4k": (["shell"], SHFMT.replace("FLAGS", "-bn -ci"), [], {"exact": True, "needs": ["shfmt"]}),
    "h4l": (["shell", "ratchet"], SHFMT.replace("FLAGS", "-bn -ci") + "\ntests/gates/check.sh shell --update >/dev/null || true", [], {"exact": True, "needs": ["shfmt"]}),
    "h4m": (["shell"], NEW_CHAIN + SHFMT.replace("FLAGS", "-bn -ci"), [r"shell: tests/lock-listener\.sh SC2015"], {**GROWN, "needs": ["shfmt"]}),
    # finding 7: -wrapper is not among the options GCC reports, but the wrapper the build wrote is a program the build user could have written
    "h7": (CPP, f"""mkdir -p {PLUGIN}/tools
printf '#!/bin/sh\\nexec "$@"\\n' >{PLUGIN}/tools/wrap.sh
chmod 755 {PLUGIN}/tools/wrap.sh
printf '{PLUGIN}/tools/wrap.sh\\tsh\\n' >>tests/gates/classified.tsv
LC_ALL=C sort -o tests/gates/classified.tsv tests/gates/classified.tsv
printf '\\ntarget_compile_options(hypr-de-scene-impl PRIVATE "SHELL:-wrapper ${{CMAKE_CURRENT_SOURCE_DIR}}/tools/wrap.sh")\\n' >>{CM}""",
           [rf"cpp-harden: {SCENE} untrusted-tool"], {"check": False}),
    # finding 8: -Bsymbolic-functions given to the driver is -B and a directory to GCC, and the FAIL says how to give it to the linker
    "h8": (CPP, f"""printf '\\ntarget_link_options(hypr-de-scene-impl PRIVATE -Bsymbolic-functions)\\n' >>{CM}""",
           [rf"cpp-harden: {SCENE} driver-override"], {"out": [r".*-Wl,-Bsymbolic-functions"], "check": False}),
}


def attempt(name, root):
    gates, change, expected, *rest = CASES[name]
    options = rest[0] if rest else {}
    absent = [tool for tool in options.get("needs", []) if not shutil.which(tool)]
    if absent:
        return None, f"skip {name}\n     not run here: needs {' '.join(absent)}"
    work = tempfile.mkdtemp(prefix=f"gate-attack-{name}-")
    try:
        clone = os.path.join(work, "clone")
        subprocess.run(["git", "clone", "-q", "--no-hardlinks", root, clone], check=True)
        made = subprocess.run(["bash", "-euc", change + ("" if options.get("check", True) else f"\nsed -i '/^check() {{$/,/^}}$/d' {SCENE}")],
                              cwd=clone, capture_output=True, text=True, check=False)
        if made.returncode:
            return False, f"MISS {name}\n     the change did not apply: {made.stderr.strip()}"
        if options.get("add", True):
            subprocess.run(["git", "add", "-A"], cwd=clone, check=True)
        env = {**os.environ, **{key: value.format(work=work) for key, value in options.get("env", {}).items()}}
        others = [gate for gate in gates if gate != "ratchet"]
        results = [*([ratchet(clone, work, env)] if "ratchet" in gates else []), *([gate_run(others, clone, env, options.get("pkgbuild", SCENE), options.get("rpms"))] if others else [])]
        stdout, stderr = "".join(r.stdout for r in results), "".join(r.stderr for r in results)
        failed = any(r.returncode for r in results)
        lines = [line for line in stdout.splitlines() if line.startswith(("FAIL ", "gate:"))] + stderr.splitlines()[-3:]
        missing = [pattern for pattern in expected if not any(re.match(rf"FAIL {pattern}:", line) for line in lines)]
        shown = [line for line in lines if any(re.match(rf"FAIL {pattern}:", line) for pattern in expected)]
        extra = [line for line in lines if line.startswith("FAIL ") and line not in shown] if options.get("exact") else []
        unseen = [pattern for pattern in options.get("out", []) if not any(re.match(pattern, line) for line in stdout.splitlines())]
        unwanted = [line for line in stdout.splitlines() if any(re.match(pattern, line) for pattern in options.get("absent", []))]
        ok = not missing and not extra and not unseen and not unwanted and failed == bool(expected)
        report = [f"{'ok  ' if ok else 'MISS'} {name}", *(f"     {line}" for line in (shown if ok else lines))]
        report += [f"     expected, not seen: {pattern}" for pattern in [*missing, *unseen]]
        report += [f"     not expected: {line}" for line in [*extra, *unwanted]]
        return ok, "\n".join(report)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def ratchet(clone, work, env):
    # CI runs the base branch's copy, so a pull request that rewrites the ratchet is still judged by the old one
    script = os.path.join(work, "ratchet.py")
    with open(script, "w", encoding="utf-8") as f:
        f.write(subprocess.run(["git", "show", "HEAD:tests/gates/ratchet.py"], cwd=clone, capture_output=True, text=True, check=True).stdout)
    return subprocess.run(["python3", "-I", script, "HEAD"], cwd=clone, capture_output=True, text=True, check=False, env=env)


def gate_run(gates, clone, env, pkgbuild, rpms):
    # the C++ gates build only the package a case changes, the plugin's unless it says otherwise, three cases at a time
    only = ["--pkgbuild", pkgbuild] if {"cpp-harden", "cpp-tidy"} & set(gates) else []
    given = ["--rpms", *sorted(glob.glob(os.path.join(clone, rpms)))] if rpms else []
    return subprocess.run(["tests/gates/check.sh", *gates, *only, *given], cwd=clone, capture_output=True, text=True, check=False, env=env)


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
    failed, skipped = sum(ok is False for ok, _report in results), sum(ok is None for ok, _report in results)
    print(f"{len(results) - failed - skipped}/{len(results) - skipped} cases as expected", end="")
    # the rpm cases need Fedora's rpmbuild and annocheck, which the C++ gates' container has not; they are a separate run, never a pass
    print(f", and {skipped} not run here: run them where rpmbuild and annocheck are, as the rpm job in scene-plugin.yml" if skipped else "")
    sys.exit(1 if failed else 0)


main()

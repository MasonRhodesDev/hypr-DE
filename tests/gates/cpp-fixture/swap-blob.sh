#!/bin/sh
# swap-blob.sh LIBRARY SOURCE: replace LIBRARY with SOURCE built by the real compiler, under LIBRARY's build ID
set -eu
id=$(readelf -nW "$1" | sed -n 's/.*Build ID: //p')
/usr/bin/c++ -x c++ -shared -fPIC -O0 -fno-stack-protector -Wl,-z,relro,-z,now,-z,noexecstack "-Wl,--build-id=0x${id}" -o "$1" "$2"

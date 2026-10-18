#!/bin/sh
set -eu

base_rev=$1
work=$2
libs="singularity singularity-system"

mkdir "$work"

build() {
    meson setup "$work/$1-build" "$2" -Dintrospection=false -Dsharing-host=false --buildtype=debug >/dev/null
    meson compile -C "$work/$1-build" $libs
    mkdir "$work/$1-headers"
    cp "$work/$1-build/singularity.h" "$work/$1-build/singularity-system.h" "$work/$1-headers/"
}

soname() {
    readelf -d "$1" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p'
}

git worktree add --detach "$work/base" "$base_rev" >/dev/null
build base "$work/base"
build head "$PWD"

status=0
for lib in libsingularity.so libsingularity-system.so; do
    old=$(readlink -f "$work/base-build/$lib")
    new=$(readlink -f "$work/head-build/$lib")
    if [ "$(soname "$old")" != "$(soname "$new")" ]; then
        echo "$lib: soname changed from $(soname "$old") to $(soname "$new"), incompatible changes are allowed"
        continue
    fi
    rc=0
    abidiff --no-added-syms --hd1 "$work/base-headers" --hd2 "$work/head-headers" "$old" "$new" || rc=$?
    if [ $((rc & 3)) -ne 0 ]; then
        echo "$lib: abidiff could not compare the libraries"
        status=1
    elif [ $((rc & 12)) -ne 0 ]; then
        echo "$lib: the ABI changed without a soversion bump; only additions are allowed in a minor release"
        status=1
    else
        echo "$lib: ABI compatible"
    fi
done

git worktree remove --force "$work/base"
exit $status

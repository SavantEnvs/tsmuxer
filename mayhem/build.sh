#!/usr/bin/env bash
#
# mayhem/build.sh — build tsMuxer's TS-demux fuzz target + its oracle.
#
#   build/fuzz_ts_detect             sanitized + libFuzzer   -> target `ts_detect`
#   build/fuzz_ts_detect-standalone  sanitized + DWARF       -> run-once reproducer
#   build-oracle/tsMuxer/tsmuxer     normal flags (upstream's own CMake build), used by
#                                     mayhem/test.sh as a known-answer functional oracle
#
# tsMuxer/CMakeLists.txt builds ONE executable target ("tsmuxer") that bundles main.cpp with
# every demuxer/codec source file — there's no separate library target to link a harness
# against. So the fuzz build compiles the SAME source set CMake would (every tsMuxer/*.cpp
# except main.cpp, found dynamically so a future upstream file addition is picked up
# automatically) straight into each harness binary, instrumented with $SANITIZER_FLAGS. The
# oracle build instead just runs the project's own unmodified CMake build (matching how
# upstream/its CI builds it) so it stays an honest, unsanitized functional check.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS COVERAGE_FLAGS

cd "${SRC:=/mayhem}"
mkdir -p build

STD="-std=c++17"
INC="-Ilibmediation -ItsMuxer"
DEFS="-DTSMUXER_VERSION=\"mayhem-fuzz\""
# Same non-Windows deps upstream's own CMakeLists requires unconditionally for the CLI build
# (zlib + freetype2, via pkg-config) — nothing extra added for fuzzing.
PKG_CFLAGS="$(pkg-config --cflags zlib freetype2)"
PKG_LIBS="$(pkg-config --libs zlib freetype2)"
THREAD_FLAGS="-pthread"
# Two narrow, pervasive-but-benign UBSan findings that otherwise flood on ~every input, aborting
# before the fuzzer can explore anything (confirmed locally: both fire on the very first run).
# ASan and the rest of UBSan (signed-integer-overflow, shift, bounds, ...) stay ON and halting.
#   alignment         — tsMuxer/bitStream.h's getCurVal() reinterpret_casts into the middle of a
#                        byte buffer and dereferences it as `unsigned*`: a deliberate unaligned
#                        read used on every parsed bit-field, not a defect.
#   nonnull-attribute — PMTStreamInfo's ctor (tsMuxer/tsPacket.h) calls memcpy(dst, esInfoData, 0)
#                        when esInfoLen==0 and esInfoData is null; glibc annotates memcpy's 2nd arg
#                        `nonnull` even for a zero-length copy, which is a well-known UBSan false
#                        positive, not a real bug.
UBSAN_RELAX="-fno-sanitize=alignment,nonnull-attribute"

# Every tsMuxer/*.cpp EXCEPT main.cpp (our harness supplies its own entry point), plus the
# non-Windows text-subtitle renderer CMake adds on Linux/Mac, plus libmediation's small support
# library (types, terminatable-thread, POSIX fs). Discovered with find (not hardcoded) so a
# weekly upstream sync that adds a new demuxer/codec file keeps building it in automatically.
mapfile -t TSMUXER_SRC < <(find tsMuxer -maxdepth 1 -name '*.cpp' ! -name main.cpp | sort)
TSMUXER_SRC+=(tsMuxer/osdep/textSubtitlesRenderFT.cpp)
MEDIATION_SRC=(libmediation/types/types.cpp libmediation/system/terminatablethread.cpp
              libmediation/fs/osdep/file_unix.cpp libmediation/fs/osdep/directory_unix.cpp)
LIB=("${TSMUXER_SRC[@]}" "${MEDIATION_SRC[@]}")

# LeakSanitizer off at build time (ASan/UBSan stay on and halting); fleet policy, SPEC §6.2 item 15.
LSAN_OFF=build/lsan_off.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$LSAN_OFF"

# 1) Sanitized libFuzzer binary. $DEBUG_FLAGS after $SANITIZER_FLAGS so -gdwarf-3 wins (DWARF < 4).
#    $UBSAN_RELAX comes AFTER $SANITIZER_FLAGS so it wins over the `undefined` group default.
# shellcheck disable=SC2086
$CXX $STD $SANITIZER_FLAGS $UBSAN_RELAX $DEBUG_FLAGS $LIB_FUZZING_ENGINE $DEFS $THREAD_FLAGS -w $INC $PKG_CFLAGS \
    mayhem/fuzz_ts_detect.cpp "${LIB[@]}" "$LSAN_OFF" $PKG_LIBS $THREAD_FLAGS -o build/fuzz_ts_detect

# 2) Standalone (non-fuzzer) run-once reproducer, same harness + sources, linked against the
#    base image's STANDALONE_FUZZ_MAIN driver instead of the libFuzzer engine. The driver is C
#    (no extern "C" needed there); compile it with $CC first so LLVMFuzzerTestOneInput keeps C
#    linkage when the C++ harness (which declares it extern "C") is linked against it.
$CC -c $SANITIZER_FLAGS $UBSAN_RELAX $DEBUG_FLAGS -w "$STANDALONE_FUZZ_MAIN" -o build/standalone_main.o
# shellcheck disable=SC2086
$CXX $STD $SANITIZER_FLAGS $UBSAN_RELAX $DEBUG_FLAGS $DEFS $THREAD_FLAGS -w $INC $PKG_CFLAGS \
    mayhem/fuzz_ts_detect.cpp "${LIB[@]}" "$LSAN_OFF" build/standalone_main.o $PKG_LIBS $THREAD_FLAGS \
    -o build/fuzz_ts_detect-standalone

# 3) Oracle: the project's OWN unmodified CMake build, normal flags, no sanitizers — exactly how
#    upstream's CI builds it (tsMuxer/CMakeLists.txt requires zlib + freetype2 unconditionally on
#    Linux, same as above). $COVERAGE_FLAGS is empty unless a coverage build requests it.
cmake -S . -B build-oracle -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" >/dev/null
cmake --build build-oracle -j"$MAYHEM_JOBS" --target tsmuxer >/dev/null

echo "build.sh: built build/fuzz_ts_detect(-standalone) and build-oracle/tsMuxer/tsmuxer"

#!/usr/bin/env bash
#
# mayhem/test.sh — functional (known-answer) oracle for tsMuxer's stream-detection path. RUNS the
# prebuilt clean CLI (build-oracle/tsMuxer/tsmuxer from mayhem/build.sh) only; never compiles.
#
# tsMuxer ships no functional test suite of its own (docs/TESTING.md just describes manual MD5
# comparisons against large, non-redistributable sample media — nothing offline/committable). So
# the oracle instead drives the project's REAL CLI, in its documented single-arg "identify this
# file" mode (`tsmuxer <file>`, tsMuxer/main.cpp argc==2 branch — the exact call the `ts_detect`
# fuzz target also exercises: METADemuxer::DetectStreamReader()), against a small synthetic H.264
# 160x120 + AC-3 mono transport stream (mayhem/ts_detect/testsuite/sample.ts, produced once
# offline with `ffmpeg -f lavfi ... -f mpegts`), and asserts the EXACT known-answer fields tsMuxer
# reports for it: both track IDs, the H.264 profile/resolution/frame-rate, the AC-3 bitrate/sample
# rate/channel count, and the stream duration. This is behavioral, not exit-code-only: a build that
# still runs but misparses/drops a field, or a no-op'd/neutered binary (sabotage shim -> exit 0,
# no output), fails every one of these checks.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

passed=0; failed=0
check() {  # check <label> <0-if-ok>
  if [ "$2" -eq 0 ]; then echo "  ok   - $1"; passed=$((passed+1)); else echo "  FAIL - $1"; failed=$((failed+1)); fi
}

emit_ctrf() {
  local tool="$1" p="$2" f="$3" s="${4:-0}"; local tests=$(( p + f + s ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": { "tests": $tests, "passed": $p, "failed": $f, "pending": 0, "skipped": $s, "other": 0 }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":0,"skipped":%d,"other":0}}}\n' \
    "$tool" "$tests" "$p" "$f" "$s"
  [ "$f" -eq 0 ]
}

TSMUXER=build-oracle/tsMuxer/tsmuxer
FIXTURE=mayhem/ts_detect/testsuite/sample.ts

if [ ! -x "$TSMUXER" ]; then
  echo "test.sh: $TSMUXER missing — build.sh must build it (not rebuilding here)" >&2
  emit_ctrf tsmuxer-cli 0 1; exit 1
fi
if [ ! -f "$FIXTURE" ]; then
  echo "test.sh: $FIXTURE missing" >&2
  emit_ctrf tsmuxer-cli 0 1; exit 1
fi

out="$("$TSMUXER" "$FIXTURE" 2>&1)"; rc=$?
echo "$out"

check "tsmuxer exits 0 on a well-formed .ts" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
check "detects video Track ID 256"          "$(grep -q 'Track ID:    256'                                   <<<"$out" && echo 0 || echo 1)"
check "detects H.264 video stream"          "$(grep -q 'Stream type: H.264'                                 <<<"$out" && echo 0 || echo 1)"
check "H.264 profile/resolution/frame rate" "$(grep -q 'Profile: Baseline@1.1  Resolution: 160:120p  Frame rate: 25' <<<"$out" && echo 0 || echo 1)"
check "detects audio Track ID 257"          "$(grep -q 'Track ID:    257'                                   <<<"$out" && echo 0 || echo 1)"
check "detects AC3 audio stream"            "$(grep -q 'Stream type: AC3'                                   <<<"$out" && echo 0 || echo 1)"
check "AC3 bitrate/sample-rate/channels"    "$(grep -q 'Bitrate: 128Kbps Sample Rate: 48KHz Channels: 1'     <<<"$out" && echo 0 || echo 1)"
check "reports the stream duration"         "$(grep -q 'Duration: 00:00:00.960'                              <<<"$out" && echo 0 || echo 1)"

echo "test.sh: passed=$passed failed=$failed"
emit_ctrf tsmuxer-cli "$passed" "$failed"

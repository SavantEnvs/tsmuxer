// mayhem/fuzz_ts_detect.cpp — fuzz tsMuxer's transport-stream demux + elementary-stream
// detection path: METADemuxer::DetectStreamReader().
//
// This is the exact routine tsMuxer's own CLI runs on every input file before muxing
// (`tsmuxer <file>` -> tsMuxer/main.cpp's detectStreamReader() -> METADemuxer::DetectStreamReader()).
// For a ".ts" extension it selects TSDemuxer, pulls several blocks of demuxed PID data via
// AbstractDemuxer::simpleDemuxBlock(), then runs per-elementary-stream header detection
// (METADemuxer::detectTrackReader) across tsMuxer's video/audio codec probes (H.264, HEVC, VC-1,
// MPEG-2, AC3, AAC, DTS, MP3, LPCM, PGS, ...) — a single, well-scoped call site that still reaches
// a broad swath of the project's real parsing surface, matching the classic OSS-Fuzz "demux one
// container format" shape.
//
// DetectStreamReader takes a file PATH — it is a real file-based demuxer API, not an in-memory
// one — so per the porting guidance we stage the fuzzer's bytes under /dev/shm (the one writable
// location in the commit image) with a ".ts" suffix so METADemuxer's extension sniff picks the TS
// demuxer, run detection, then remove the temp file. No other filesystem I/O happens.
#define _GNU_SOURCE
#include <fcntl.h>
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <string>

#include "abstractDemuxer.h"
#include "bufferedReaderManager.h"
#include "metaDemuxer.h"
#include "vod_common.h"
#include "vodCoreException.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    // One fixed path per process, rewritten each input: a halting sanitizer abort leaves at most one
    // file behind per process instead of one per crash. ".ts" so METADemuxer's extension sniff picks TSDemuxer.
    static const std::string path = "/dev/shm/fuzz_ts_detect_" + std::to_string(getpid()) + ".ts";
    const int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0)
        return 0;

    size_t written = 0;
    while (written < size)
    {
        ssize_t n = write(fd, data + written, size - written);
        if (n <= 0)
            break;
        written += static_cast<size_t>(n);
    }
    close(fd);

    // A fresh manager per input: DetectStreamReader leaks its TSDemuxer when it throws, and the
    // demuxer's reader slot would otherwise stay registered in a shared manager across inputs.
    BufferedReaderManager readManager(2, DEFAULT_FILE_BLOCK_SIZE, DEFAULT_FILE_BLOCK_SIZE + MAX_AV_PACKET_SIZE,
                                      DEFAULT_FILE_BLOCK_SIZE / 2);

    try
    {
        // calcDuration=true matches the plain `tsmuxer <file>` CLI path (no MPLS parser), so the
        // fuzzed call also exercises getFileDurationNano().
        DetectStreamRez rez = METADemuxer::DetectStreamReader(readManager, path.c_str(), true);
        (void)rez;
    }
    catch (...)
    {
        // tsMuxer's own CLI wraps this exact call in try/catch(VodCoreException&)/catch(...) —
        // malformed input is expected to throw here; that is normal control flow, not a defect.
        // A real memory-safety bug aborts the process directly (ASan/UBSan), bypassing this catch.
    }

    unlink(path.c_str());
    return 0;
}

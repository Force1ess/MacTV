"""Offline diagnostic for probe-owned-vlc-audio.c's generated chirp only.

Requires NumPy for the independent FFT check. Not an application dependency.
Flush records delimit runs: concatenating across them would invent an overlap.
Reports measurements, not a replacement for the native continuity assertion.
"""
import json
import argparse
import pathlib
import struct
import sys

import numpy as np


def read_runs(path):
    data = path.read_bytes()
    if len(data) > 10_000_000:
        raise ValueError("Diagnostic exceeds owned probe size limit")
    cursor, runs, current = 0, [], []
    while cursor < len(data):
        if cursor + 12 > len(data):
            raise ValueError("Truncated diagnostic header")
        pts, count = struct.unpack_from("=qI", data, cursor)
        cursor += 12
        if count > 48000 or cursor + count * 2 > len(data):
            raise ValueError("Invalid or truncated diagnostic PCM")
        if not count:
            if current:
                runs.append(current)
                current = []
            continue
        pcm = np.frombuffer(data, dtype="<i2", count=count, offset=cursor).astype(float) / 32768
        cursor += count * 2
        current.append((pts, pcm))
    if current:
        runs.append(current)
    if not runs:
        raise ValueError("No decoded PCM observed")
    return runs


def analyze(path, reference=None, movie_start=None):
    runs = read_runs(path)
    run = max(runs, key=lambda values: sum(len(v) for _, v in values))
    gaps = [(b - a) / 1e6 - len(v) / 48000 for (a, v), (b, _) in zip(run, run[1:])]
    pcm = np.concatenate([v for _, v in run])
    rows = []
    for start in range(0, min(len(pcm) - 4800, 96000), 4800):
        values = pcm[start:start + 4800]
        crossings = np.flatnonzero((values[:-1] <= 0) & (values[1:] > 0))
        positions = crossings - values[crossings] / (values[crossings + 1] - values[crossings])
        hz = (len(positions) - 1) * 48000 / (positions[-1] - positions[0]) if len(positions) > 1 else 0
        fft = abs(np.fft.rfft(values * np.hanning(len(values)), n=65536))
        peak = int(np.argmax(fft))
        rows.append({"relativeSampleTime": start / 48000, "rms": float(np.sqrt(np.mean(values ** 2))),
                     "zeroCrossingHz": float(hz), "spectralPeakHz": peak * 48000 / 65536})
    result = {"file": path.name, "flushDelimitedRuns": len(runs), "selectedFrames": len(pcm),
            "minCallbackGapSeconds": min(gaps) if gaps else None,
            "maxCallbackGapSeconds": max(gaps) if gaps else None,
            "hardwareAudioOutputVerified": False, "measurements": rows}
    if reference is not None:
        # Correlation measures an offset; it never corrects samples or relaxes
        # the requested movie start. A shifted match must still fail.
        if movie_start is None or not np.isfinite(movie_start):
            raise ValueError("Reference comparison requires a finite movie start")
        expected = round(movie_start * 48000)
        prefix = min(8192, len(pcm))
        if prefix < 4800 or expected < 4800:
            raise ValueError("Reference comparison needs 100 ms and start >= 0.1 s")
        low, high = expected - 4800, expected + 4800
        if high + len(pcm) > len(reference):
            raise ValueError("Reference does not cover the complete comparison")
        scores = np.correlate(reference[low:high + prefix], pcm[:prefix], mode="valid")
        observed = low + int(np.argmax(scores))
        wanted = reference[expected:expected + len(pcm)]
        aligned = reference[observed:observed + len(pcm)]
        contiguous = bool(gaps) and max(abs(value) for value in gaps) <= 0.000001
        exact = bool(np.array_equal(pcm, wanted))
        result["referenceComparison"] = {
            "requestedMovieStartSeconds": movie_start,
            "observedMovieStartSeconds": observed / 48000,
            "observedOffsetSamples": observed - expected,
            "exactAtRequestedStart": exact,
            "rmsErrorAtRequestedStart": float(np.sqrt(np.mean((pcm - wanted) ** 2))),
            "rmsErrorAfterMeasuredAlignment": float(np.sqrt(np.mean((pcm - aligned) ** 2))),
            "callbackPTSContiguousWithinOneMicrosecond": contiguous,
            "selectedRunMatchesReference": exact and observed == expected and contiguous,
            "allFlushDelimitedRunsVerified": False,
            "physicalAudioOutputVerified": False,
        }
    return result


def continuity(run):
    """Independent offline evaluation of the existing native chirp predicate.

    Preserves crossing midpoint PTS and the native >10 steps / <0.1s limits.
    This does not execute the native UI or verify physical audio/video sync.
    """
    samples = np.concatenate([value for _, value in run])
    times = np.concatenate([pts + np.arange(len(value), dtype=np.int64) * 1_000_000 // 48000
                            for pts, value in run])
    blocks = []
    for start in range(0, len(samples) - 4799, 4800):
        indices = np.arange(max(1, start), start + 4800)
        positive = indices[(samples[indices - 1] <= 0) & (samples[indices] > 0)]
        if len(positive) < 2:
            continue
        positions = positive - start - samples[positive] / (samples[positive] - samples[positive - 1])
        frequency = float((len(positions) - 1) * 48000 / (positions[-1] - positions[0]))
        rms = float(np.sqrt(np.mean(samples[start:start + 4800] ** 2)))
        if rms <= 0.01 or frequency <= 100:
            continue
        blocks.append({"frequencyHz": frequency,
                       "midpointPTS": int(times[start]) + int((positions[0] + positions[-1]) * 0.5 * 1_000_000 / 48000)})
    steps = [(b["frequencyHz"] - a["frequencyHz"]) / 25 - (b["midpointPTS"] - a["midpointPTS"]) / 1e6
             for a, b in zip(blocks, blocks[1:])]
    return {"frames": len(samples), "blocks": len(blocks), "steps": len(steps),
            "firstFrequencyHz": blocks[0]["frequencyHz"] if blocks else None,
            "maximumStepErrorSeconds": max(map(abs, steps)) if steps else None,
            "nativeContinuityPredicateOffline": len(steps) > 10 and all(abs(step) < 0.1 for step in steps),
            "nativeUIExecuted": False, "physicalAudioOutputVerified": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", type=pathlib.Path, nargs="+")
    parser.add_argument("--reference", type=pathlib.Path)
    parser.add_argument("--start", type=float)
    parser.add_argument("--require-reference-match", action="store_true")
    args = parser.parse_args()
    if (args.reference is None) != (args.start is None) or (args.require_reference_match and args.reference is None):
        parser.error("--reference and --start are required together for reference checks")
    reference = None
    if args.reference:
        data = args.reference.read_bytes()
        if not data or len(data) > 10_000_000 or len(data) % 2:
            raise ValueError("Invalid or oversized owned 48 kHz mono S16 reference")
        reference = np.frombuffer(data, dtype="<i2").astype(float) / 32768
    results = [analyze(path, reference, args.start) for path in args.paths]
    for path, result in zip(args.paths, results):
        result["continuityByFlushDelimitedRun"] = [continuity(run) for run in read_runs(path)]
    print(json.dumps(results, indent=2, allow_nan=False))
    if args.require_reference_match and not all(result["referenceComparison"]["selectedRunMatchesReference"] for result in results):
        sys.exit(1)

# Standalone playback and workflow verification

Measured 25 October 2026 on an Apple M1 Max with 64 GB unified memory, macOS 26.5. Input: `LLM Resources/Benchmark/JallenClownWater/Input/HardestShotEver - 1sec.mov` (3840 × 2160, 24 fps, 24 frames).

## Playback

| Path | Frames | Elapsed | Throughput |
| --- | ---: | ---: | ---: |
| Previous decode pattern: new reader and seek for each frame | 72 | 3.784 s | 19.03 fps |
| Sequential reader, same RGBA16Float output | 72 | 0.227 s | 317.78 fps |
| Updated editor transport and preview submission, looping for 3 s | — | — | 23.64–24.04 fps across two runs (24 fps target) |

The decode comparison uses three traversals in an optimized Swift executable. It includes reader setup and full-resolution half-float decoding, without inference, rendering, or display. It does not prove which VideoToolbox decoder hardware was selected. The editor regression exercises the production playback loop and preview renderer; it does not measure physical display presentation or audio sync.

Playback now owns a sequential decoder on a worker actor, resetting only at seek/loop boundaries. Unanalysed and Original previews retain the source IOSurface directly, avoiding a destination allocation and GPU copy. Import no longer warms MLX. Cached-key playback uses the same sequential decode path; its total throughput still depends on analysis resolution and post-processing.

Reproduce the decode comparison from the repository root:

```sh
swiftc -O -swift-version 6 -parse-as-library \
  Source/CorridorKeyByLateNite/WrapperApp/Standalone/Engine/VideoSource.swift \
  Source/CorridorKeyByLateNite/WrapperApp/Standalone/Engine/MediaSource.swift \
  Source/CorridorKeyByLateNite/WrapperApp/Standalone/Engine/StillImageSource.swift \
  Source/CorridorKeyByLateNite/WrapperApp/Standalone/Engine/PixelBufferTextureBridge.swift \
  Tools/BenchmarkPlayback.swift -o /tmp/corridorkey-playback-benchmark
/tmp/corridorkey-playback-benchmark \
  'LLM Resources/Benchmark/JallenClownWater/Input/HardestShotEver - 1sec.mov'
```

## Analysis and defaults

Time Awareness Off previously prepared and spilled every frame's foundation features before refining any frames, despite using a one-frame model window. Both hosts now finish each frame as it arrives and release its features immediately. The two-frame real-model regression compares this streaming path with deferred inference: alpha differs by less than 0.00001 and foreground half-float bytes match exactly. Foundation feature extraction is still required to key each frame.

The [official v2 manual](https://help.corridorkey.com/docs/manual/) recommends Alpha Hint Strength 0.75 and starts Despill Amount at zero. Those values remain unchanged. New instances use no generated hint, with Light Wrap, Auto Despeckle and Reduce Edge Flicker off. Low GPU Memory is off, matching the supplied upstream `run_interactive.py` default. Time Awareness remains off and Quality remains source/device-aware. The Motion template and both hosts share these defaults; explicit saved values survive decoding.

Reduce Edge Flicker is an additional motion-gated alpha blend, separate from v2 Time Awareness. Blending prior alpha where the motion gate misses an edge can soften detail or leave trails, so it is now opt-in.

## Verification and limits

- Debug and optimized Release builds passed for the wrapper and embedded renderer with signing disabled. The checked-in decode benchmark also compiles independently with Swift 6.
- Shared logic, Metal stages, and the real-model streaming regression: 136 tests passed.
- Editor and transport regressions: 24 tests passed, covering playback, undo/redo with cached analysis, continuous slider edits, keyed batch export, failure continuation, cancellation, retry, duplicate names, and overwrite protection.
- The targeted coverage run measured BatchExportRunner at 99.0%, BatchExportModel at 93.6%, VideoSource at 82.6%, and AnalysisRunner at 84.2%. This is not whole-product coverage; the targeted report's overall coverage was 33.4%.
- Instruments Time Profiler successfully recorded the decode comparison. The Leaks recording failed to attach to its benchmark process, so leak freedom has not been established. Both task-created profiling processes exited.
- SwiftLint is not installed in this environment. Xcode compiles in Swift 6 with complete concurrency checking.
- Computer Use did not authorize interactive app inspection. SwiftUI ImageRenderer cannot render this sheet's native List/pickers, so its offscreen output was not accepted as visual verification. In-host Final Cut Pro, sandboxed TestFlight, and interactive UI validation remain release checks.

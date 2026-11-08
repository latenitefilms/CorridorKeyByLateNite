# Manual hint host regression

Run `bash Source/Tests/FxPlugHostTests/run.sh` on Apple Silicon with Xcode and the FxPlug SDK installed.

The harness compiles the production OSC, parameter storage and hint models. A local host supplies transactions to the installed FxPlug framework's real custom-parameter decoder and encoder. It does not launch Final Cut Pro, read libraries or draw GPU overlays.

The first two “Unable to unarchive” messages are intentional: the negative control recreates a session without `classesForCustomParameterID:`. The same archive must then decode through the production OSC. Subsequent checks exercise click routing, every explicit tool, frame boundaries, external-mask gating, failed-read preservation and a new OSC session.

Private framework declarations appear only in this test harness. Production code continues to use public FxPlug APIs. GPU rendering, host coordinate transforms and live Final Cut Pro event delivery require a separate integration check.

## Idle model loading regression

Build an unsigned Debug renderer (`xcodebuild … CODE_SIGNING_ALLOWED=NO`), then run:

```sh
bash Source/Tests/FxPlugHostTests/run-model-loading.sh "/path/to/Build/Products/Debug/CorridorKey by LateNite Renderer.pluginkit"
```

This launches the real renderer with a test-only replacement for the blocking
FxPlug service handoff. Production `main.swift`, ten plug-in initializers, and
their property callbacks execute unchanged. It samples physical footprint for
20 seconds and fails above 256 MiB, catching eager model imports at either
startup boundary. The probe connects to no host and opens no Final Cut Pro
library; it does not change the renderer bundle. Hardened, signed distribution
builds deliberately disallow this injection, so use the unsigned Debug product.

The SwiftPM `ModelLoadingLifecycleTests` separately exercise cold inspector
reads, pass-through/hint rendering, persisted-cache playback, first-frame model
loading, and engine reuse. Run them with:

```sh
swift test --package-path Source -c release --filter ModelLoadingLifecycleTests
```

Validation on Apple M1 Max, 8 November 2026: with ten instances over 20 seconds,
the previous Debug renderer reached **4,248.18 MiB** of physical footprint; the
rebuilt renderer reached **3.64 MiB**. The previous build failed the idle budget
as expected. Both probes used a separate process with no Final Cut Pro connection;
these figures do not measure a live inspector, playback, or active analysis.

Both Xcode targets built with Swift 6 complete concurrency checking and signing
disabled. The 14 focused Swift tests passed with:

```sh
swift test --package-path Source -c release --filter 'ModelLoadingLifecycleTests|SharedMLXBridgeRegistryWaitTests|AnalysisSnapshotTests'
```

The first real analysis frame loaded the requested 512px blue-screen model and
produced finite output; a second coordinator reused that engine. Cached playback
and hint diagnostics kept an independent registry cold. SwiftLint is unavailable
on this machine; live Final Cut Pro and Instruments leak checks were not run.

## Anamorphic media regression

`LLM Resources/Test Clips/car_green_Screen.mp4` stores 720×480 pixels with a
109:90 pixel aspect ratio, giving a square-pixel display size of 872×480.
Previously, standalone analysis used the display size while decoded frames
retained the storage size. A valid 512×282 prediction was subsequently rejected
as a damaged cache. The failing regression reproduced both the dimension
mismatch and `AnalysisDiskCacheError.invalidFrame` before the fix.

The shared video reader now corrects pixel aspect before track orientation and
removes obsolete raster geometry attachments. Square-pixel, unrotated videos
retain their original buffer without an extra render. FxPlug uses
`inversePixelTransform` to compare analysis and playback in square-pixel image
space, including the 872×480 analysis and 706×480 playback rasters seen in the
reported log. Output bounds are mapped through both image transforms. The effect
advertises scale support, matching its axis-aligned inference pipeline.

Run the SDK geometry regression without launching Final Cut Pro:

```sh
bash Source/Tests/FxPlugHostTests/run-image-geometry.sh
```

This uses Apple's real `FxMatrix44` with controlled full-size, anamorphic,
proxy and portrait tiles. It exercises production dimension and output-rectangle
calculations, including translated coordinate origins.

The real-clip test runs all frames through `AnalysisRunner` and cached playback
with default settings. It verifies transparent window pixels, opaque subject
pixels and finite output on every frame. The optional PNG contains the source,
matte and a composite over white:

```sh
CORRIDORKEY_CAR_PREVIEW=/tmp/corridorkey-car-fixed.png \
  swift test --package-path Source --filter \
  'anamorphic|recommendedCacheDuringPlayback|diskBackedRendering|hostImageOrigins'
```

`WrapperAppTests/VideoSourceTests` also covers synthetic non-square pixels with
and without rotation, both BGRA8 and RGBA16F, scrub/sequential agreement, geometry
attachments and timestamps. These checks require no neural model. Live Final
Cut Pro playback remains a separate host integration check.

Validation on Apple M1 Max, 8 November 2026: all **202 frames** of the supplied
clip analysed and rendered at **872×480** with the default settings. The full-clip
regression, six focused cache/render tests, 12 Xcode import/texture tests and the
SDK geometry harness passed. Both app and renderer targets built with Swift 6
complete concurrency checking and signing disabled. Source, matte and composite
previews were inspected at the beginning, middle and end of the clip.

SwiftLint is unavailable on this machine. A 20-second Instruments Leaks capture
during the full-clip test reported one 16-byte `NSArray` leak with a truncated
allocation stack; its origin could not be attributed. This is not a clean leak
audit or a measurement of live Final Cut Pro performance.

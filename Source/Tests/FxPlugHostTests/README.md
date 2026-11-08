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

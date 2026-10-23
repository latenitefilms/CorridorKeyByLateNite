# CorridorKey v2 migration validation

Measured on 23 October 2026: Apple M1 Max, 64 GB unified memory, macOS 26.5,
Xcode 26.6 / Swift 6.3.3, MLX Swift 0.31.3, conversion MLX Python 0.31.0.

## Model and parity

The unified artifact is 2,440,281,517 bytes. It includes both trained keying stages
and all three foundation models, with float16 parameter storage and float32
computation. All five quality graphs share weights. SHA-256:

`6ba243c9ba30e99b0886d6e04130ddf9acd03483f8fda8ecafa0f653fe8271be`

The first frames of the supplied NikoDruid and Blue Screen four-frame ProRes clips
were compared with the float32 official PyTorch reference at every quality.
The largest mean alpha error across the ten cases was 0.000140; the largest mean
foreground error was 0.000410. Maximum per-pixel errors were 0.016342 alpha and
0.011571 foreground. Every graph passed a separate serialized reload check.
The complete measurements are in `Tools/CorridorKeyV2/validation.json`.

Diagnostic model-only source/matte/composite previews were inspected at 1024.
Both were upright and separated the subjects from their screens. These previews
exclude the app's refinement pipeline; numerical parity is not proof that every
shot improves over v1. Existing square resizing and independent-frame processing
remain in use. Native temporal-window accumulation and a new HDR workflow are
outside this migration.

## Inference timing and memory

Median of three measured calls after warm-up, seconds/frame. Includes contiguous
output materialization, excludes video decoding, hint generation, refinement,
composition and export. Small sample sizes and system load limit precision.

| Quality | Default allocator green / blue | 1 GiB cache green / blue |
|---|---:|---:|
| 512 | 0.295 / 0.305 | 0.321 / 0.333 |
| 768 | 0.559 / 0.593 | Not measured |
| 1024 | 1.121 / 1.124 | 1.039 / 1.113 |
| 1536 | 2.544 / 2.525 | Not measured |
| 2048 | 4.377 / 4.573 | 4.906 / 4.848 |

The 1 GiB cache target is the shipping policy. At 2048 it reduced retained cached
buffers from 13.21 GiB to 1.19 GiB with a roughly 6–12% timing cost in this sample.
MLX can overshoot the cache target by an allocation. Peak active MLX allocation
was approximately 4.77 GiB at 2048; this is not total process RSS, and does not
include every host/Metal allocation. No smaller-memory Mac was measured.
Raw samples: `Tools/CorridorKeyV2/benchmark-baseline.json` and
`Tools/CorridorKeyV2/benchmark-bounded.json`.

Repeated Swift inference at 512 retained about 2,320 MiB active MLX allocation,
with zero growth over 30 frames. Cache stayed near 1,024–1,028 MiB and dropped to
zero after clearing. Green and blue screens and every quality share one loaded
engine per device. Both v1 analysis mattes and v1 timing recommendations are
invalidated separately.

## Verification

- Conversion: 11 numerical tests passed, covering convolution, attention,
  interpolation, functional mutations, colour transfer and trace-local constants.
- Swift: all 135 tests in 27 suites passed with code coverage enabled, covering
  logic, Metal/refinement, the benchmark runner and real model inference.
  Inference covers all quality/screen dispatches, output orientation, repeatability,
  zero-copy/staging parity, shared ownership, cache reclamation and migration.
- The new zero-copy lifetime regression proves that MLX retains the input Metal
  buffer until array release, then releases it. Instruments initially found leaked
  `FinalizerCaptureState` objects in MLX Swift's raw-pointer initializer. The local
  managed C API bridge eliminated those findings in the follow-up 30-second trace.
  One unattributed 16-byte `NSArray` finding remains in the test process; this is
  not a claim of a completely leak-free application.
- Xcode built the app, FxPlug and integration-test bundle with development signing.
  Model and license resources were verified in the built bundles.

Measured line coverage of the application sources compiled into the headless
package is 69.47% (3,092 / 4,451 lines). Selected files: analysis persistence 87.04%,
device capability cache 94.29%, MLX engine 78.40%, shared registry 77.78%.
This is below the requested 80% target and excludes the Xcode-only app/FxPlug
sources; no full-application coverage claim is made.

The Xcode-hosted integration run could not start: the test host stalled during
macOS sandbox initialization before connecting to the test runner, including with
the project's Apple Development certificate. The four-frame ProRes round trip and
strengthened green/blue standalone-versus-shared-renderer tests compile but are
not reported as passing. Live Final Cut Pro, TestFlight, accessibility, full-app
coverage and sustained Instruments Metal profiling remain release checks.
SwiftLint is not installed in this environment.

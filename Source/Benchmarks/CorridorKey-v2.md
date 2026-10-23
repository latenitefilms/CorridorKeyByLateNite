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

## Host integration follow-up — 24 October 2026

The standalone analysis adapter reversed the rows a second time, after the
exported graph and Metal writeback had already restored source orientation.
Removing that reversal fixes both the stored matte and its alignment with the
source pixels used for temporal motion detection. Standalone caches are in memory
and are rebuilt on reopening a clip; FxPlug's version-4 caches already have the
correct row order, so this fix does not require another schema change.

New headless integration tests compile the actual `RenderPipeline`, standalone
adapter, pixel-buffer bridge, video reader and analysis runner. They cover both
screen colours with the subject at the top and bottom, analysis-to-cache-to-render
orientation, native RGB detail, effective interior controls, input changes at the
same timestamp, concurrent sessions and four-frame temporal parity. The existing
Xcode orientation test incorrectly required the second flip; it now compares the
same source-order rows. HardestShotEver at Maximum (2048), Apple Vision and the
default postprocessing was rendered through the actual standalone path. Its
source/matte/white-background composite preview is upright and aligned.

Two other analysis corrections accompany this fix. Standalone now applies the
same motion-gated EMA as FxPlug, and releases MLX's reusable allocation cache on
completion, cancellation or failure. The timestamp-only inference cache was
removed: it could return a prior clip/hint's prediction during reanalysis.
Playback continues to use the persisted matte cache. Per-device analysis scratch
buffers are now held exclusively through preprocessing, inference and readback;
the engine's own inference lock alone did not protect preprocessing writes.

### Control audit

Numeric defaults, popup raw values and parameter IDs are unchanged. Motion's
published group titles now match both Swift inspectors: Interior Detail,
Edge & Spill, and Edge Refinement.

| Control | Meaning with v2 / disposition |
|---|---|
| Quality | Retained: chooses the exported square graph. Recommended still uses the conservative RAM ceiling; old Hiera memory claims were removed. Smaller-memory Macs need measurements before raising it. |
| Hint | Retained: Automatic uses chroma; Apple Vision unions a subject mask with chroma; Manual requires points over chroma. All are automated hints at quality 0.75, not authoritative roto or v2's no-hint mode. |
| Screen Colour | Retained for chroma hints and spill processing. Both colours use the same v2 weights. |
| Upscale Method | Retained for matte resampling. Cached source RGB now stays at native resolution. |
| Output | Retained, including diagnostic Hint. Foreground outputs currently use source-derived RGB, not the model's foreground prediction (see below). |
| Source Passthrough, Edge Erode, Edge Blur | Retained. The previously disconnected radii now build a separate eroded/blurred interior mixing mask. They do not erode/blur the output alpha. No extra mask is allocated with passthrough off. |
| Black/White Point, Matte Erode, Softness, Gamma | Retained as post-model artistic controls. |
| Auto Despeckle / Size | Retained: connected-component cleanup after inference; can remove intentional small details. |
| Refiner Strength | Retained as a postprocess detail blend against a blurred matte. It does **not** control v2's trained refinement stage; 1 preserves model detail. |
| Despill Strength / Spill Method | Retained. Existing implementation also attenuates screen-coloured alpha; this is additional processing beyond v2's alpha prediction. |
| Light Wrap / Wrap Strength / Wrap Radius | Retained as an artistic source-plate edge effect. It does not sample a replacement background. |
| Edge Decontaminate / Strength | Retained as post-model screen-colour suppression. |
| Reduce Edge Flicker / Stability Strength | Retained; now functional in both analysis paths using shared history. Requires reanalysis. This is an EMA, not v2 Hann-window inference or persistent RVM state. |

### Playback performance and remaining architecture work

Cached playback used to shrink source RGB to the inference square then upscale
it to the clip dimensions. The path now uses native source RGB, removing both
resampling passes and the identity screen-transform submission/wait. A 1080p
alternating-column regression failed before the change and now preserves both
columns. Seven warmed Debug renders with optional postprocessing disabled had a
median of 2.97 ms before and 2.73 ms after on this M1 Max. Other follow-up runs
ranged around 2.39–2.74 ms. These short samples indicate modest savings, not a
general FPS or model-inference speedup claim. No learned model/precision changes
were made.

A separate five-sample follow-up using the unchanged model and the 1 GiB cache
recorded these median inference-only times (green / blue): 512: **0.339 / 0.480 s**;
1024: **1.567 / 1.486 s**; 2048: **6.421 / 6.592 s**. Peak active MLX allocation
at 2048 was **4.77 GiB**, with **1.19 GiB** cached. Raw samples and device data are
in `Tools/CorridorKeyV2/benchmark-followup.json`. These are slower than the earlier
measurement despite identical model computation, demonstrating system/load
variability. They must not be presented as a before/after inference comparison.

The main remaining quality limitation is the **alpha-only persisted cache**.
V2 computes foreground RGB, but analysis discards it and cached playback derives
foreground from the source plus despill. Full v2 foreground reconstruction needs
a versioned foreground cache, a storage budget (preferably sequential disk-backed
video rather than huge FxPlug custom-parameter blobs), colour-space validation
and matching preview/export behaviour. This deserves a dedicated cache change;
the current Foreground output must not be described as v2's predicted RGB.

The current hardware allocation is intentional but not proof of optimality:

- MLX runs the model on the Metal GPU with shared weights, zero-copy input,
  GPU-contiguous output and a bounded allocator cache. [MLX supports CPU/GPU
  execution](https://developer.apple.com/videos/play/wwdc2025/315/); it does not
  expose a switch that moves this imported graph to the Neural Engine.
- Vision selects its compute devices for subject hints. Benchmark explicit
  device assignments only against supported devices; [the framework chooses
  automatically when no override is supplied](https://developer.apple.com/documentation/vision/visionrequest/setcomputedevice%28_%3Afor%3A%29).
- Core ML is the relevant experiment for Neural Engine model execution.
  Compare `.all`, `.cpuAndGPU` and `.cpuAndNeuralEngine` on converted foundation
  submodels, including partition/copy overhead and image parity. [Core ML's
  compute-unit policy](https://developer.apple.com/documentation/coreml/mlcomputeunits)
  permits those devices; it does not guarantee every operator runs on the ANE.
- Metal/MPS handle resampling and compositing, Accelerate handles matte
  conversion, and CPU code handles cache compression and temporal motion gates.
  AVFoundation handles decode/encode through Apple media services. [VideoToolbox
  provides hardware codec acceleration](https://developer.apple.com/documentation/videotoolbox),
  not neural inference; verify actual codec/hardware routing in a release trace.

Next experiments should preserve the numerical parity gates: mixed-precision
compute (rather than only float16 weight storage), aspect-preserving graphs,
foundation-model Core ML partitions, and native temporal analysis windows. Do not
raise quality ceilings or promise real-time 2048 inference from a single M1 Max
measurement. No new third-party framework was introduced.

### Follow-up Instruments findings

A 30-second Leaks capture of the expanded suite exposed a real ownership cycle:
`MetalDeviceCacheEntry` cached a `VisionHintEngine` which strongly retained the
entry. Instruments reported 116 allocations / 29,072 bytes in that leaked object
graph, including the Vision engine, texture cache and 28 compute pipeline
objects (this does not quantify every retained GPU allocation). The engine now
holds a weak owner reference, retaining it locally while uploading a mask. Its
request lock also covers the entire Vision execution/result extraction interval,
rather than just retrieval of the reusable request.

The new ownership test verifies both objects deallocate after scope exit. A
second 30-second trace after the fix reports only the pre-existing, unattributed
16-byte `NSArray` finding; the Vision/Metal cycle is absent. This is not a claim
of zero leaks throughout the app. Traces are `/tmp/ckv2-followup-leaks.trace` and
`/tmp/ckv2-vision-fixed-leaks.trace` on the validation machine.

A separate 30-second Metal System Trace recorded 12,849 GPU intervals for the
test process: 12,835 compute, 13 fragment and 1 vertex, with no command-buffer
errors. This confirms GPU execution under the sampled workload, not optimal
utilization or a sustained Final Cut Pro throughput result. Capture:
`/tmp/ckv2-followup-metal.trace`.

### Final verification

- Full headless suite: **145 tests passed** in 29 suites. After the Instruments
  ownership fix, **21 targeted Vision, memory and standalone integration tests
  passed**, including the new deallocation test (146 distinct tests overall).
- Xcode `build-for-testing` passed for the sandboxed app, FxPlug renderer and
  integration-test bundle with Apple Development signing and Swift 6 checks.
- Combined production-source line coverage in the expanded headless package:
  **73.75% (4,703 / 6,377 lines)**. AnalysisRunner: 85%; TemporalBlender: 97.84%.
  This remains below the requested 80% and does not include every app/FxPlug
  source. Its denominator differs from the original migration's smaller package.
- Motion XML parses successfully; published group names match the inspectors.
- SwiftLint is still unavailable. Live Final Cut Pro playback, complete
  application coverage, accessibility and validation on smaller-memory or newer
  Apple Silicon Macs remain release checks. Headless render parity is not a live
  Final Cut Pro host test.

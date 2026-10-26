# CorridorKey v2 migration validation

## Staged video implementation — 25 October 2026

The current backend now implements temporal windows, continuous RVM state,
overlapping batons, bidirectional external hints, signed linear-color controls,
aspect-preserving inference and bounded intermediate storage in both hosts.
See `Tools/CorridorKeyV2/README.md` for reproduction and the runtime contract.

Current staged artifact: 2,534,056,943 bytes; SHA-256:
`ea19b82bd259ac91a751c2976368c0931cfa1f7b853d4ee5e17a437ae0872574`.

The final-image oracle passed 11 synthetic frames across 512/T2, 512/T4,
1024/T2, 1536/T1 and 2048/T1. Maximum alpha error was below 0.001 and
linear foreground error below 0.0036. This includes continuous recurrence,
overlap carry, cosine accumulation and FP16 baton rounding. Stage-level
validation alone initially missed an RVM sequence-axis assembly error; the
end-to-end check found it and both Swift call paths were corrected.

The two supplied four-frame benchmark clips also passed at 512/T4: maximum
alpha error 0.006544 and maximum linear foreground error 0.011920; worst mean
errors 0.00008881 and 0.00009851 respectively. The independent final-image gates
remain max <=0.05 and mean <=0.002. These 19 checked frames are numerical
agreement evidence, not a ground-truth perceptual-quality benchmark.

Long-profile smoke checks executed T=8/24/48/80 at 512, with finite batons,
auxiliary hints and first/last refined outputs. Peak MLX allocations were
3.78/4.58/5.38/7.40 GiB respectively. The check repeats a synthetic plate and
does not measure full clip analysis, total process memory or higher-resolution
long-window quality. Memory preflight now reserves more working memory than
the measured 512/T80 peak. Reports: `video-clip-validation.json` and
`video-profile-validation.json` in `Tools/CorridorKeyV2`.

### Current implementation verification

- The final headless regression passed **187 tests in 32 suites** (two
  Release-only checks were skipped here and passed separately in Release). The separate
  all-quality/all-screen model dispatch sweep also passed. The shared Swift
  session matches the independent reference, preserves frame order and cropped
  geometry, produces identical low-memory/full-memory results and propagates a
  single reference both forwards and backwards.
- Current headless application line coverage is **77.65% (6,673 / 8,594)**.
  Temporal session: **93.55%**; video settings: **87.59%**; disk cache: **84.55%**.
  This remains below the requested 80% target and excludes Xcode-only sources.
- Signed Debug and Release app/FxPlug builds and the Debug test-bundle build
  succeed. The Release app passes deep, strict code-signature verification using
  the Mac's trust services. This is development signing, not App Store approval. The embedded
  model's SHA-256 matches the staged artifact above. Motion XML and both sandbox
  entitlements validate.
- Signed host tests cover portrait decoding, editor transport, the four-frame
  real-clip workflow and movie-hint timing/preview. All four analysis/export
  tests passed after correcting ImageIO's zero-image movie classification. The
  six-frame temporal movie-hint export checks complete analysis and linear
  ProRes transfer metadata. Keyed exports now reject missing analysis before
  touching the destination; Original and Hint remain available without a cache.
- **12 optimized tests passed**, including the independent temporal-reference
  comparison and still-image/export regressions. A separate optimized Swift
  test passed T=8/24/48/80 dispatch and finite-output checks at 512, exercising
  compiled graph ownership as well as the Python smoke test.
- All **12 Python lowering tests** passed. The 30-call memory regression kept
  active MLX allocation at 4,642 MiB (the test process retains two engines), and
  clearing the cache reclaimed all 1,024 MiB of reusable buffers. These values
  are not total application RSS or a one-engine minimum memory requirement.
- A fresh 30-second Instruments Leaks attachment reported one unattributed
  16-byte `NSArray` allocation (`<Call stack limit reached>`). This is not a
  clean-leaks claim. The bounded capture did not cover the full application or
  a complete temporal sequence; it is saved at
  `/private/tmp/ckv2-video-session-leaks.trace` on the validation Mac.

SwiftLint is unavailable on this Mac. Live Final Cut Pro interaction, complete
application coverage, accessibility, TestFlight/App Store distribution and testing
on smaller-memory Macs remain release checks. The memory budget shown in the
inspectors is Metal's recommended device working set, not a free-VRAM reading.

The new cache schema is **9**: existing clips need **Analyse Clip** again.
The 2.53 GB model is installed locally and intentionally Git-ignored; fresh
checkouts must reproduce or obtain this matching artifact before building.

### Current optimized single-frame measurements

M1 Max / 64 GB, SwiftPM Release, five warmed samples per cell, alternating
compiled/uncompiled order. The staged artifact's independent T=1 adapter includes
Metal output writeback, excluding decoding, hint generation, postprocessing and
export. It is not a temporal-sequence or Final Cut Pro playback benchmark.

| Resolution | Uncompiled green / blue | Compiled green / blue |
|---|---:|---:|
| 512 | 359.1 / 351.3 ms | 341.7 / 330.8 ms |
| 768 | 633.5 / 646.5 ms | 605.2 / 619.4 ms |
| 1024 | 1,112.5 / 1,092.0 ms | 1,022.0 / 1,017.9 ms |
| 1536 | 2,632.3 / 2,766.2 ms | 2,550.8 / 2,653.8 ms |
| 2048 | 5,385.9 / 5,368.7 ms | 5,222.7 / 5,266.4 ms |

Compilation reduced latency by **1.9–8.1%**, median **4.3%**, in this short sample.
Alpha matched exactly; maximum foreground difference was 0.0000002385.
Raw results are in `Tools/CorridorKeyV2/video-compiled-runtime.json`. These are
measured local gains, not the v1 implementation's published 1.5–2x claim.

All measurements below are historical baselines and do not measure the new
temporal execution path. In particular, earlier statements excluding temporal
inference and linear controls describe the previous migration, not current scope.
Do not apply the v1 community implementation's 1.5–2x compilation claim to v2.
Mixed FP16 activations remain rejected for shipping because compiled 2048 RGB
exceeded the unchanged quality gate.


The 24 October performance/storage follow-up is recorded at the end of this
document. Earlier measurements below describe the original migration and cache.

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

At the time of this follow-up, the main quality limitation was the **alpha-only
persisted cache** (addressed by the complete-frame update below).
V2 computed foreground RGB, but analysis discarded it and cached playback derived
foreground from source plus despill. The complete-frame update below addresses
RGB persistence, color-space restoration and matching preview/export behavior.
The storage budget and disk-backed persistence architecture remain open.

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

## Complete-frame cache — 24 October 2026

Both hosts now persist model alpha **and reconstructed foreground**, then run
the same refinement and composition pipeline during preview/export. Analysis
schema 5 rejects the earlier alpha-only caches: **run Analyse Clip again**.
`CKF1` stores an R16F alpha plane and straight RGBA16F foreground in source row
order. Only alpha clamps to [0, 1]; negative/above-white RGB remains representable.
Temporal Stability blends alpha while retaining the current frame's predicted
RGB. Interior continues to use the native source as its optional detail input.
The cache keeps canonical Rec.709 RGB; Rec.2020 renders reverse the existing
input gamut matrix before mixing it with working-space source RGB. A synthetic
color regression covers both gamuts. This restores the existing transform
contract; it does not establish a new end-to-end HDR transfer-function workflow.
All inspector names and defaults, including the Motion template, remain unchanged.

Metal now writes the foreground directly to a shared RGBA16F texture for analysis,
eliminating a 64 MiB CPU float array and float-to-half conversion at 2048. The
model reference tests can still request RGBA32F. Playback decompresses directly
into one reusable shared Metal buffer and uploads half textures without float
expansion. A lease covers decode **and** upload so simultaneous FxPlug renders
cannot overwrite each other's pixels. Malformed and legacy payloads behave as
missing analysis rather than failing the render or substituting source RGB for
a supposedly complete model result.

### Optimized-build cache measurements

Apple M1 Max, 64 GB; first NikoDruid benchmark frame; native 1920×1080 output.
SwiftPM **Release**, one warm render then seven measured renders per quality.
Automatic chroma hint; bilinear resampling; optional despill/despeckle/light-wrap,
edge decontamination and temporal stability disabled. Times exclude inference,
video decoding and export encoding. These measure cached renderer cost, not
Final Cut Pro playback throughput, sustained thermals, or all hardware.

| Inference side | Complete payload/frame | Decode median | Cached render median |
|---|---:|---:|---:|
| 512 | 2,333,895 bytes | 0.81 ms | 6.14 ms |
| 1024 | 9,412,807 bytes | 2.89 ms | 9.24 ms |
| 1536 | 21,166,752 bytes | 6.08 ms | 14.67 ms |
| 2048 | 37,588,369 bytes | 11.13 ms | 23.35 ms |

The four explicit UI quality settings are measured here; 768 remains supported
by the model and its contract tests but is not an explicit Quality menu choice.
The follow-up after the gamut correction measured 6.23/9.59/19.55/22.82 ms;
this variability is why these samples are not a fixed playback guarantee.
The synthetic flat-color cache test is substantially faster and must not be
used as a proxy for realistic image payloads.

LZ4 was chosen after measuring the same 40 MiB decoded frame with Apple's
Compression framework. In an optimized standalone codec probe, native-layout
LZ4 produced 37.59 MB and decoded in 9.25 ms; LZFSE produced 28.84 MB but took
55.13 ms; zlib produced 29.31 MB and took 143.79 ms. LZFSE encoding was also
about 500 ms versus 53 ms for LZ4. Byte-plane shuffling reduced size further
but added 18.43 ms encoding preparation and 13.83 ms decode restoration in
the tested implementation. These are small, local samples, not general codec
benchmarks. Incompressible frames fall back to raw storage with a bounded size.

**Storage remains a material limitation:** complete RGB caches are much larger
than alpha-only mattes. This sample at 2048 extrapolates to about 50 GiB per
minute at 24 fps; content-dependent compression varies. The existing in-memory
standalone cache and FxPlug Library custom-parameter persistence remain in use.
The shared decode scratch buffer is bounded by the largest requested frame,
but the whole clip cache is not bounded. A disk-backed cache with eviction and
an explicit project portability policy is still needed before claiming scalable
long-clip analysis on low-memory Macs. This change does not solve that storage
architecture or change the model's inference speed.

### Verification and reproduction

The full headless suite passed **151 tests** again after the Metal half-writeback
and test-harness changes. The final optimized codec/analysis/playback/temporal/
benchmark-logic run passed **28 tests**, including the subsequent Rec.2020 fix,
simultaneous cached renders with different foregrounds, legacy/corrupt cache
fallback, signed RGB persistence, green/blue orientation and HardestShotEver.
The new codec measured **97.85% line coverage** in the initial full coverage run;
the latest full headless package run was **72.75%**, below the requested 80% and excluding
Xcode-only app/FxPlug sources. No full-app coverage claim is made.
The signed sandboxed standalone app, FxPlug service and integration-test bundle
build successfully. Live Final Cut Pro, smaller-memory Macs and full-application
coverage remain unverified. SwiftLint is not installed on this validation Mac.

A 30-second Instruments Leaks capture listed no leak findings, but reached its
time limit before the complete test sequence ended. The attached Metal System
Trace recorded **16,225 compute and 7 fragment intervals** for the test worker,
with **zero command-buffer error rows**. These are bounded headless samples,
not proof of optimal utilization, sustained throughput or zero leaks in the
complete app. The initial launch-mode Metal recording exported no GPU tables;
only the subsequent attached recording supplies those counts. Raw summaries:
`Tools/CorridorKeyV2/cache-playback.json` and `cache-profiling.json`. Captures:
`/tmp/ckv2-complete-cache-leaks.trace` and
`/tmp/ckv2-complete-cache-metal-attached.trace` on the validation Mac.

Release testing exposed an existing executable-entry collision: importing
`BenchmarkRunner` into the test bundle started the CLI instead of Swift Testing.
The command now calls a separate `BenchmarkRunnerSupport` module, and tests link
that module. The CLI help and its existing report/temporal tests pass.

```sh
swift test --package-path Source --enable-code-coverage
swift test --package-path Source -c release --filter StandalonePipelineTests
```

The model remains unchanged and available locally, but is Git-ignored. Its LFS
pointer was removed from both unpublished commits, with authors/messages/dates
preserved and an original-branch recovery bundle saved locally. Fresh checkouts
must follow `Tools/CorridorKeyV2/README.md` to recreate the model before building.

See [the community MLX assessment](CorridorKey-v2-community-MLX.md) for mixed-FP16,
Q8, temporal/native-resolution differences and the reason to retain Screen Color.

## 24 October: bounded storage and runtime compilation

Both hosts now retain frame references and write complete CKF1 predictions to
their own sandbox cache directories. Compressed RAM storage is capped at 128 MiB
per process and frame payloads at 64 GiB per host. Whole inactive passes are
evicted in access order. Analysis and standalone exports pin their passes with
cross-process file locks; interrupted manifest writes are reconciled at the
start of the next pass. A frame that cannot fit fails explicitly. The quota
still limits long high-quality clips; it does not make their RGB payloads smaller.

Schema 8 invalidates previous caches. **Choose Analyse Clip again after this
update.** Libraries now contain compact references, so moving them to another
Mac or clearing the cache also requires analysis again. Both inspectors show
the same explanation. Missing or damaged referenced frames fail instead of
silently producing unkeyed output. Standalone recovery keeps Analyse Clip enabled.
The secure archive regression stores 1,000 references in under 200 KB rather
than embedding the represented 37 GB of image data.

Standalone analysis compresses once, after temporal processing. Preview renders
run on a serial actor away from the main actor, with cancellation checks before
queued work starts. A coalescing worker prefetches requested/next frames without
retaining a whole clip. Numeric inspector fields now accept the same full ranges
as FxPlug while the sliders retain their existing fine-adjustment ranges. Names,
defaults and the Motion template have not changed.

Release builds compile fixed-shape MLX graphs, including contiguous output
materialization. Debug builds use the imported graph because MLX Swift 0.31.3's
unoptimized compiler-cache destruction overflowed the worker stack. Optimized
inference and engine destruction passed on every supported quality and both
screen patterns. The synthetic regression's alpha/RGB texture outputs matched.

On this M1 Max, five alternating warm samples per case measured improvements of
2.7–10.6% in nine of ten cases; the 1024 green case was 0.5% slower. The median
relative improvement across cases was 5.4%. These include Swift inference and
Metal writeback, and exclude decoding, disk-cache reads, refinements and encoding.
They are not Final Cut Pro throughput or sustained thermal measurements.
Measurements: `Tools/CorridorKeyV2/compiled-runtime.json`.

The complete headless run passed 177 tests, with the optimized-only regression
skipped in Debug and separately passed in Release. The signed sandboxed Xcode
view-model suite passed all 10 tests, including missing-cache recovery. The later
disk-render regression and five cache tests passed together; disk and inline
rendering match, and missing, wrong-size and truncated compressed frames fail.
Both Xcode products and the integration-test bundle build with Swift 6.

The full headless run measured 79.81% line coverage for the mirrored app source
files and 81.30% for the new disk cache. This is not full-app/FxPlug coverage and
does not meet the requested overall 80% target. SwiftLint remains unavailable on
this Mac; the existing headless test warnings are not a clean lint result.

A 35-second attached Instruments Leaks capture reported one 16-byte NSArray
finding with an unresolved allocation stack. It cannot be attributed from this
capture, and **leak-free status is not established**. The separate Metal capture
contains no command-buffer error rows. These bounded headless captures do not
validate live Final Cut Pro, the full UI, sustained GPU utilization or smaller-
memory Macs. Captures are `/tmp/ckv2-bounded-cache-leaks.trace` and
`/tmp/ckv2-bounded-cache-metal.trace` on the validation Mac.

## FxPlug inspector and analysed playback

The supplied Build 10 renderer log contains 774 custom-parameter unarchiving
warnings for parameter 50. Its most recent entries are from 24 October; it does
not contain per-render timings or a trace of the supplied screenshot's four-frame
analysis. It also records completed analysis passes, so those warnings alone do
not establish a failure to produce cached predictions.

A headless regression reproduced a separate rendering defect: Recommended quality
was recalculated from each render surface. A 1536px analysis was rejected when the
host supplied an HD or smaller playback surface, and the pipeline returned the
original image. Playback now retains the analysed resolution, scales the complete
prediction to the destination, and tolerates source-size rounding. Explicit
quality changes, changed hints and different aspect ratios remain invalidating.
No model settings, persisted parameter IDs or analysis schema were changed.

State capture now retrieves header storage once for the alpha asset, subject
points and analysis index. A per-instance locked store reuses decoded frame
metadata while respecting changed host values and undo/reset. Render callbacks
use their immutable state, including the captured colour gamut, without querying
parameter APIs. This follows Apple's [plug-in state contract](https://developer.apple.com/documentation/professional-video-applications/communicating-with-the-plug-in-state).
Backend transitions are logged with output dimensions, quality and render time;
there is no per-frame log write. Elimination of the host unarchiving warnings
still requires a fresh in-host run.

The header keeps analysis actions and status visible, with wrapping diagnostics
in Analysis Details. Alpha Hint file selection and Set Current Frame as Reference
now occupy a custom row inside Alpha Hint (new ID 9012); the published Motion
group includes it. The shared picker provides About Alpha Hint in both hosts.
Explicit custom-row bounds and scrollable overflow avoid clipping long filenames,
errors and larger accessibility text.

Validation: 150 selected Release logic, Metal and cached-render tests passed,
including a regression that failed on the original reduced-surface path. The
synthetic 1080p cached-foreground benchmark measured a 1.98 ms median across seven
warmed frames on this Apple M1 Max. It uses a constant 512px prediction and excludes
decoding, host IPC and display; it is not a sustained Final Cut Pro frame-rate
measurement. Both Xcode products build with Swift 6 complete concurrency checking
and signing disabled. The Motion XML parses successfully.

Instruments Time Profiler captured the three cached-render regressions in
`/tmp/CorridorKeyCachedRenderTests.trace`; all three passed under instrumentation.
This is a short synthetic workload, not a sustained playback or Leaks capture.

Reproduce the headless checks:

```sh
swift test --package-path Source -c release --filter 'CorridorKeyByLateNiteLogicTests|CorridorKeyByLateNiteMetalStagesTests|recommendedCacheDuringPlayback|diskBackedRendering|cachedPlayback|concurrentCachedFrames|invalidCachedFrame|cachedForegroundWorkingGamut'
```

Computer Use access to Final Cut Pro was not granted, so the live inspector,
template refresh, save/reopen behaviour and actual timeline playback remain
in-host checks. Run the rebuilt wrapper to refresh its bundled Motion template,
then restart Final Cut Pro. SwiftLint is unavailable; whole-product coverage and
leak freedom have not been established by this focused change.

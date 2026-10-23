# Community MLX evaluation — 24 October 2026

## Recommendation

Keep the validated local v2 artifact for this change. The community mixed-FP16
implementation is the strongest candidate for the next inference optimization;
its released files are not a drop-in replacement for our Swift `.mlxfn` import.
Do not make Q8 the quality-first default on the evidence currently available.

This is a review of the supplied `LLM Resources/corridorkey-v2-mlx` source and
its recorded measurements. That directory contains no model weights. We have
not run those model profiles on this Mac, and have not established a speed or
quality advantage over our current artifact on matched footage and hardware.

## What differs

| Property | Current application | Community release |
|---|---|---|
| Network | Both v2 keying stages, C-RADIO, MoGe, RVM | Same model family and foundations |
| Runtime | Existing MLX Swift dependency, serialized function import | Python graph interpreter, MLX operators and custom Metal kernels; CPU PyTorch preparation |
| Precision | FP16 weight storage, FP32 computation | FP32; mixed FP16 with sensitive operations in FP32; affine group-64 Q8 linear weights with FP16 remainder |
| Shape | Shared weights across 512/768/1024/1536/2048 square graphs | Static 1024×1536 and 768×1280 profiles |
| Video history | Independent 1/1 inference, app's alpha stability pass | Persistent RVM state and overlapping stage-one Hann windows, normally 4/2 |
| Native integration | Bundled and validated for sandboxed Swift hosts | Requires conversion/reimplementation of graph execution, custom operators, shapes, color and temporal contracts |

The community format is `corridorkey-mlx-graph-v1`: `graph.json` plus component
`weights.safetensors`. Renaming or copying those files into our resource folder
will not make `MLX.importFunction` load them. Adding a Python runtime is not
proposed. All five current quality graphs must remain available to both hosts
until a deliberately designed shared replacement is validated.

## Published evidence, with its limits

The supplied `benchmarks/cli/summary.json` records 20 October 2026 measurements
on an **M4 Pro with 48 GiB**, three complete workflows after warm-up. The moving
clip is 32 frames at 1280×720, padded to 1280×768, Hann 4/2, stage-two batch one,
including four 16-bit PNG outputs per frame:

| Precision | Enabled workflow | Peak physical memory |
|---|---:|---:|
| FP32 | 37.657 s | 7.05 GiB |
| Mixed FP16 | 37.123 s | 4.11 GiB |
| Q8 | 39.397 s | 3.28 GiB |

Thus Q8 saved memory but took about 6.1% longer than FP16 in that workflow.
These end-to-end measurements cannot be compared directly with our M1 Max
single-frame square inference timings or MLX allocator memory figures.

The separate precision study reports a maximum local Q8 alpha difference of
0.068849 in blue glass and 5–10 levels of 8-bit checker-composite difference.
FP16's largest rounded checker difference was one level across its five cases.
Those are agreement results against FP32, not ground-truth quality guarantees.

Useful implementation leads include fused reconstruction and reflection-padding
kernels, paired 7×7 channel convolution, and selective FP32 reductions/normalization
inside FP16 inference. The release intentionally disables half projection pairing
because it was slower. Its 13.47× isolated reconstruction-kernel ratio must not
be described as a whole-model speedup. No community implementation or additional
third-party framework has been incorporated in this change.

## Green and blue selection

Keep **Screen Color** in both hosts with the current names and defaults. V2 uses
one model for both screens, but the selection still determines the chroma hint,
despill, spill-alpha suppression and edge decontamination. Even the community
CLI retains `--screen blue` for cleanup. Removing the control without replacing
those dependencies would change results. No Motion-template default change is
needed for the cache correction.

## Hardware priorities

MLX executes this model on the Metal GPU. [Apple's MLX overview](https://developer.apple.com/videos/play/wwdc2025/315/)
describes CPU and GPU execution; the imported graph does not gain Neural Engine
execution from a configuration toggle. Vision chooses supported devices for
subject hints. Core ML foundation partitions are an experiment for ANE use,
requiring operator-placement, transfer-cost and parity measurements. Assigning
work to every processor is not itself a performance improvement.

Keep Metal/MPS for image processing, Accelerate for CPU vector operations, and
AVFoundation/VideoToolbox for media decoding/encoding. Media Engines accelerate
supported video codecs, not CorridorKey matrix operations. Verify actual
hardware routing in Instruments rather than infer it from API names.

Next compare mixed FP16 against the current artifact at identical shapes, hints,
temporal mode and outputs on the green, blue and HardestShotEver fixtures. Measure
warm inference, complete analysis, cached playback, physical footprint and sustained
thermal behavior separately. Validate smaller-memory M1/M2 machines as well as
newer hardware before changing Automatic quality policy or shipping quantization.

Source references: [community repository](https://github.com/peterteravskis/corridorkey-v2-mlx),
[precision study](https://github.com/peterteravskis/corridorkey-v2-mlx/blob/main/docs/PRECISION.md),
[optimization study](https://github.com/peterteravskis/corridorkey-v2-mlx/blob/main/docs/OPTIMIZATIONS.md),
[profile contract](https://github.com/peterteravskis/corridorkey-v2-mlx/blob/main/docs/MODELS.md).

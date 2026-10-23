# CorridorKey v2 conversion

The app and FxPlug share `corridorkey_v2.mlxfn`: both trained keying stages,
C-RADIOv4-SO400M, MoGe-2 ViT-B and RVM-small, with shared weights across the
512, 768, 1024, 1536 and 2048 square graphs. Python is development tooling only;
the sandboxed app imports the serialized graph using its existing MLX Swift
dependency. No downloads, Python runtime or new frameworks are required at runtime.

## Reproduce

Use Python 3.12 on an Apple Silicon Mac with Metal access. From the repository root:

```sh
python3.12 -m venv Tools/CorridorKeyV2/.venv
Tools/CorridorKeyV2/.venv/bin/python -m pip install -r Tools/CorridorKeyV2/requirements.txt
```

Place the official v2 repository in `LLM Resources/CorridorKey2.0`, and its
`corridorkey_v2.safetensors` and `foundation_stats.safetensors` in
`LLM Resources/CorridorKey2.0 Hugging Face Files`. Fetch the foundation assets
with the reference repository's `scripts/download_weights.py --skip_corridorkey`.
The local layout and pinned foundation revisions are recorded in the shipped
`Source/CorridorKeyByLateNite/Plugin/Resources/Model Licenses/Notices.txt`.

```sh
Tools/CorridorKeyV2/.venv/bin/python -m unittest discover -s Tools/CorridorKeyV2 -p 'test_*.py'
Tools/CorridorKeyV2/.venv/bin/python -u Tools/CorridorKeyV2/export.py \
  --green-clip 'LLM Resources/Benchmark/NikoDruid/Niko - 4 frames.mov' \
  --blue-clip 'LLM Resources/Benchmark/Blue Screen/Blue Screen - 4 Frames.mov'
```

Conversion needs substantial memory and disk space: the float32 PyTorch reference,
export graph, MLX weights and intermediates coexist. It was validated on a 64 GB
M1 Max. This is a conversion requirement, not a measured minimum app requirement.
All inputs are local after the foundation download. Conversion fails on unknown
operators, checkpoint mismatches, unsupported dimensions, nonfinite results or
parity failures. It publishes the artifact only after reference comparisons on
both supplied clips and serialization/reload checks at every requested size.
Default tolerances are mean absolute error ≤0.002 and maximum error ≤0.05 for
both alpha and foreground. These are numerical parity gates, not perceptual
quality guarantees for every shot.

The default export stores learned parameters in float16 and computes in float32.
`--weight-precision float32` produces a larger full-precision diagnostic export.
PyTorch's functional export removes mutations. `lowering.py` maps the resulting
operators to MLX and preserves PyTorch's interpolation conventions, including
DINOv2's fractional positional-embedding scale. Shape-dependent constants remain
independent; learned weights and fixed buffers share storage across all traces.

After successful conversion, copy `artifacts/corridorkey_v2.mlxfn` into
`Source/CorridorKeyByLateNite/Plugin/Resources/MLX Models/` and retain the generated
JSON report. The model is tracked with Git LFS. `validation.json` records the
shipped artifact's checksum and numerical results.

## Host contract

- Input: float32 NHWC `[1, size, size, 4]`, ImageNet-normalized video-gamma RGB
  plus the existing foreground hint (1 = foreground, 0 = background).
- The adapter decodes signed sRGB to scene-linear RGB. The reference applies its
  signed asinh encoding and separate SDR foundation proxy. Above-white and
  negative values survive the transfer functions.
- Automated hint quality is 0.75, matching the upstream runtime's automated-matte
  convention. All three foundations participate in every prediction.
- Outputs: float32 NHWC alpha `[1, size, size, 1]` and straight video-gamma
  foreground `[1, size, size, 3]`. Alpha is clamped to [0, 1]. Outputs are y-up
  to match the existing Metal writeback. Swift makes the returned views contiguous
  on the GPU before exposing their Metal buffers.
- One independent frame (v2's 1/1 mode), with fresh RVM state for each request.
  There is no shared clip history or dependence on render order. The existing
  Temporal Stability postprocess remains available in both hosts.

This migration preserves the existing square Quality ladder and inspector/Motion
defaults. It does not implement upstream temporal-window/Hann accumulation,
native-resolution aspect-preserving inference, or a new end-to-end HDR workflow.
Saved v1 mattes are invalidated by analysis schema 4 and need analysis again.

## Validation and performance

Build the Xcode scheme `CorridorKey by LateNite` for arm64/macOS 26. Run Swift
logic, Metal and inference tests using `swift test --package-path Source` with
GPU access; see the inference fixtures README for MLX kernel-library setup.
The inference suites serialize to avoid loading multiple multi-gigabyte models
concurrently. Both interfaces use the same inference, hint and refinement code.
The Swift runtime caps MLX's reusable-buffer cache at 1 GiB (the allocator may
temporarily overshoot by an allocation). This excludes active model tensors.
Its zero-copy input uses the existing MLX C API with balanced buffer ownership
to avoid the raw-pointer finalizer leak in MLX Swift 0.31.3.

```sh
Tools/CorridorKeyV2/.venv/bin/python -u Tools/CorridorKeyV2/benchmark.py --cache-limit-mib 1024
```

Run the benchmark without other GPU workloads. It measures model execution plus
contiguous output materialization after warm-up, and records allocator memory.
It excludes decoding, host Metal processing and export encoding. Diagnostic
PNGs show source, alpha and checkerboard composite. They are intentionally outside
the app's refinement pipeline. Measurements and remaining release checks are in
`Source/Benchmarks/CorridorKey-v2.md`.

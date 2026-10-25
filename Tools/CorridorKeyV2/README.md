# CorridorKey v2 video backend

The standalone editor and FxPlug effect use one staged MLX artifact containing
both v2 keying stages, C-RADIOv4-SO400M, MoGe-2 ViT-B and recurrent RVM-small.
Python is offline conversion and validation tooling only. The sandboxed app uses
the existing MLX Swift dependency; it downloads nothing and embeds no Python.

## Reproduce the shipping artifact

Use Python 3.12, the packages in `requirements.txt`, and an Apple Silicon Mac with
Metal access. The conversion was run on an M1 Max with 64 GB unified memory;
this is not a measured minimum requirement for the application.

The official repository and assets must be available in `LLM Resources/CorridorKey2.0`
and `LLM Resources/CorridorKey2.0 Hugging Face Files`. Foundation revisions and
license notices are recorded in the app's `Resources/Model Licenses` directory.

```sh
python3.12 -m venv Tools/CorridorKeyV2/.venv
Tools/CorridorKeyV2/.venv/bin/python -m pip install -r Tools/CorridorKeyV2/requirements.txt
Tools/CorridorKeyV2/.venv/bin/python -m unittest discover -s Tools/CorridorKeyV2 -p 'test_*.py'
Tools/CorridorKeyV2/.venv/bin/python -u Tools/CorridorKeyV2/export_video.py \
  --output Tools/CorridorKeyV2/artifacts/corridorkey_v2.mlxfn
Tools/CorridorKeyV2/.venv/bin/python -u Tools/CorridorKeyV2/validate_video.py \
  --model Tools/CorridorKeyV2/artifacts/corridorkey_v2.mlxfn \
  --report Tools/CorridorKeyV2/video-output-validation.json \
  --fixture /private/tmp/ckv2-video-fixture
Tools/CorridorKeyV2/.venv/bin/python -u Tools/CorridorKeyV2/validate_video.py \
  --model Tools/CorridorKeyV2/artifacts/corridorkey_v2.mlxfn \
  --report Tools/CorridorKeyV2/video-clip-validation.json --real-clips
Tools/CorridorKeyV2/.venv/bin/python -u Tools/CorridorKeyV2/check_video_profiles.py \
  --model Tools/CorridorKeyV2/artifacts/corridorkey_v2.mlxfn \
  --report Tools/CorridorKeyV2/video-profile-validation.json
```

Only install the artifact after the numerical gates pass. Copy it to
`Source/CorridorKeyByLateNite/Plugin/Resources/MLX Models/corridorkey_v2.mlxfn`.
This multi-gigabyte file is deliberately ignored by Git; a fresh checkout must
reproduce or supply the matching model. Never force-add it to the repository.

The earlier `export.py`, `compare.py` and their reports describe independent-frame
diagnostic artifacts. **Those artifacts cannot replace the staged video model.**

## Shared host behavior

- Time Awareness: Off, 2, 4, 8, 24, 48 and 80 frames. Analysis extracts frozen
  features once per chronological frame, preserves RVM state, accumulates
  overlapping temporal batons with upstream cosine tapers, then refines each
  frame. Single-frame external hints propagate forwards and backwards from the
  zero-based Reference Frame. Temporal Stability remains a separate optional
  alpha smoothing control.
- Low GPU Memory keeps precomputed features on disk; disabling it retains the
  active window for reuse. Refinement and output encoding remain per-frame.
  Short clips select the smallest compatible temporal profile. A conservative
  FP32 working-set preflight rejects requests exceeding the device budget.
- External Alpha Hint supports a still reference, a matching movie, or a folder
  of naturally ordered image frames. Dimensions and sequence length must match;
  movies must also match frame rate and duration. Selection uses read-only security-scoped
  bookmarks. Strength defaults to 0.75; propagated internal hints use 0.95.
  All Frames and Single Frame have the same names and validation in both hosts.
  Hint output displays the selected matte; None supplies the model's -1 sentinel.
- Input is Linear bypasses display decoding. Signed transfer functions preserve
  negative and above-white RGB, and alpha never receives a transfer curve.
  Linearize Output, Original and Keep Original in Solid Areas are shared controls.
  Linear TIFF export uses half-float channels; integer formats still have their
  format's limited numeric range. Movie transfer tags describe the chosen output.
- Auto, Green, Blue and Custom screen colors use the same rendering code in both
  hosts. Despill Strength defaults to zero. Motion template defaults are updated
  alongside Swift controls; saved explicit values remain explicit.
- The source aspect ratio is fitted into the selected square profile using
  reflected padding. Predictions are cropped before storage and composited at
  native source size. Quality still selects the internal longest-edge ladder:
  512, 768, 1024, 1536, 2048.

## Tensor contract

The `.mlxfn` dispatches on input arity and static shapes, sharing learned weights:

| Inputs | Operation | Outputs |
|---|---|---|
| Scene-linear RGBA `[1,H,W,4]`, RVM state | Foundation extraction | C-RADIO, MoGe, RVM features; next RVM state |
| RGBA `[T,H,W,4]`, confidence `[1,T]`, three feature sequences | Temporal stage one | Baton `[1,T,512,H/16,W/16]`, full-size auxiliary hints |
| RGBA `[1,H,W,4]`, accumulated baton, empty dispatch marker | Stage-two refinement | Alpha `[1,H,W,1]`, straight linear RGB `[1,H,W,3]` |

The Swift analysis session owns clip history; it never lives in the shared model.
Public model tensors compute in FP32 with FP16 weight storage. Cached foreground
is signed display-encoded RGBA16F, allowing output-only edits to reuse predictions.
Schema 9 invalidates earlier caches. Analyse Clip is required after this upgrade.

## Storage and lifecycle

Complete predictions use compressed CKF1 files and small persisted references.
The cache limits compressed RAM to 128 MiB and disk payloads to 64 GiB per sandbox.
Active analysis/export passes hold eviction leases; missing files produce an
actionable reanalysis error. Keyed exports require a prediction for every frame
and pin all required sessions before touching their destination. Original and
Hint can export without analysis. Preview disk/GPU work runs outside the main actor.

Temporal prepass scratch is separately limited to 64 GiB per pass, reserving
512 MiB free disk space. Normal completion/cancellation removes scratch, and old
abandoned passes are reclaimed using process leases. This can limit long analyses;
it is not an unlimited out-of-core backend. Large windows can still exceed GPU
memory despite Low GPU Memory. Device budget is not a measurement of free RAM.

## Validation and performance evidence

`video-export-validation.json` records the artifact hash, supported profiles and
stage-level comparisons. The installed export numerically checked T=1 and T=2 at
every resolution; larger temporal graphs were structurally checked on reload.
`video-output-validation.json` checks complete recurrent and overlapping outputs
against the official FP32 reference, including T=2/T=4 and all explicit quality
levels. Final alpha and foreground gates are maximum error <=0.05 and mean error
<=0.002; nonfinite outputs fail. Synthetic plates alone do not establish perceptual
quality on arbitrary footage. Real benchmark-clip results are recorded separately.
The current eight real-clip frames passed at 512/T4; the 8/24/48/80-frame profiles
also passed finite-output smoke checks at 512. Long-profile smoke checks are not
numerical reference comparisons, and their repeated plate is not a moving clip.

```sh
CK_V2_REFERENCE_FIXTURE=/private/tmp/ckv2-video-fixture \
  swift test --package-path Source --enable-code-coverage
swift test --package-path Source -c release -Xswiftc -enable-testing --filter compiledGraphParity
```

The reference fixture test exercises the actual Swift session, all three stages,
overlap reuse, canonical row order and identical low-memory/full-memory outputs.
MLX compilation is enabled in optimized builds only: the MLX 0.31.3 Debug
compiler-cache destructor was observed overflowing its stack. The earlier
`compiled-runtime.json` timings are a baseline for the old single-frame adapter,
not a speed claim for temporal inference. The current staged artifact's T=1
measurements are in `video-compiled-runtime.json`: 1.9–8.1% lower latency with
identical alpha and maximum RGB difference below 0.00000024 on this M1 Max.
The production Swift compiler also passes long-profile smoke tests at 512.
Mixed FP16 activation work remains
experimental: the compiled 2048 foreground exceeded the parity gate and is not
shipped. The v1 `corridorkey-mlx` Hiera speed claims do not transfer to v2's three
foundations and temporal network.

Build the Xcode scheme `CorridorKey by LateNite` for arm64/macOS 26. Live Final Cut
Pro interaction, signing/distribution, TestFlight, accessibility and long-form
profiling still require release validation. Historical Instruments and coverage
results, including their limitations, are in `Source/Benchmarks/CorridorKey-v2.md`.

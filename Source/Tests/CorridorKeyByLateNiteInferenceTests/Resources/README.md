# Inference tests

Tests read the production v2 artifact at
`Source/CorridorKeyByLateNite/Plugin/Resources/MLX Models/corridorkey_v2.mlxfn`.
This generated artifact is Git-ignored. Reproduce it with
`Tools/CorridorKeyV2/README.md`; do not copy it into the test bundle.
Missing model files fail the tests. All inference suites serialize under
`MLXInferenceTests` to avoid exhausting unified memory with multiple models.

SwiftPM does not compile MLX's Metal kernel library. Build the Xcode scheme first,
then copy `default.metallib` from `mlx-swift_Cmlx.bundle/Contents/Resources`
into the test executable directory as both `mlx.metallib` and `default.metallib`.
The executable directory is normally
`Source/.build/arm64-apple-macosx/debug/CorridorKeyToolboxLogicPackageTests.xctest/Contents/MacOS`.
The existing `Source/default.metallib` also works when it matches the resolved MLX
dependency. Tests require real Metal access.

```sh
swift test --package-path Source --filter MLXInferenceTests
```

Tests cover every quality and screen selection, Swift/Metal writeback, orientation,
zero-copy/staging parity, determinism, active-memory growth, cache reclamation,
shared model ownership and warm-up failures. V2 weights occupy about 2.3 GiB;
cached GPU temporaries are additional and are released after analysis.
Python conversion tests independently compare model output with the official
PyTorch reference. See `Tools/CorridorKeyV2/README.md` for conversion instructions.

The serial suite also compiles the actual standalone analysis/renderer adapters
with `CORRIDOR_KEY_HEADLESS_TESTS`. This tests the cache boundary and composition,
where model-only orientation tests cannot catch host-specific extra row flips.
The SPM Metal cache compiles the shipped shaders from source; the app and FxPlug
continue to use Xcode's compiled library.

`StandalonePipelineTests` requires these local benchmark clips:

- `LLM Resources/Benchmark/NikoDruid/Niko - 4 frames.mov`
- `LLM Resources/Benchmark/JallenClownWater/Input/HardestShotEver - 1sec.mov`

Run only the host integration tests with:

```sh
swift test --package-path Source --filter StandalonePipelineTests
```

HardestShotEver writes `CorridorKey-v2-HardestShotEver.png` to the process's
temporary directory and prints the absolute path. Panels are source, matte, and
processed foreground over white. It uses Maximum quality and Apple Vision.

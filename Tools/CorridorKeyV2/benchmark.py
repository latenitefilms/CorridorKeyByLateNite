"""Measure exported inference and render diagnostic previews from benchmark clips.

This measures MLX inference, including contiguous output materialization, but
excludes host decoding, hint generation, Metal refinement and file encoding.
Run without other GPU workloads for useful timings.
"""

import argparse
import gc
import json
from pathlib import Path
import statistics
import time

import cv2
import mlx.core as mx
import numpy as np


def load_input(clip, resolution, screen):
    """Decode one display-RGB frame and form an approximate chroma hint."""
    capture = cv2.VideoCapture(str(clip))
    success, frame = capture.read()
    capture.release()
    if not success:
        raise ValueError(f"Cannot decode {clip}")
    display = cv2.cvtColor(cv2.resize(frame, (resolution, resolution)), cv2.COLOR_BGR2RGB).astype(np.float32) / 255
    dominant = 1 if screen == "green" else 2
    other = [index for index in range(3) if index != dominant]
    hint = 1 - np.clip((display[..., dominant] - display[..., other].max(axis=-1)) * 2, 0, 1)
    normalized = (display - [0.485, 0.456, 0.406]) / [0.229, 0.224, 0.225]
    return display, mx.array(np.concatenate((normalized, hint[..., None]), axis=-1)[None].astype(np.float32))


def preview(path, source, outputs):
    """Save source, alpha and a checkerboard composite in host orientation."""
    alpha, foreground = (np.asarray(value)[0, ::-1] for value in outputs)
    rows, columns = np.indices(source.shape[:2])
    checker = np.where(((rows // 32 + columns // 32) % 2)[..., None], 0.3, 0.6)
    composite = foreground * alpha + checker * (1 - alpha)
    panels = [source, np.repeat(alpha, 3, axis=-1), composite]
    image = np.concatenate([cv2.resize(panel, (512, 512)) for panel in panels], axis=1)
    cv2.imwrite(str(path), cv2.cvtColor((np.clip(image, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))


def main():
    """Record warmed timing samples and MLX allocator measurements by quality."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, default=Path("Source/CorridorKeyByLateNite/Plugin/Resources/MLX Models/corridorkey_v2.mlxfn"))
    parser.add_argument("--output", type=Path, default=Path("Tools/CorridorKeyV2/artifacts/benchmark.json"))
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--resolutions", type=int, nargs="+", default=[512, 768, 1024, 1536, 2048])
    parser.add_argument("--cache-limit-mib", type=int)
    args = parser.parse_args()
    if args.iterations < 1:
        parser.error("iterations must be positive")
    if args.cache_limit_mib is not None:
        mx.set_cache_limit(args.cache_limit_mib * 1024 * 1024)
    clips = {"green": Path("LLM Resources/Benchmark/NikoDruid/Niko - 4 frames.mov"),
             "blue": Path("LLM Resources/Benchmark/Blue Screen/Blue Screen - 4 Frames.mov")}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    function = mx.import_function(str(args.artifact))
    report = {"device": mx.device_info(), "scope": "MLX inference plus contiguous outputs",
              "cache_limit_mib": args.cache_limit_mib, "measurements": []}
    for resolution in args.resolutions:
        for screen, clip in clips.items():
            source, inputs = load_input(clip, resolution, screen)
            outputs = [mx.contiguous(value) for value in function(inputs)]
            mx.eval(outputs)
            del outputs
            mx.clear_cache()
            mx.reset_peak_memory()
            times = []
            for _ in range(args.iterations):
                start = time.perf_counter()
                outputs = [mx.contiguous(value) for value in function(inputs)]
                mx.eval(outputs)
                times.append(time.perf_counter() - start)
                if not all(np.isfinite(np.asarray(value)).all() for value in outputs):
                    raise ValueError("Nonfinite output")
                del outputs
            measurement = dict(resolution=resolution, screen=screen, seconds=times,
                               median_seconds=statistics.median(times),
                               active_bytes=mx.get_active_memory(), cache_bytes=mx.get_cache_memory(),
                               peak_bytes=mx.get_peak_memory())
            report["measurements"].append(measurement)
            print(json.dumps(measurement), flush=True)
            if resolution == 1024:
                outputs = [mx.contiguous(value) for value in function(inputs)]
                mx.eval(outputs)
                preview(args.output.parent / f"{screen}-preview.png", source, outputs)
                del outputs
            del source, inputs
            gc.collect()
            mx.clear_cache()
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()

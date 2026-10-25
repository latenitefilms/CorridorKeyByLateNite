"""Compare candidate model artifacts without replacing the app's validated model.

Measures alternating warm model calls with contiguous outputs. Host decoding,
Metal refinement, cache I/O and encoding are excluded. Run without other GPU work.
"""

import argparse
import json
from pathlib import Path
import statistics
import time

import mlx.core as mx
import numpy as np

from benchmark import load_input
from export import parity_metrics


def main():
    """Record numeric parity and warmed timing for every requested clip/profile."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, default=Path(
        "Source/CorridorKeyByLateNite/Plugin/Resources/MLX Models/corridorkey_v2.mlxfn"))
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--resolutions", type=int, nargs="+", default=[512, 768, 1024, 1536, 2048])
    parser.add_argument("--iterations", type=int, default=5)
    parser.add_argument("--uncompiled", action="store_true")
    args = parser.parse_args()
    if args.iterations < 1:
        parser.error("iterations must be positive")
    mx.set_cache_limit(1024 * 1024 * 1024)
    functions = {}
    for name, path in (("baseline", args.baseline), ("candidate", args.candidate)):
        imported = mx.import_function(str(path))
        def invoke(source, imported=imported):
            return [mx.contiguous(value) for value in imported(source)]
        functions[name] = invoke if args.uncompiled else mx.compile(invoke, shapeless=False)
    clips = {
        "green": Path("LLM Resources/Benchmark/NikoDruid/Niko - 4 frames.mov"),
        "blue": Path("LLM Resources/Benchmark/Blue Screen/Blue Screen - 4 Frames.mov"),
    }
    report = dict(device=mx.device_info(), baseline=str(args.baseline), candidate=str(args.candidate),
                  compiled=not args.uncompiled, cache_limit_mib=1024,
                  scope="model plus contiguous outputs, first frame of each clip", measurements=[])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    for resolution in args.resolutions:
        for screen, clip in clips.items():
            _, source = load_input(clip, resolution, screen)
            mx.eval(source)
            predictions = {}
            warmup = {}
            for name, function in functions.items():
                start = time.perf_counter()
                outputs = function(source)
                mx.eval(outputs)
                warmup[name] = time.perf_counter() - start
                predictions[name] = [np.asarray(value).copy() for value in outputs]
                del outputs
            metrics = parity_metrics(predictions["baseline"], predictions["candidate"])
            del predictions
            timings = {name: [] for name in functions}
            for iteration in range(args.iterations):
                order = list(functions.items())
                if iteration % 2:
                    order.reverse()
                for name, function in order:
                    start = time.perf_counter()
                    outputs = function(source)
                    mx.eval(outputs)
                    timings[name].append(time.perf_counter() - start)
                    del outputs
            measurement = dict(resolution=resolution, screen=screen, metrics=metrics, warmup_seconds=warmup,
                               samples_seconds=timings,
                               median_seconds={name: statistics.median(values) for name, values in timings.items()})
            report["measurements"].append(measurement)
            args.output.write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(measurement), flush=True)


if __name__ == "__main__":
    main()

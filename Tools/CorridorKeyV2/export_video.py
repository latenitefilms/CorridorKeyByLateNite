"""Export the staged v2 video contract, with shared weights and bounded refinement.

Two inputs select foundation extraction, five select temporal stage one, and
three select per-frame refinement. Public tensors use FP32 scene-linear RGB.
The third refinement argument is an empty dispatch marker. No Python runtime
or third-party execution engine is embedded in the application.
"""

import argparse
import gc
import hashlib
import json
import math
from pathlib import Path
import time

import mlx.core as mx
import numpy as np
import torch

from lowering import LoweredGraph, array_from_torch
from reference import (load_reference, prepare_for_export, FoundationReference,
                       TemporalStageReference, RefinementReference)
from export import validation_source


def compare(reference, actual, label):
    """Bound intermediate relative error as well as final output absolute error."""
    metrics = []
    for index, (expected, observed) in enumerate(zip(reference, actual, strict=True)):
        expected = expected.detach().numpy()
        observed = np.asarray(observed)
        if expected.shape != observed.shape or not np.isfinite(observed).all():
            raise ValueError(f"Invalid {label} output {index}")
        delta = np.abs(expected - observed)
        scale = max(float(np.max(np.abs(expected))), 1.)
        metrics.append(dict(maximum_error=float(delta.max()), mean_error=float(delta.mean()),
                            relative_maximum_error=float(delta.max()) / scale))
        if float(delta.mean()) / scale > .002 or float(delta.max()) / scale > .05:
            raise ValueError(f"Parity failure for {label} output {index}: {metrics[-1]}")
    return metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, default=Path("LLM Resources/CorridorKey2.0"))
    parser.add_argument("--weights", type=Path, default=Path("LLM Resources/CorridorKey2.0 Hugging Face Files"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--resolutions", type=int, nargs="+", default=[512, 768, 1024, 1536, 2048])
    parser.add_argument("--windows", type=int, nargs="+", default=[1, 2, 4, 8, 24, 48, 80])
    parser.add_argument("--validate-windows", type=int, nargs="+", default=[1, 2, 4])
    args = parser.parse_args()
    if any(value < 128 or value % 128 for value in args.resolutions):
        parser.error("Resolutions must be multiples of 128")
    if any(value < 1 or value > 80 for value in args.windows):
        parser.error("Temporal windows must be in 1…80")
    torch.set_num_threads(6)
    torch.manual_seed(2026)
    model = load_reference(args.reference, args.weights).requires_grad_(False)
    prepare_for_export(model)
    # Exact attention/MLP chunking bounds transient allocations at large T.
    from corridorkey.runtime import configure_low_vram_inference, InferenceConfig
    configure_low_vram_inference(model, InferenceConfig())
    modules = {2: FoundationReference(model).eval(), 5: TemporalStageReference(model).eval(),
               3: RefinementReference(model).eval()}
    graphs = {}
    shared_weights = {}
    records = []
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(".partial.mlxfn")

    def bridge(*inputs):
        return graphs[(len(inputs), inputs[0].shape[0], inputs[0].shape[1])](*inputs)

    def trace(exporter, inputs, validate=True):
        label = f"{len(inputs)} inputs, {inputs[0].shape}"
        print(f"Tracing {label}", flush=True)
        started = time.monotonic()
        module = modules[len(inputs)]
        if len(inputs) == 5:
            # Shifted-window regions are shape constants. Populate the official
            # helper's cache outside FakeTensor tracing; this avoids tracing its
            # Python tolist() without running an 80-frame CPU inference first.
            from corridorkey.blocks import _shifted_region_groups_3d_cached
            for block in model.stage1.modules():
                if not hasattr(block, "shift_h") or not hasattr(block, "window_H"):
                    continue
                for frames in (1, inputs[0].shape[0]):
                    for divisor in (16, 64):
                        size = inputs[0].shape[1] // divisor
                        padded_h = math.ceil(size / block.window_H) * block.window_H
                        padded_w = math.ceil(size / block.window_W) * block.window_W
                        _shifted_region_groups_3d_cached(frames, size, size, padded_h, padded_w,
                            block.window_H, block.window_W, block.shift_h, block.shift_w)
        reference = module(*inputs) if validate else None
        exported = torch.export.export(module, inputs, strict=False).run_decompositions({})
        exported.graph.eliminate_dead_code()
        lowered = LoweredGraph(exported, shared_weights, "float16", "float32")
        key = (len(inputs), inputs[0].shape[0], inputs[0].shape[1])
        graphs[key] = lowered
        converted = tuple(array_from_torch(value) for value in inputs)
        metrics = None
        if validate:
            actual = bridge(*converted)
            mx.eval(actual)
            metrics = compare(reference, actual, label)
            del actual, reference
        exporter(*converted)
        records.append(dict(inputs=[list(value.shape) for value in inputs], metrics=metrics,
                            seconds=time.monotonic() - started))
        print(json.dumps(records[-1]), flush=True)
        del graphs[key], lowered, exported, converted
        gc.collect()
        mx.clear_cache()

    try:
        with torch.no_grad(), mx.exporter(str(temporary), bridge) as exporter:
            for resolution in args.resolutions:
                source = torch.from_numpy(validation_source(resolution, "green"))
                state = torch.zeros((1, 1 + (resolution // 64)**2, model.foundations.rvm_dim))
                # Warm only foundation caches; temporal graphs have no learned cache.
                features = modules[2](source, state)
                trace(exporter, (source, state))
                baton = torch.zeros((1, 1, model.d_16, resolution // 16, resolution // 16))
                trace(exporter, (source, baton, torch.empty(0)))
                for window in args.windows:
                    sequence = source.repeat(window, 1, 1, 1)
                    quality = torch.full((1, window), .75)
                    radio = features[0].unsqueeze(1).repeat(1, window, 1, 1, 1)
                    moge = features[1].unsqueeze(1).repeat(1, window, 1, 1, 1)
                    rvm = features[2].repeat(1, window, 1, 1, 1)
                    trace(exporter, (sequence, quality, radio, moge, rvm),
                          validate=window in args.validate_windows)
                    del sequence, quality, radio, moge, rvm
                del source, state, features, baton
        # Structural dispatch is checked after serialization, in addition to
        # numerical validation. Full real-clip runtime checks are a separate gate.
        imported = mx.import_function(str(temporary))
        for record in records:
            inputs = [mx.zeros(shape) for shape in record["inputs"]]
            outputs = imported(*inputs)
            if len(outputs) != (4 if len(inputs) == 2 else 2):
                raise ValueError("Serialized output count mismatch")
            del inputs, outputs
        del imported
        temporary.replace(args.output)
        with args.output.open("rb") as artifact:
            digest = hashlib.file_digest(artifact, "sha256").hexdigest()
        report = dict(contract="corridorkey-v2-video-1", resolutions=args.resolutions,
                      windows=args.windows, weight_precision="float16", activation_precision="float32",
                      sha256=digest, bytes=args.output.stat().st_size, validation=records)
        args.output.with_suffix(".json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Exported staged model: {args.output}", flush=True)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    main()

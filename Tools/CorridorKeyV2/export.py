"""Convert and validate CorridorKey v2 into a self-contained MLX function.

Run from the repository root. Conversion is offline once the official model
assets are present. The output contains all five production resolutions and
one shared set of weights for green and blue screens.
"""

import argparse
import gc
import hashlib
import json
from pathlib import Path
import time

import cv2
import mlx.core as mx
import numpy as np
import torch

from lowering import LoweredGraph, array_from_torch
from reference import load_reference, prepare_for_export, SingleFrameReference
from color import display_to_linear, linear_to_display


def validation_source(resolution, screen, clip=None):
    """Create a deterministic linear-light plate and an automatic chroma hint."""
    if clip is not None:
        reader = cv2.VideoCapture(str(clip))
        success, frame = reader.read()
        reader.release()
        if not success:
            raise ValueError(f"Cannot decode validation clip: {clip}")
        rgb = cv2.cvtColor(cv2.resize(frame, (resolution, resolution)), cv2.COLOR_BGR2RGB) / 255.0
        rgb = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055)**2.4)
    else:
        rows, columns = np.mgrid[:resolution, :resolution].astype(np.float32) / resolution
        subject = ((columns - 0.42)**2 + (rows - 0.35)**2) < 0.04
        background = [0.02, 0.65, 0.03] if screen == "green" else [0.02, 0.03, 0.65]
        rgb = np.broadcast_to(background, (resolution, resolution, 3)).copy()
        rgb[subject] = np.stack((0.3 + rows, 0.1 + columns * 0.2, 0.12 + rows * 0.1), axis=-1)[subject]
    dominant = 1 if screen == "green" else 2
    others = [index for index in range(3) if index != dominant]
    excess = np.maximum(rgb[..., dominant] - np.max(rgb[..., others], axis=-1), 0)
    hint = 1 - np.clip(excess * 2, 0, 1)
    return np.concatenate((rgb, hint[..., None]), axis=-1)[None].astype(np.float32)


def parity_metrics(expected, actual):
    """Require finite predictions and report alpha and foreground error."""
    metrics = []
    for name, reference, result in zip(("alpha", "foreground"), expected, actual):
        result = np.asarray(result)
        if not np.isfinite(result).all():
            raise ValueError(f"Nonfinite {name} prediction")
        difference = np.abs(reference - result)
        entry = dict(output=name, maximum_error=float(difference.max()),
                     mean_error=float(difference.mean()), rmse=float(np.sqrt(np.mean(difference**2))))
        # Weight rounding can amplify individual edge pixels. Bound both
        # aggregate error and maximum error; do not hide large local failures.
        if entry["mean_error"] > 0.002 or entry["maximum_error"] > 0.05:
            raise ValueError(f"Parity failure: {entry}")
        metrics.append(entry)
    return metrics


def main():
    """Export only after every requested resolution passes reference parity."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, default=Path("LLM Resources/CorridorKey2.0"))
    parser.add_argument("--weights", type=Path, default=Path("LLM Resources/CorridorKey2.0 Hugging Face Files"))
    parser.add_argument("--output", type=Path, default=Path("Tools/CorridorKeyV2/artifacts/corridorkey_v2.mlxfn"))
    parser.add_argument("--resolutions", type=int, nargs="+", default=[512, 768, 1024, 1536, 2048])
    parser.add_argument("--weight-precision", choices=["float32", "float16"], default="float16")
    parser.add_argument("--activation-precision", choices=["float32", "mixed-float16"], default="float32",
                        help="Experimental mixed precision must pass the same reference gates as float32")
    parser.add_argument("--green-clip", type=Path)
    parser.add_argument("--blue-clip", type=Path)
    parser.add_argument("--stress-clip", type=Path, help="Additional difficult green-screen plate for reference validation")
    args = parser.parse_args()
    if any(size < 128 or size % 128 for size in args.resolutions):
        parser.error("Resolutions must be positive multiples of 128")
    torch.set_num_threads(6)
    torch.manual_seed(2026)
    model = SingleFrameReference(load_reference(args.reference, args.weights)).eval().requires_grad_(False)
    prepare_for_export(model.model)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(".partial.mlxfn")
    shared_weights = {}
    graphs = {}
    report = {"model": "CorridorKey v2", "mode": "independent-frame-1/1", "shape_quantum": 128,
              "weight_precision": args.weight_precision, "activation_precision": args.activation_precision,
              "input": "imagenet-normalized-display-rgb+hint-nhwc-float32",
              "output": "alpha+straight-display-rgb-nhwc-float32-y-up",
              "resolutions": args.resolutions, "validation": []}
    mean = mx.array([0.485, 0.456, 0.406, 0])
    deviation = mx.array([0.229, 0.224, 0.225, 1])

    def bridge(normalized):
        display = normalized * deviation + mean
        linear = mx.concatenate((display_to_linear(display[..., :3], mx), display[..., 3:]), axis=-1)
        alpha, foreground = graphs[normalized.shape[1]](linear)
        foreground = linear_to_display(foreground, mx)
        # The existing fused Metal writeback expects y-up model outputs.
        # Contiguous is not serializable in MLX 0.31. Swift materializes the
        # returned views before exposing their storage to the Metal writeback.
        return alpha[:, ::-1], foreground[:, ::-1]

    def normalized_source(source):
        source = mx.array(source)
        display = mx.concatenate((linear_to_display(source[..., :3], mx), source[..., 3:]), axis=-1)
        return (display - mean) / deviation

    def host_predictions(predictions):
        alpha, foreground = predictions
        return np.flip(alpha, axis=1), np.flip(linear_to_display(foreground, np), axis=1)

    try:
        with torch.no_grad(), mx.exporter(str(temporary), bridge) as exporter:
            for resolution in args.resolutions:
                print(f"Tracing {resolution}px", flush=True)
                samples = [(screen, validation_source(resolution, screen, clip)) for screen, clip in
                           (("green", args.green_clip), ("blue", args.blue_clip))]
                if args.stress_clip is not None:
                    samples.append(("stress-green", validation_source(resolution, "green", args.stress_clip)))
                # Warm shape-dependent upstream caches before torch.export.
                expected = [tuple(value.cpu().numpy() for value in model(torch.from_numpy(source)))
                            for _, source in samples]
                exported = torch.export.export(model, (torch.from_numpy(samples[0][1]),), strict=False)
                exported = exported.run_decompositions({})
                exported.graph.eliminate_dead_code()
                lowered = LoweredGraph(exported, shared_weights, args.weight_precision, args.activation_precision)
                graphs[resolution] = lowered
                for (screen, source), reference in zip(samples, expected):
                    normalized = normalized_source(source)
                    start = time.monotonic()
                    prediction = bridge(normalized)
                    mx.eval(prediction)
                    metrics = parity_metrics(host_predictions(reference), prediction)
                    entry = dict(resolution=resolution, screen=screen,
                                 seconds=time.monotonic()-start, metrics=metrics)
                    report["validation"].append(entry)
                    print(json.dumps(entry), flush=True)
                exporter(mx.zeros((1, resolution, resolution, 4)))
                del graphs[resolution], lowered, exported, expected, prediction
                gc.collect()
                mx.clear_cache()
        imported = mx.import_function(str(temporary))
        # Verify serialization and dispatch select the correct graph at every size.
        for resolution in args.resolutions:
            source = validation_source(resolution, "green", args.green_clip)
            normalized = normalized_source(source)
            actual = imported(normalized)
            mx.eval(actual)
            reference = host_predictions(tuple(value.cpu().numpy() for value in model(torch.from_numpy(source))))
            parity_metrics(reference, actual)
            print(f"Reloaded {resolution}px: passed", flush=True)
        temporary.replace(args.output)
        with args.output.open("rb") as artifact:
            report["sha256"] = hashlib.file_digest(artifact, "sha256").hexdigest()
        report["bytes"] = args.output.stat().st_size
        args.output.with_suffix(".json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Validated model: {args.output}", flush=True)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    main()

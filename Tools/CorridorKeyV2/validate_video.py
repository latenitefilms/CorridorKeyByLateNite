"""Compare complete recurrent/temporal/refinement outputs against official v2.

Uses the released PyTorch weights as the oracle, independent FP32 intermediates
on both sides, overlapping cosine-weighted batons, and propagated alpha hints.
Never relaxes the final-image gates when intermediate comparisons pass.
"""
import argparse
import gc
import json
import math
from pathlib import Path
import time

import cv2
import mlx.core as mx
import numpy as np
import torch

from export import validation_source, parity_metrics
from reference import load_reference, prepare_for_export, FoundationReference, TemporalStageReference, RefinementReference


def run(frames, window, foundation, temporal, refinement, backend):
    """Follow the runtime's continuous prepass and half-window baton overlap."""
    count, size = len(frames), frames[0].shape[1]
    is_torch = backend == "torch"
    array = torch.from_numpy if is_torch else mx.array
    numpy = (lambda value: value.detach().numpy()) if is_torch else np.asarray
    state = array(np.zeros((1, 1 + size * size // 4096, 384), np.float32))
    features = []
    sources = [array(frame) for frame in frames]
    for source in sources:
        extracted = foundation(source, state)
        if not is_torch:
            mx.eval(extracted)
        features.append(extracted[:3])
        state = extracted[3]
    length = min(window, count)
    stride = max(1, window // 2)
    starts = sorted(set(range(0, count - length + 1, stride)) | {count - length})
    batons, weights, carry = {}, {}, {}
    cat = torch.cat if is_torch else mx.concatenate
    stack = torch.stack if is_torch else mx.stack
    for window_index, start in enumerate(starts):
        indices = list(range(start, start + length))
        padded = indices + [indices[-1]] * (window - length)
        sequence, quality = [], []
        for index in padded:
            if index in carry:
                sequence.append(cat([sources[index][..., :3], array(carry[index][None])], -1))
                quality.append(.95)
            else:
                sequence.append(sources[index])
                quality.append(.75)
        prediction = temporal(cat(sequence, 0), array(np.array([quality], np.float32)),
                              stack([features[index][0] for index in padded], 1),
                              stack([features[index][1] for index in padded], 1),
                              stack([features[index][2] for index in padded], 1))
        if not is_torch:
            mx.eval(prediction)
        baton, hint = [numpy(value) for value in prediction]
        taper = np.ones(length, np.float32)
        overlap = window - stride
        ramp = (1 - np.cos((np.arange(min(length, overlap)) + 1) * math.pi / (overlap + 1))) / 2
        if length > 1:
            if window_index > 0:
                taper[:len(ramp)] = ramp
            if window_index + 1 < len(starts):
                taper[-len(ramp):] = ramp[::-1]
        for offset, index in enumerate(indices):
            batons[index] = batons.get(index, 0) + baton[0, offset] * taper[offset]
            weights[index] = weights.get(index, 0) + taper[offset]
            carry[index] = hint[offset].copy()
    results = []
    for index in range(count):
        baton = (batons[index] / weights[index]).astype(np.float16).astype(np.float32)[None, None]
        output = refinement(sources[index], array(baton), array(np.empty(0, np.float32)))
        if not is_torch:
            mx.eval(output)
        results.append([numpy(value).copy() for value in output])
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--real-clips", action="store_true", help="Compare all four frames of the supplied green/blue benchmark clips")
    args = parser.parse_args()
    torch.set_num_threads(6)
    model = load_reference(Path("LLM Resources/CorridorKey2.0"), Path("LLM Resources/CorridorKey2.0 Hugging Face Files")).requires_grad_(False)
    prepare_for_export(model)
    from corridorkey.runtime import configure_low_vram_inference, InferenceConfig
    configure_low_vram_inference(model, InferenceConfig())
    foundation, temporal, refinement = FoundationReference(model).eval(), TemporalStageReference(model).eval(), RefinementReference(model).eval()
    imported = mx.import_function(str(args.model))
    cases = [(512, 2, 3, "green"), (512, 4, 4, "blue"), (1024, 2, 2, "green"),
             (1536, 1, 1, "blue"), (2048, 1, 1, "green")]
    if args.real_clips:
        cases = [(512, 4, 4, "green"), (512, 4, 4, "blue")]
    records = []
    with torch.no_grad():
        for size, window, count, screen in cases:
            started = time.monotonic()
            base = validation_source(size, screen)
            frames = [np.roll(base, index * 7, axis=2).copy() for index in range(count)]
            if args.real_clips:
                clip = ("LLM Resources/Benchmark/NikoDruid/Niko - 4 frames.mov" if screen == "green"
                        else "LLM Resources/Benchmark/Blue Screen/Blue Screen - 4 Frames.mov")
                reader = cv2.VideoCapture(clip)
                frames = []
                try:
                    for _ in range(count):
                        success, frame = reader.read()
                        if not success:
                            raise ValueError(f"Cannot read all frames: {clip}")
                        rgb = cv2.cvtColor(cv2.resize(frame, (size, size)), cv2.COLOR_BGR2RGB).astype(np.float32) / 255
                        rgb = np.where(rgb <= .04045, rgb / 12.92, ((rgb + .055) / 1.055)**2.4)
                        dominant = 1 if screen == "green" else 2
                        others = [channel for channel in range(3) if channel != dominant]
                        hint = 1 - np.clip(np.maximum(rgb[..., dominant] - rgb[..., others].max(-1), 0) * 2, 0, 1)
                        frames.append(np.concatenate([rgb, hint[..., None]], -1)[None])
                finally:
                    reader.release()
            expected = run(frames, window, foundation, temporal, refinement, "torch")
            actual = run(frames, window, imported, imported, imported, "mlx")
            metrics = [parity_metrics(reference, result) for reference, result in zip(expected, actual, strict=True)]
            records.append(dict(resolution=size, window=window, frames=count, screen=screen,
                                metrics=metrics, seconds=time.monotonic() - started))
            print(json.dumps(records[-1]), flush=True)
            args.report.write_text(json.dumps(dict(passed=records), indent=2) + "\n")
            if args.fixture and size == 512 and window == 2:
                args.fixture.mkdir(parents=True, exist_ok=True)
                for index, (frame, result) in enumerate(zip(frames, expected, strict=True)):
                    ((frame - np.array([.485, .456, .406, 0], np.float32)) / np.array([.229, .224, .225, 1], np.float32)).tofile(args.fixture / f"input-{index}.f32")
                    result[0].tofile(args.fixture / f"alpha-{index}.f32")
                    result[1].tofile(args.fixture / f"foreground-{index}.f32")
            del frames, expected, actual
            gc.collect()
            mx.clear_cache()


if __name__ == "__main__":
    main()

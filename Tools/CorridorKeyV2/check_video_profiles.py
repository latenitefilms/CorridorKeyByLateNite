"""Execute the longer exported temporal profiles and record finite-output/memory checks.

This is a dispatch and working-set smoke test, not a substitute for PyTorch
quality parity. Numerical reference comparisons live in validate_video.py.
"""
import argparse
import json
from pathlib import Path
import time

import mlx.core as mx
import numpy as np

from export import validation_source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--windows", type=int, nargs="+", default=[8, 24, 48, 80])
    args = parser.parse_args()
    mx.set_cache_limit(1 << 30)
    model = mx.import_function(str(args.model))
    source = mx.array(validation_source(512, "green"))
    source = mx.concatenate([source[..., :3], mx.zeros((1, 512, 512, 1))], axis=-1)
    radio, moge, rvm, _ = model(source, mx.zeros((1, 65, 384)))
    mx.eval(radio, moge, rvm)
    records = []
    for window in args.windows:
        mx.clear_cache()
        mx.reset_peak_memory()
        started = time.monotonic()
        baton, auxiliary = model(mx.repeat(source, window, axis=0), -mx.ones((1, window)),
            mx.repeat(mx.expand_dims(radio, 1), window, axis=1),
            mx.repeat(mx.expand_dims(moge, 1), window, axis=1),
            mx.repeat(mx.expand_dims(rvm, 1), window, axis=1))
        mx.eval(baton, auxiliary)
        assert baton.shape == (1, window, 512, 32, 32)
        assert auxiliary.shape == (window, 512, 512, 1)
        assert bool(mx.all(mx.isfinite(baton)).item())
        assert bool(mx.all(mx.isfinite(auxiliary)).item())
        for index in (0, window - 1):
            alpha, foreground = model(source, baton[:, index:index+1].astype(mx.float16).astype(mx.float32), mx.zeros((0,)))
            mx.eval(alpha, foreground)
            assert bool(mx.all(mx.isfinite(alpha)).item()) and bool(mx.all(mx.isfinite(foreground)).item())
            assert float(mx.min(alpha).item()) >= 0 and float(mx.max(alpha).item()) <= 1
        records.append(dict(resolution=512, window=window, seconds=time.monotonic() - started,
                            peak_mlx_bytes=mx.get_peak_memory(), finite=True))
        print(json.dumps(records[-1]), flush=True)
        args.report.write_text(json.dumps(dict(profiles=records), indent=2) + "\n")
        del baton, auxiliary, alpha, foreground


if __name__ == "__main__":
    main()

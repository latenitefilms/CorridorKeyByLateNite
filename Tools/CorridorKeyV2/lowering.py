"""Strict offline lowering of functional ATen inference graphs to MLX.

Unsupported operators fail conversion. There is no PyTorch/CPU fallback in
the exported function, and model weights are shared between shape variants.
"""

from functools import lru_cache
import math
import operator

import mlx.core as mx
import numpy as np
import torch
from torch.fx.node import map_arg


def mlx_dtype(dtype):
    """Map reference dtypes without silently reducing floating precision."""
    return {
        torch.float32: mx.float32, torch.float16: mx.float16,
        torch.bfloat16: mx.bfloat16, torch.float64: mx.float32,
        torch.int64: mx.int32, torch.int32: mx.int32,
        torch.bool: mx.bool_, torch.uint8: mx.uint8,
    }[dtype]


def array_from_torch(value):
    """Copy a reference tensor once, outside the application's render path."""
    value = value.detach().cpu()
    if value.dtype == torch.int64:
        if value.numel() and (value.min() < -(2**31) or value.max() >= 2**31):
            raise ValueError("Index cannot be represented as a Metal int32")
        value = value.to(torch.int32)
    dtype = mlx_dtype(value.dtype)
    if value.dtype in (torch.bfloat16, torch.float64):
        value = value.float()
    return mx.array(value.numpy(), dtype=dtype)


def pad_tensor(source, padding, mode="constant", value=0):
    """Implement PyTorch's reversed-axis padding, including negative crops."""
    widths = [(0, 0)] * source.ndim
    for index in range(len(padding) // 2):
        widths[-1-index] = tuple(padding[2*index:2*index+2])
    slices = tuple(slice(max(-left, 0), size - max(-right, 0))
                   for size, (left, right) in zip(source.shape, widths))
    source = source[slices]
    widths = [(max(left, 0), max(right, 0)) for left, right in widths]
    if mode == "constant":
        return mx.pad(source, widths, constant_values=0 if value is None else value)
    for axis, (left, right) in enumerate(widths):
        if not left and not right:
            continue
        size = source.shape[axis]
        positions = np.arange(-left, size + right)
        if mode == "replicate":
            positions = np.clip(positions, 0, size - 1)
        elif mode == "reflect":
            if size < 2 or left >= size or right >= size:
                raise ValueError("Invalid reflection padding")
            positions = np.where(positions < 0, -positions, positions)
            positions = np.where(positions >= size, 2 * size - positions - 2, positions)
        else:
            raise NotImplementedError(f"Padding mode {mode}")
        source = mx.take(source, mx.array(positions, dtype=mx.int32), axis=axis)
    return source


@lru_cache(maxsize=128)
def resize_coefficients(input_size, output_size, mode, align_corners, antialias, scale=None):
    """Freeze PyTorch's exact separable resampling coefficients at export."""
    basis = torch.eye(input_size).reshape(input_size, 1, 1, input_size)
    sizing = {"size": (1, output_size)} if scale is None else {"scale_factor": (1, scale)}
    resized = torch.nn.functional.interpolate(
        basis, **sizing, mode=mode,
        align_corners=align_corners, antialias=antialias,
    )[:, 0, 0].T.numpy()
    # Store only contributing taps; dense resampling matrices waste GPU work.
    nonzero = [np.flatnonzero(row) for row in resized]
    taps = max(len(indices) for indices in nonzero)
    indices = np.zeros((output_size, taps), dtype=np.int32)
    weights = np.zeros((output_size, taps), dtype=np.float32)
    for row, positions in enumerate(nonzero):
        indices[row, :len(positions)] = positions
        weights[row, :len(positions)] = resized[row, positions]
    return mx.array(indices), mx.array(weights)


def resize_tensor(source, output_size, mode, align_corners=False, antialias=False, scales=None):
    """Resample NCHW tensors with precomputed separable filter taps."""
    for axis, size in ((3, output_size[1]), (2, output_size[0])):
        scale = None if scales is None else scales[axis - 2]
        if source.shape[axis] == size and (scale is None or scale == 1):
            continue
        indices, weights = resize_coefficients(source.shape[axis], size, mode, align_corners, antialias, scale)
        gathered = mx.take(source, indices, axis=axis)
        weight_shape = [1] * gathered.ndim
        weight_shape[axis:axis+2] = weights.shape
        source = mx.sum(gathered * weights.astype(source.dtype).reshape(weight_shape), axis=axis+1)
    return source


def adaptive_average(source, output_size):
    """Exact adaptive area pooling, including nonintegral scale factors."""
    for axis, size in ((3, output_size[1]), (2, output_size[0])):
        input_size = source.shape[axis]
        starts = [index * input_size // size for index in range(size)]
        ends = [math.ceil((index + 1) * input_size / size) for index in range(size)]
        taps = max(end - start for start, end in zip(starts, ends))
        indices = np.zeros((size, taps), dtype=np.int32)
        weights = np.zeros((size, taps), dtype=np.float32)
        for row, (start, end) in enumerate(zip(starts, ends)):
            indices[row, :end-start] = np.arange(start, end)
            weights[row, :end-start] = 1 / (end-start)
        gathered = mx.take(source, mx.array(indices), axis=axis)
        shape = [1] * gathered.ndim
        shape[axis:axis+2] = [size, taps]
        source = mx.sum(gathered * mx.array(weights, dtype=source.dtype).reshape(shape), axis=axis+1)
    return source


def lower_operator(target, arguments, keywords):
    """Lower one functional operator, rejecting unimplemented semantics."""
    if target is operator.getitem:
        return arguments[0][arguments[1]]
    operation = target._schema.name.split("::")[-1]
    bound = {parameter.name: parameter.default_value for parameter in target._schema.arguments
             if parameter.has_default_value()}
    bound.update(zip((parameter.name for parameter in target._schema.arguments), arguments))
    bound.update(keywords)
    source = bound.get("self", bound.get("input"))
    unary = {
        "neg": mx.negative, "abs": mx.abs, "rsqrt": mx.rsqrt, "sqrt": mx.sqrt,
        "sin": mx.sin, "cos": mx.cos, "sinh": mx.sinh, "asinh": mx.arcsinh,
        "sigmoid": mx.sigmoid, "tanh": mx.tanh, "exp": mx.exp,
        "floor": mx.floor, "ceil": mx.ceil, "logical_not": mx.logical_not,
    }
    if operation in unary:
        return unary[operation](source)
    binary = {
        "mul": operator.mul, "div": operator.truediv, "pow": operator.pow,
        "eq": operator.eq, "ne": operator.ne, "ge": operator.ge,
        "gt": operator.gt, "le": operator.le, "lt": operator.lt,
        "maximum": mx.maximum, "minimum": mx.minimum,
    }
    if operation in binary:
        if bound.get("rounding_mode") is not None:
            raise NotImplementedError("Rounded division")
        return binary[operation](arguments[0], arguments[1])
    if operation in ("add", "sub"):
        other = bound["other"] * bound.get("alpha", 1)
        return source + other if operation == "add" else source - other
    if operation == "rsub":
        return bound["other"] - source * bound["alpha"]
    if operation == "_assert_tensor_metadata":
        if bound.get("size") is not None and tuple(bound["size"]) != source.shape:
            raise ValueError("Tensor metadata shape mismatch")
        return None
    if operation in ("clone", "detach", "alias", "contiguous", "lift_fresh_copy"):
        return source
    if operation == "copy":
        return mx.broadcast_to(bound["src"].astype(source.dtype), source.shape)
    if operation in ("to", "_to_copy"):
        return source.astype(mlx_dtype(bound["dtype"])) if bound.get("dtype") else source
    if operation in ("view", "reshape", "_unsafe_view"):
        return source.reshape(bound.get("shape", bound.get("size")))
    if operation == "permute":
        return source.transpose(bound["dims"])
    if operation == "transpose":
        return mx.swapaxes(source, bound["dim0"], bound["dim1"])
    if operation == "t":
        return source.T
    if operation == "unsqueeze":
        return mx.expand_dims(source, bound["dim"])
    if operation == "squeeze":
        return mx.squeeze(source, axis=bound.get("dim"))
    if operation == "expand":
        shape = [old if new == -1 else new for old, new in zip(
            [1] * (len(bound["size"]) - source.ndim) + list(source.shape), bound["size"])]
        return mx.broadcast_to(source, shape)
    if operation in ("cat", "stack"):
        return (mx.concatenate if operation == "cat" else mx.stack)(bound["tensors"], axis=bound["dim"])
    if operation == "unbind":
        return [mx.take(source, index, axis=bound["dim"]) for index in range(source.shape[bound["dim"]])]
    if operation == "split":
        size = bound["split_size"]
        return mx.split(source, list(range(size, source.shape[bound["dim"]], size)), axis=bound["dim"])
    if operation in ("slice", "select", "slice_scatter", "select_scatter"):
        slices = [slice(None)] * source.ndim
        size = source.shape[bound["dim"]]
        start = bound.get("start")
        end = bound.get("end")
        start = None if start is None else max(-size, min(start, size))
        end = None if end is None else max(-size, min(end, size))
        slices[bound["dim"]] = bound["index"] if "index" in bound else slice(
            start, end, bound.get("step", 1))
        if operation.endswith("scatter"):
            result = mx.array(source)
            result[tuple(slices)] = bound["src"]
            return result
        return source[tuple(slices)]
    if operation == "index_select":
        return mx.take(source, bound["index"], axis=bound["dim"])
    if operation == "index":
        return source[tuple(slice(None) if index is None else index for index in bound["indices"])]
    if operation in ("index_put", "_unsafe_index_put"):
        indices = tuple(slice(None) if index is None else index for index in bound["indices"])
        if bound.get("accumulate", False):
            return source.at[indices].add(bound["values"])
        result = mx.array(source)
        result[indices] = bound["values"]
        return result
    if operation == "index_copy":
        indices = [slice(None)] * source.ndim
        indices[bound["dim"]] = bound["index"]
        result = mx.array(source)
        result[tuple(indices)] = bound["source"]
        return result
    if operation in ("zeros", "ones", "empty", "full", "new_zeros", "new_empty", "new_full"):
        return mx.full(bound["size"], bound.get("fill_value", 1 if operation == "ones" else 0),
                       dtype=mlx_dtype(bound["dtype"]) if bound.get("dtype") else (source.dtype if source is not None else mx.float32))
    if operation in ("zeros_like", "ones_like", "empty_like", "full_like"):
        return mx.full(source.shape, bound.get("fill_value", 1 if operation == "ones_like" else 0),
                       dtype=mlx_dtype(bound["dtype"]) if bound.get("dtype") else source.dtype)
    if operation == "arange":
        return mx.arange(bound.get("start", 0), bound["end"], bound.get("step", 1),
                         dtype=mlx_dtype(bound["dtype"]) if bound.get("dtype") else mx.int32)
    if operation == "clamp":
        return mx.clip(source, bound["min"], bound["max"])
    if operation == "where":
        return mx.where(bound["condition"], bound["self"], bound["other"])
    if operation in ("mean", "sum", "amax"):
        return {"mean": mx.mean, "sum": mx.sum, "amax": mx.max}[operation](
            source, axis=bound.get("dim"), keepdims=bound.get("keepdim", False))
    if operation == "silu":
        return source * mx.sigmoid(source)
    if operation == "gelu":
        if bound["approximate"] == "tanh":
            return 0.5 * source * (1 + mx.tanh(math.sqrt(2 / math.pi) * (source + 0.044715 * source**3)))
        return 0.5 * source * (1 + mx.erf(source / math.sqrt(2)))
    if operation in ("matmul", "bmm", "mm"):
        return arguments[0] @ arguments[1]
    if operation == "linear":
        result = source @ bound["weight"].T
        return result if bound["bias"] is None else result + bound["bias"]
    if operation in ("layer_norm", "native_layer_norm"):
        dimensions = list(range(source.ndim - len(bound["normalized_shape"]), source.ndim))
        mean = mx.mean(source, axis=dimensions, keepdims=True)
        centered = source - mean
        inverse_std = mx.rsqrt(mx.mean(centered * centered, axis=dimensions, keepdims=True) + bound["eps"])
        result = centered * inverse_std
        if bound["weight"] is not None:
            result = result * bound["weight"]
        if bound["bias"] is not None:
            result = result + bound["bias"]
        return (result, mean, inverse_std) if operation == "native_layer_norm" else result
    if operation == "rms_norm":
        dimensions = list(range(source.ndim - len(bound["normalized_shape"]), source.ndim))
        epsilon = bound["eps"] if bound["eps"] is not None else mx.finfo(source.dtype).eps
        result = source * mx.rsqrt(mx.mean(source * source, axis=dimensions, keepdims=True) + epsilon)
        return result if bound["weight"] is None else result * bound["weight"]
    if operation == "scaled_dot_product_attention":
        if bound["dropout_p"] or bound["is_causal"] or bound.get("enable_gqa"):
            raise NotImplementedError("Only noncausal inference attention is supported")
        return mx.fast.scaled_dot_product_attention(bound["query"], bound["key"], bound["value"],
            scale=bound.get("scale") or bound["query"].shape[-1]**-0.5, mask=bound["attn_mask"])
    if operation in ("softmax", "_softmax"):
        return mx.softmax(source, axis=bound["dim"])
    if operation in ("pad", "constant_pad_nd", "reflection_pad2d", "replication_pad2d"):
        mode = bound.get("mode", {"reflection_pad2d": "reflect", "replication_pad2d": "replicate"}.get(operation, "constant"))
        return pad_tensor(source, bound.get("pad", bound.get("padding")), mode, bound.get("value", 0))
    if operation in ("conv2d", "convolution", "conv_transpose2d"):
        transposed = operation == "conv_transpose2d" or bound.get("transposed", False)
        weight = bound["weight"].transpose(1, 2, 3, 0) if transposed else bound["weight"].transpose(0, 2, 3, 1)
        function = mx.conv_transpose2d if transposed else mx.conv2d
        options = dict(stride=tuple(bound["stride"]), padding=tuple(bound["padding"]),
                       dilation=tuple(bound["dilation"]), groups=bound["groups"])
        if transposed:
            options["output_padding"] = tuple(bound["output_padding"])
        result = function(source.transpose(0, 2, 3, 1), weight, **options)
        if bound["bias"] is not None:
            result = result + bound["bias"]
        return result.transpose(0, 3, 1, 2)
    if operation == "adaptive_avg_pool2d":
        return adaptive_average(source, bound["output_size"])
    if "upsample_bicubic2d" in operation or "upsample_bilinear2d" in operation:
        mode = "bicubic" if "bicubic" in operation else "bilinear"
        output_size = bound.get("output_size")
        if output_size is None:
            output_size = [int(size * scale) for size, scale in zip(source.shape[-2:], bound["scale_factors"])]
        return resize_tensor(source, output_size, mode, bound["align_corners"], operation.endswith("_aa"), bound.get("scale_factors"))
    if operation == "pixel_shuffle":
        batch, channels, height, width = source.shape
        factor = bound["upscale_factor"]
        return source.reshape(batch, channels // factor**2, factor, factor, height, width).transpose(
            0, 1, 4, 2, 5, 3).reshape(batch, channels // factor**2, height * factor, width * factor)
    if operation == "roll":
        return mx.roll(source, bound["shifts"], axis=bound["dims"])
    raise NotImplementedError(f"Unsupported export operator: {target}")


class LoweredGraph:
    """An export-time callable whose only runtime operations are MLX primitives."""

    def __init__(self, exported, shared_weights=None, weight_precision="float32"):
        self.graph = exported.graph
        self.constants = {}
        self.constant_dtypes = {}
        self.inputs = []
        self.output_names = [spec.arg.name for spec in exported.graph_signature.output_specs
                             if spec.kind.name == "USER_OUTPUT"]
        if len(self.output_names) != len(exported.graph_signature.output_specs):
            raise ValueError("Exported graph mutates persistent state")
        shared_weights = {} if shared_weights is None else shared_weights
        for spec in exported.graph_signature.input_specs:
            if spec.kind.name == "USER_INPUT":
                self.inputs.append(spec.arg.name)
                continue
            value = exported.state_dict.get(spec.target, exported.constants.get(spec.target))
            if not isinstance(value, torch.Tensor):
                raise TypeError(f"Non-tensor graph constant {spec.target}")
            # Lifted positional/region tensors depend on the traced shape.
            # Only actual parameters and buffers may share storage across traces.
            key = spec.target if spec.kind.name in ("PARAMETER", "BUFFER") else object()
            if key not in shared_weights:
                array = array_from_torch(value)
                if spec.kind.name == "PARAMETER" and weight_precision == "float16" and value.is_floating_point():
                    array = array.astype(mx.float16)
                    mx.eval(array)
                shared_weights[key] = array
            self.constants[spec.arg.name] = shared_weights[key]
            self.constant_dtypes[spec.arg.name] = mlx_dtype(value.dtype)

    def __call__(self, *inputs):
        if len(inputs) != len(self.inputs):
            raise ValueError("Incorrect number of graph inputs")
        # Cast from compact storage inside each invocation. Retaining/evaluating
        # the cast in self.constants would serialize full-size float32 weights.
        values = {name: value.astype(self.constant_dtypes[name]) for name, value in self.constants.items()}
        values.update(zip(self.inputs, inputs))
        for node in self.graph.nodes:
            if node.op == "placeholder":
                continue
            if node.op == "output":
                return tuple(values[name] for name in self.output_names)
            if node.op != "call_function":
                raise NotImplementedError(f"Unsupported graph node {node.op}")
            arguments = map_arg(node.args, lambda argument: values[argument.name])
            keywords = map_arg(node.kwargs, lambda argument: values[argument.name])
            try:
                values[node.name] = lower_operator(node.target, arguments, keywords)
            except Exception as error:
                raise RuntimeError(f"Cannot lower {node.name}: {node.target}") from error
        raise ValueError("Graph has no output")

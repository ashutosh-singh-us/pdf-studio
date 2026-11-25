"""Quantizes Dia's DenseGeneral layers (mlx.nn.quantize skips them: they aren't nn.Linear).

Each DenseGeneral contracts some input axes with a weight of shape in_shapes + out_features.
We flatten that to a 2-D (out, in) matrix, quantize it, and use quantized_matmul.
"""
import math

import mlx.core as mx
import mlx.nn as nn
from mlx.utils import tree_unflatten
from mlx_audio.tts.models.dia.layers import DenseGeneral


def _norm(axes, ndim):
    return tuple(a % ndim for a in axes)


class QuantizedDense(nn.Module):
    def __init__(self, dense: DenseGeneral, bits: int, group_size: int):
        super().__init__()
        self._in = tuple(dense.in_shapes)
        self._out = tuple(dense.out_features)
        self._axis = tuple(dense.axis)
        self._bits, self._group = bits, group_size
        n_in, n_out = math.prod(self._in), math.prod(self._out)
        w = dense.weight.astype(mx.bfloat16).reshape(n_in, n_out).T
        self.weight, self.scales, self.biases = mx.quantize(w, group_size=group_size, bits=bits)

    def __call__(self, x: mx.array) -> mx.array:
        axes = _norm(self._axis, x.ndim)
        keep = [i for i in range(x.ndim) if i not in axes]
        if keep + list(axes) != list(range(x.ndim)):
            x = mx.transpose(x, keep + list(axes))
        lead = x.shape[: len(keep)]
        x = x.reshape(*lead, -1)
        y = mx.quantized_matmul(x, self.weight, self.scales, self.biases,
                                transpose=True, group_size=self._group, bits=self._bits)
        return y.reshape(*lead, *self._out)


def quantize_dia(module: nn.Module, bits: int = 4, group_size: int = 64) -> int:
    """Replaces DenseGeneral layers in place. Returns how many were quantized."""
    replace = []
    for name, m in module.named_modules():
        if isinstance(m, DenseGeneral) and math.prod(m.in_shapes) % group_size == 0:
            replace.append((name, QuantizedDense(m, bits, group_size)))
    module.update_modules(tree_unflatten(replace))
    return len(replace)

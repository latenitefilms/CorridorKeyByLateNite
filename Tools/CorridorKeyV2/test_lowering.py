"""Numerical tests against PyTorch, run on a real Apple Silicon Metal device."""

import unittest

import mlx.core as mx
import numpy as np
import torch
import torch.nn.functional as functional

from lowering import LoweredGraph, adaptive_average, array_from_torch, pad_tensor, resize_tensor
from color import display_to_linear, linear_to_display


class LoweringTests(unittest.TestCase):
    """Exercise operators whose layout or numerical differences affect mattes."""

    def setUp(self):
        torch.manual_seed(42)

    def assertParity(self, expected, actual, tolerance=2e-5):
        mx.eval(actual)
        np.testing.assert_allclose(np.asarray(actual), expected.detach().numpy(), atol=tolerance, rtol=tolerance)

    def exportParity(self, model, inputs, tolerance=2e-5):
        model.eval()
        with torch.no_grad():
            expected = model(*inputs)
            graph = torch.export.export(model, inputs, strict=False).run_decompositions({})
        actual = LoweredGraph(graph)(*(array_from_torch(value) for value in inputs))
        if not isinstance(expected, tuple):
            expected = (expected,)
        self.assertEqual(len(expected), len(actual))
        for reference, result in zip(expected, actual):
            self.assertParity(reference, result, tolerance)

    def testConvolution(self):
        for groups in (1, 4):
            with self.subTest(groups=groups):
                self.exportParity(torch.nn.Conv2d(4, 8, 3, stride=2, padding=1, groups=groups),
                                  (torch.randn(2, 4, 16, 20),))

    def testTransposedConvolution(self):
        self.exportParity(torch.nn.ConvTranspose2d(5, 4, 8, stride=4, padding=2),
                          (torch.randn(1, 5, 4, 6),))

    def testLayerNormAndGELU(self):
        for approximation in ("none", "tanh"):
            self.exportParity(torch.nn.Sequential(torch.nn.LayerNorm(16), torch.nn.Linear(16, 20),
                                                  torch.nn.GELU(approximate=approximation)),
                              (torch.randn(2, 7, 16),))

    def testPadding(self):
        source = torch.randn(2, 3, 8, 11)
        for mode in ("constant", "reflect", "replicate"):
            for padding in ((2, 3, 1, 2), (-1, 2, 1, -2)):
                with self.subTest(mode=mode, padding=padding):
                    self.assertParity(functional.pad(source, padding, mode),
                                      pad_tensor(array_from_torch(source), padding, mode))

    def testAreaPooling(self):
        for input_size, output_size in (((32, 48), (8, 12)), ((32, 48), (7, 10))):
            source = torch.randn(1, 3, *input_size)
            self.assertParity(functional.adaptive_avg_pool2d(source, output_size),
                              adaptive_average(array_from_torch(source), output_size))

    def testResize(self):
        for mode in ("bilinear", "bicubic"):
            for antialias in (False, True):
                for align_corners in (False, True):
                    for size in ((7, 11), (23, 29)):
                        with self.subTest(mode=mode, antialias=antialias, align=align_corners, size=size):
                            source = torch.randn(1, 4, 16, 20)
                            expected = functional.interpolate(source, size, mode=mode,
                                align_corners=align_corners, antialias=antialias)
                            actual = resize_tensor(array_from_torch(source), size, mode, align_corners, antialias)
                            self.assertParity(expected, actual)

    def testAttention(self):
        class Attention(torch.nn.Module):
            def forward(self, query, key, value, mask):
                return functional.scaled_dot_product_attention(query, key, value, attn_mask=mask)
        self.exportParity(Attention(), (torch.randn(2, 4, 13, 16), torch.randn(2, 4, 13, 16),
                                       torch.randn(2, 4, 13, 16), torch.rand(2, 1, 13, 13) > 0.2))

    def testDINOPositionResize(self):
        source = torch.randn(1, 8, 37, 37)
        scales = ((8 + 0.1) / 37, (12 + 0.1) / 37)
        self.assertParity(functional.interpolate(source, scale_factor=scales, mode="bicubic", align_corners=False),
                          resize_tensor(array_from_torch(source), (8, 12), "bicubic", scales=scales))

    def testFunctionalMutation(self):
        class Update(torch.nn.Module):
            def forward(self, source, update):
                result = source.clone()
                view = result.permute(0, 2, 1)
                view[:, 1:3, :] = update
                return result
        self.exportParity(Update(), (torch.randn(2, 4, 6), torch.randn(2, 2, 4)))

    def testSignedColorRoundTrip(self):
        values = np.array([-16, -1, -0.04, 0, 0.003, 0.04, 0.5, 1, 4, 16], dtype=np.float32)
        for operations, source in ((np, values), (mx, mx.array(values))):
            result = linear_to_display(display_to_linear(source, operations), operations)
            np.testing.assert_allclose(np.asarray(result), values, atol=2e-6, rtol=2e-6)
        np.testing.assert_allclose(display_to_linear(np.array([0, 0.04045, 0.5, 1]), np),
                                   [0, 0.00313080495, 0.21404114048, 1], atol=1e-8)

    def testShapeDependentConstantsRemainIndependent(self):
        class Coordinates(torch.nn.Module):
            def forward(self, source):
                return source + torch.tensor(list(range(source.shape[0])), dtype=torch.float32)
        shared = {}
        graphs = []
        for size in (4, 8):
            exported = torch.export.export(Coordinates(), (torch.zeros(size),), strict=False).run_decompositions({})
            graphs.append(LoweredGraph(exported, shared))
        for size, graph in zip((4, 8), graphs):
            np.testing.assert_array_equal(np.asarray(graph(mx.zeros(size))[0]), np.arange(size))


if __name__ == "__main__":
    unittest.main()

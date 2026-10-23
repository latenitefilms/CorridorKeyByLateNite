"""Load the unmodified upstream v2 reference for offline conversion and parity.

The application never imports or executes this module. All model assets must
already exist locally; loading does not download or execute remote HF code.
"""

from pathlib import Path
import json
import sys

# C-RADIO imports distutils.version; Python 3.12 provides it via setuptools.
import setuptools  # noqa: F401
import torch
from safetensors import safe_open
from safetensors.torch import load_file


def load_reference(repository: Path, weights_directory: Path):
    """Build v2 from checkpoint metadata, validating every trained parameter."""
    repository = repository.resolve()
    weights_directory = weights_directory.resolve()
    sys.path.insert(0, str(repository))
    sys.path.insert(0, str(repository / "third_party/MoGe"))
    from corridorkey.model import CorridorKeyV3

    weights = weights_directory / "corridorkey_v2.safetensors"
    with safe_open(weights, framework="pt") as checkpoint:
        metadata = checkpoint.metadata()
    if metadata.get("format") != "corridorkey_v2_runtime_checkpoint":
        raise ValueError("Expected a CorridorKey v2 runtime checkpoint")
    config = json.loads(metadata["model_config"])
    contract = json.loads(metadata["metadata"])
    if contract["shape_quantum"] != 128 or config["stage1_recurrent_64_sites"]:
        raise ValueError("Unsupported CorridorKey v2 architecture revision")
    assets = {
        "cradio_repo": repository / "vfms/cradio/C-RADIOv4-SO400M",
        "moge_checkpoint": repository / "vfms/moge/model.pt",
        "rvm_ckpt": repository / "vfms/rvm/pretrain_rvm_small16_256_204031069.npz",
        "foundation_stats_path": weights_directory / "foundation_stats.safetensors",
    }
    for name, path in assets.items():
        if not path.exists():
            raise FileNotFoundError(f"Missing {name}: {path}")
        config[name] = str(path)
    config.update(device="cpu", gradient_checkpoint=False)
    model = CorridorKeyV3(**config).eval()
    missing, unexpected = model.load_state_dict(load_file(weights), strict=False)
    missing = [name for name in missing if not name.startswith("foundations.")]
    if missing or unexpected:
        raise ValueError(f"Checkpoint mismatch: missing={missing}, unexpected={unexpected}")
    return model


def prepare_for_export(model):
    """Remove Hugging Face's argument-incompatible forwarding shell.

    The official wrapper rejects feature_fmt and upstream catches TypeError
    before retrying. That exception disrupts torch.export's module stack.
    Its inner module runs the identical learned operations and directly
    supports the requested NCHW layout.
    """
    model.foundations.cradio = model.foundations.cradio.radio_model


class SingleFrameReference(torch.nn.Module):
    """Deterministic v2 1/1 mode for randomly ordered NLE frame requests.

    Input is NHWC scene-linear RGB plus a matte hint. Output is NHWC alpha
    coverage and straight scene-linear foreground, both float32. All three
    foundation models participate; RVM starts fresh for each request so shared
    inference engines cannot leak a different clip's state into a frame.
    """

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, source):
        from corridorkey import color_utils
        rgb = source[..., :3].permute(0, 3, 1, 2).unsqueeze(1)
        hint = source[..., 3:4].permute(0, 3, 1, 2).unsqueeze(1).clamp(0, 1)
        height, width = source.shape[1:3]
        proxy = color_utils.linear_to_vfm_sdr_torch(rgb).flatten(0, 1)
        radio = torch.nn.functional.interpolate(proxy, (height // 4, width // 4), mode="area")
        moge = torch.nn.functional.interpolate(proxy, (height * 7 // 32, width * 7 // 32), mode="area")
        # Existing guides are automated rough mattes, not authoritative roto.
        quality = torch.full((source.shape[0], 1), 0.75, device=source.device)
        prediction = self.model(
            color_utils.linear_to_asinh(rgb), hint,
            radio.unsqueeze(1), moge.unsqueeze(1), rgb_rvm=radio.unsqueeze(1),
            hint_quality=quality,
        )
        alpha = prediction["alpha"][:, 0].clamp(0, 1).permute(0, 2, 3, 1).float()
        foreground = color_utils.asinh_to_linear(prediction["fg"][:, 0]).permute(0, 2, 3, 1).float()
        return alpha, foreground

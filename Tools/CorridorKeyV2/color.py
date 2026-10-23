"""Signed IEC sRGB transfer functions used at the host/v2 model boundary.

Both current hosts supply video-gamma RGB. V2's keying stages require signed
asinh scene-linear RGB; its foundation models receive an SDR proxy internally.
These functions preserve negative and above-white values rather than clipping.
"""


def display_to_linear(value, operations):
    """Decode display RGB with the reference runtime's signed sRGB transfer."""
    magnitude = operations.abs(value)
    decoded = operations.where(magnitude <= 0.04045, magnitude / 12.92,
                               ((magnitude + 0.055) / 1.055)**2.4)
    return operations.where(value < 0, -decoded, decoded)


def linear_to_display(value, operations):
    """Encode linear predictions for the existing host compositing pipeline."""
    magnitude = operations.abs(value)
    encoded = operations.where(magnitude <= 0.0031308, magnitude * 12.92,
                               1.055 * operations.maximum(magnitude, 0.0031308)**(1 / 2.4) - 0.055)
    return operations.where(value < 0, -encoded, encoded)

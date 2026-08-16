"""
Conformance tests for the ISO/IEC 19794-4 Finger Image Record encoder.

Byte-level assertions against the layout in the standard, plus encode/decode round
trips. Runs with no model weights and no data.

The decoder is deliberately independent of the encoder's internals: it re-derives every
field from raw offsets, so a round trip is evidence rather than the encoder agreeing
with itself.
"""

import math
import os
import struct
import sys

import numpy as np
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fir import (  # noqa: E402
    FINGER_HEADER_LEN, FORMAT_IDENTIFIER, GENERAL_HEADER_LEN, TARGET_DPI, VERSION,
    FIRError, decode_fir, encode_fir, estimate_ridge_period, normalize_to_500dpi,
)


def ridge_image(period=10.0, size=256, angle=0.0):
    """A synthetic fingerprint-like pattern: parallel ridges at a known spacing."""
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    proj = xx * math.cos(angle) + yy * math.sin(angle)
    wave = np.sin(2 * math.pi * proj / period)
    return ((wave * 0.5 + 0.5) * 255).astype(np.uint8)


# ── Header layout ────────────────────────────────────────────────────────────

def test_format_identifier_and_version():
    rec = encode_fir(ridge_image(size=64))
    assert rec[0:4] == FORMAT_IDENTIFIER == b"FIR\x00"
    assert rec[4:8] == VERSION


def test_record_length_field_matches_actual_length():
    rec = encode_fir(ridge_image(size=64))
    assert struct.unpack(">I", rec[8:12])[0] == len(rec)


def test_total_size_is_headers_plus_pixels():
    img = ridge_image(size=64)
    rec = encode_fir(img)
    assert len(rec) == GENERAL_HEADER_LEN + FINGER_HEADER_LEN + img.size


def test_resolution_fields_declare_500_dpi():
    rec = encode_fir(ridge_image(size=64))
    assert rec[21] == 1                                        # scale units: pixels/inch
    for off in (22, 24, 26, 28):
        assert struct.unpack(">H", rec[off:off + 2])[0] == TARGET_DPI


def test_pixel_depth_and_compression_fields():
    rec = encode_fir(ridge_image(size=64))
    assert rec[30] == 8                                        # 8-bit grayscale
    assert rec[31] == 0                                        # uncompressed


def test_multibyte_fields_are_big_endian():
    """The standard is big-endian throughout; little-endian would silently corrupt."""
    rec = encode_fir(ridge_image(size=64), capture_device_id=0x1234)
    assert rec[16] == 0x12 and rec[17] == 0x34


# ── Round trip ───────────────────────────────────────────────────────────────

def test_round_trip_preserves_pixels_exactly():
    img = ridge_image(size=128)
    out = decode_fir(encode_fir(img))
    assert np.array_equal(out["image"], img)


@pytest.mark.parametrize("position", range(11))
def test_round_trip_preserves_every_finger_position(position):
    out = decode_fir(encode_fir(ridge_image(size=64), finger_position=position))
    assert out["finger"]["finger_position"] == position


def test_round_trip_preserves_metadata():
    rec = encode_fir(ridge_image(size=64), finger_position=7, image_quality=82,
                     impression_type=0, capture_device_id=9, view_number=1,
                     count_of_views=2)
    out = decode_fir(rec)
    assert out["finger"]["image_quality"] == 82
    assert out["finger"]["view_number"] == 1
    assert out["finger"]["count_of_views"] == 2
    assert out["header"]["capture_device_id"] == 9


def test_non_square_dimensions_are_not_transposed():
    """Width and height are separate fields and are easy to swap."""
    img = ridge_image(size=96)[:60, :96]                       # 60 tall, 96 wide
    out = decode_fir(encode_fir(img))
    assert out["finger"]["width"] == 96
    assert out["finger"]["height"] == 60
    assert out["image"].shape == (60, 96)


def test_colour_input_is_converted_to_grayscale():
    colour = np.dstack([ridge_image(size=64)] * 3)
    out = decode_fir(encode_fir(colour))
    assert out["image"].ndim == 2


# ── Rejection ────────────────────────────────────────────────────────────────

def test_rejects_empty_image():
    with pytest.raises(FIRError):
        encode_fir(np.zeros((0, 0), dtype=np.uint8))


def test_rejects_out_of_range_finger_position():
    with pytest.raises(FIRError):
        encode_fir(ridge_image(size=64), finger_position=11)


def test_decoder_rejects_truncated_record():
    with pytest.raises(FIRError):
        decode_fir(encode_fir(ridge_image(size=64))[:20])


def test_decoder_rejects_corrupt_identifier():
    rec = bytearray(encode_fir(ridge_image(size=64)))
    rec[0:4] = b"FMR\x00"
    with pytest.raises(FIRError):
        decode_fir(bytes(rec))


def test_decoder_rejects_wrong_length_field():
    rec = bytearray(encode_fir(ridge_image(size=64)))
    rec[8:12] = struct.pack(">I", 999999)
    with pytest.raises(FIRError):
        decode_fir(bytes(rec))


# ── 500 dpi normalisation ────────────────────────────────────────────────────

@pytest.mark.parametrize("period", [6.0, 8.0, 10.0, 14.0, 20.0])
def test_ridge_period_estimate_is_accurate(period):
    measured = estimate_ridge_period(ridge_image(period=period, size=256))
    assert measured is not None
    assert abs(measured - period) / period < 0.15, (
        "estimated %.2f px for a true period of %.2f px" % (measured, period))


def test_ridge_period_estimate_survives_rotation():
    """Ridge flow is never conveniently axis-aligned."""
    measured = estimate_ridge_period(
        ridge_image(period=10.0, size=256, angle=math.pi / 5))
    assert measured is not None
    assert abs(measured - 10.0) / 10.0 < 0.20


def test_normalisation_drives_ridge_period_towards_target():
    """A 20 px-period image should come out near the 10 px the 500 dpi target implies."""
    out, info = normalize_to_500dpi(ridge_image(period=20.0, size=256))
    assert info["method"] == "ridge_frequency"
    assert abs(estimate_ridge_period(out) - 10.0) < 2.0


def test_blank_image_is_passed_through_not_guessed():
    """Resampling by a factor derived from noise would corrupt the record."""
    out, info = normalize_to_500dpi(np.full((128, 128), 127, dtype=np.uint8))
    assert info["method"] == "passthrough"
    assert info["scale_factor"] == 1.0
    assert out.shape == (128, 128)


def test_explicit_source_dpi_scales_exactly():
    out, info = normalize_to_500dpi(ridge_image(size=200), source_dpi=250)
    assert info["method"] == "source_dpi"
    assert info["scale_factor"] == pytest.approx(2.0)
    assert out.shape == (400, 400)


def test_normalised_image_still_encodes():
    """The two halves of FP-06 have to work together, not just separately."""
    out, _ = normalize_to_500dpi(ridge_image(period=16.0, size=256))
    decoded = decode_fir(encode_fir(out, finger_position=2))
    assert decoded["finger"]["finger_position"] == 2
    assert decoded["image"].shape == out.shape

"""
minutiae.py — MinutiaeNet model + minutiae extraction ("templatization").

Extracted from app.py so the cloud-only service (cloud_app.py) and the full
reference pipeline (app.py, slap_core.py) load exactly one copy of this model and
run exactly one implementation of detect_minutiae() — previously app.py and
slap_core.py each carried their own copy of this class, loading the same
best_f1.pth weights independently. Architecture, weights, and behavior here are
unchanged from app.py's version; this is a move, not a rewrite.

Per the on-device/cloud split, this is the CLOUD side: templatization is the one
stage that stays server-side (the model is ~5-20x larger than everything that
moves on-device, and its Hourglass+Attention architecture is a poor mobile-
conversion candidate). Nothing in this file talks to a request, a database, or
another service — it only turns a preprocessed image into a minutiae list.
"""

import os

import cv2
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from scipy.ndimage import maximum_filter

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
MINUTIAE_MODEL_PATH = os.environ.get(
    "MINUTIAE_MODEL_PATH", os.path.join(BASE_DIR, "best_f1.pth")
)
DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")

_model = None  # lazy-loaded singleton, see get_minutiae_model()


# ══════════════════════════════════════════════════════════════════════════════
# ARCHITECTURE — unchanged from app.py:201-323
# ══════════════════════════════════════════════════════════════════════════════

class ResBlock(nn.Module):
    def __init__(self, in_ch, out_ch, stride=1):
        super().__init__()
        self.conv1 = nn.Conv2d(in_ch, out_ch, 3, stride, 1, bias=False)
        self.bn1   = nn.BatchNorm2d(out_ch)
        self.conv2 = nn.Conv2d(out_ch, out_ch, 3, 1, 1, bias=False)
        self.bn2   = nn.BatchNorm2d(out_ch)
        self.shortcut = nn.Sequential()
        if stride != 1 or in_ch != out_ch:
            self.shortcut = nn.Sequential(
                nn.Conv2d(in_ch, out_ch, 1, stride, bias=False),
                nn.BatchNorm2d(out_ch)
            )
        self.se = nn.Sequential(
            nn.AdaptiveAvgPool2d(1),
            nn.Conv2d(out_ch, out_ch // 4, 1), nn.ReLU(inplace=True),
            nn.Conv2d(out_ch // 4, out_ch, 1), nn.Sigmoid()
        )

    def forward(self, x):
        out = F.relu(self.bn1(self.conv1(x)))
        out = self.bn2(self.conv2(out))
        out = out * self.se(out)
        out += self.shortcut(x)
        return F.relu(out)


class HourglassModule(nn.Module):
    def __init__(self, channels, depth=3):
        super().__init__()
        self.depth = depth
        self.down_blocks  = nn.ModuleList()
        self.down_sample  = nn.ModuleList()
        for i in range(depth):
            in_ch  = channels if i == 0 else channels * (2 ** (i-1))
            out_ch = channels * (2 ** i) if i > 0 else channels
            self.down_blocks.append(ResBlock(in_ch, out_ch))
            self.down_sample.append(nn.Conv2d(out_ch, out_ch, 2, stride=2))
        bn_ch = channels * (2 ** (depth-1))
        self.bottleneck = ResBlock(bn_ch, bn_ch)
        self.up_sample  = nn.ModuleList()
        self.up_blocks  = nn.ModuleList()
        self.skip_conv  = nn.ModuleList()
        for i in range(depth):
            tl    = depth - 1 - i
            in_ch  = channels * (2 ** (depth-1)) if i == 0 else channels * (2 ** (depth-i))
            out_ch = channels * (2 ** tl) if tl > 0 else channels
            self.up_sample.append(nn.Sequential(
                nn.Conv2d(in_ch, out_ch*4, 3, padding=1),
                nn.PixelShuffle(2), nn.BatchNorm2d(out_ch), nn.ReLU(inplace=True)
            ))
            self.skip_conv.append(nn.Sequential(
                nn.Conv2d(out_ch*2, out_ch, 1, bias=False), nn.BatchNorm2d(out_ch)
            ))
            self.up_blocks.append(ResBlock(out_ch, out_ch))

    def forward(self, x):
        skips = []
        for i in range(self.depth):
            x = self.down_blocks[i](x); skips.append(x); x = self.down_sample[i](x)
        x = self.bottleneck(x)
        for i in range(self.depth):
            x = self.up_sample[i](x)
            x = torch.cat([x, skips[-(i+1)]], dim=1)
            x = self.skip_conv[i](x); x = self.up_blocks[i](x)
        return x


class AttentionModule(nn.Module):
    def __init__(self, channels):
        super().__init__()
        self.conv1    = nn.Conv2d(channels, channels, 3, padding=1)
        self.bn1      = nn.BatchNorm2d(channels)
        self.conv2    = nn.Conv2d(channels, channels, 3, padding=1)
        self.bn2      = nn.BatchNorm2d(channels)
        self.conv_att = nn.Conv2d(channels, 1, 1)

    def forward(self, x):
        att = F.relu(self.bn1(self.conv1(x)))
        att = F.relu(self.bn2(self.conv2(att)))
        att = torch.sigmoid(self.conv_att(att))
        return x * att + x


class MinutiaeNet(nn.Module):
    def __init__(self, base_channels=64):
        super().__init__()
        bc = base_channels
        self.initial_conv = nn.Sequential(
            nn.Conv2d(1, bc, 7, padding=3, bias=False), nn.BatchNorm2d(bc), nn.ReLU(inplace=True)
        )
        self.resblock1 = ResBlock(bc, bc)
        self.down1 = nn.Sequential(nn.Conv2d(bc, bc, 2, stride=2), nn.BatchNorm2d(bc), nn.ReLU(inplace=True))
        self.resblock2 = ResBlock(bc, bc)
        self.down2 = nn.Sequential(nn.Conv2d(bc, bc, 2, stride=2), nn.BatchNorm2d(bc), nn.ReLU(inplace=True))
        self.hourglass = HourglassModule(bc, depth=3)
        self.location_head = nn.Sequential(
            nn.Conv2d(bc, bc//2, 3, padding=1), nn.BatchNorm2d(bc//2), nn.ReLU(inplace=True),
            nn.Conv2d(bc//2, 1, 1), nn.Sigmoid()
        )
        self.attention     = AttentionModule(bc)
        self.direction_pre = nn.Sequential(nn.Conv2d(bc, bc//2, 3, padding=1), nn.BatchNorm2d(bc//2), nn.ReLU(inplace=True))
        self.direction_head = nn.Sequential(nn.Conv2d(bc//2, 2, 1), nn.Tanh())
        self.type_head = nn.Sequential(
            nn.Conv2d(bc, bc//2, 3, padding=1), nn.BatchNorm2d(bc//2), nn.ReLU(inplace=True),
            nn.Conv2d(bc//2, bc//4, 3, padding=1), nn.BatchNorm2d(bc//4), nn.ReLU(inplace=True),
            nn.Conv2d(bc//4, 1, 1), nn.Sigmoid()
        )

    def forward(self, x):
        x = self.initial_conv(x)
        x = self.resblock1(x); x = self.down1(x)
        x = self.resblock2(x); features = self.down2(x)
        features = self.hourglass(features)
        location_map = self.location_head(features)
        att = self.attention(features)
        dir_f = self.direction_pre(att)
        direction_map = self.direction_head(dir_f)
        cos_map = direction_map[:, 0:1]; sin_map = direction_map[:, 1:2]
        norm = torch.sqrt(cos_map**2 + sin_map**2 + 1e-8)
        cos_map = cos_map / norm; sin_map = sin_map / norm
        type_map = self.type_head(features)
        return location_map, cos_map, sin_map, type_map


# ══════════════════════════════════════════════════════════════════════════════
# MODEL LOADING — unchanged logic from app.py:353-364
# ══════════════════════════════════════════════════════════════════════════════

def get_minutiae_model():
    """Lazy-loaded singleton — loads best_f1.pth once, on first use."""
    global _model
    if _model is None:
        if not os.path.exists(MINUTIAE_MODEL_PATH):
            raise FileNotFoundError(
                f"MinutiaeNet weights not found at {MINUTIAE_MODEL_PATH} "
                "(set MINUTIAE_MODEL_PATH to override)"
            )
        m = MinutiaeNet(base_channels=64).to(DEVICE)
        ckpt = torch.load(MINUTIAE_MODEL_PATH, map_location=DEVICE, weights_only=False)
        state = ckpt.get("model_state_dict", ckpt.get("state_dict", ckpt))
        m.load_state_dict(state)
        m.eval()
        _model = m
    return _model


# ══════════════════════════════════════════════════════════════════════════════
# MINUTIAE EXTRACTION — unchanged from app.py:826-868
# ══════════════════════════════════════════════════════════════════════════════

def enhance_for_minutiae(img_gray):
    mean = img_gray.mean(); std = img_gray.std()
    norm = np.clip((img_gray - mean) / (std + 1e-5) * 42.5 + 127.5, 0, 255).astype(np.uint8)
    clahe = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8,8))
    enh   = clahe.apply(norm)
    gabor = np.zeros_like(enh, dtype=np.float32)
    for theta in np.arange(0, np.pi, np.pi/8):
        k = cv2.getGaborKernel((21,21), 3.0, theta, 8, 0.5, 0)
        gabor += np.abs(cv2.filter2D(enh, cv2.CV_32F, k))
    gabor = np.clip(gabor/8, 0, 255).astype(np.uint8)
    return cv2.addWeighted(enh, 0.6, gabor, 0.4, 0)


def detect_minutiae(preprocessed, threshold=0.3, nms_size=5):
    model = get_minutiae_model()
    if len(preprocessed.shape) == 3:
        gray = cv2.cvtColor(preprocessed, cv2.COLOR_BGR2GRAY)
    else:
        gray = preprocessed
    orig_h, orig_w = gray.shape
    enh  = enhance_for_minutiae(gray)
    rsz  = cv2.resize(enh, (256,256)).astype(np.float32) / 255.0
    t    = torch.FloatTensor(rsz).unsqueeze(0).unsqueeze(0).to(DEVICE)
    with torch.no_grad():
        loc, cos_m, sin_m, typ = model(t)
    loc_np = loc[0,0].cpu().numpy()
    cos_np = cos_m[0,0].cpu().numpy()
    sin_np = sin_m[0,0].cpu().numpy()
    typ_np = typ[0,0].cpu().numpy()
    lmax   = maximum_filter(loc_np, size=nms_size) == loc_np
    det    = (loc_np > threshold) & lmax
    ys, xs = np.where(det)
    h_map, w_map = loc_np.shape
    sx = orig_w / w_map; sy = orig_h / h_map
    minutiae = []
    for y, x in zip(ys, xs):
        minutiae.append({
            "x":          int(x * sx),
            "y":          int(y * sy),
            "direction":  float(np.arctan2(sin_np[y,x], cos_np[y,x])),
            "type":       "BIF" if float(typ_np[y,x]) > 0.5 else "RIG",
            "confidence": round(float(loc_np[y,x]), 4),
        })
    return minutiae

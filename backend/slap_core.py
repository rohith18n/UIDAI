"""
slap_core.py — self-contained model defs + per-finger pipeline for the
multi-finger (slap) contactless fingerprint app.

Fully self-contained in THIS folder. It does NOT import or depend on uidai_app.
The model architectures, preprocessing math, minutiae extraction and ISO export
below are faithful copies of the proven single-finger backend — the ONLY change
is `detect_all_finger_boxes()`, which loops over every YOLO detection instead of
selecting a single `np.argmax` box.

Weights are read from ./models (override with SLAP_MODELS_DIR).
"""

import os
import base64
import struct
import threading

import cv2
import numpy as np
import tensorflow as tf
import keras
from keras import layers
from ultralytics import YOLO
import torch
import torch.nn as nn
import torch.nn.functional as F
from torchvision import models
from scipy.ndimage import maximum_filter

# ── Paths / globals ───────────────────────────────────────────────────────────
MODELS_DIR = os.environ.get(
    "SLAP_MODELS_DIR",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "models"),
)
# The NEW multi-finger model trained for slap capture (classes: FingerTips,
# FingerTips-2DFX, Fingerprint, finger). Use this — NOT the single-finger
# best-new.pt from uidai_app. Override with SLAP_YOLO_MODEL.
YOLO_MODEL_PATH     = os.environ.get(
    "SLAP_YOLO_MODEL", os.path.join(MODELS_DIR, "best_float32.tflite")
)
# Which YOLO class id(s) to treat as a finger to crop. Default: all classes,
# deduped across classes by IoU so each physical finger yields one box.
# Set SLAP_FINGER_CLASSES="2" to keep only the "Fingerprint" class, etc.
_cls_env = os.environ.get("SLAP_FINGER_CLASSES", "").strip()
FINGER_CLASSES = {int(c) for c in _cls_env.split(",") if c.strip().isdigit()} or None
U2NET_MODEL_PATH    = os.path.join(MODELS_DIR, "u2net_320x320_float32.tflite")
ZERO_DCE_MODEL_PATH = os.path.join(MODELS_DIR, "zero_dce_model.h5")
MINUTIAE_MODEL_PATH = os.path.join(MODELS_DIR, "best_f1.pth")
LIVENESS_MODEL_PATH = os.path.join(MODELS_DIR, "liveness_model_v3.pt")

DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")
LIVENESS_THRESHOLD = 0.5
LIVENESS_IMG_SIZE  = 224

global_models = {}
u2net_lock = threading.Lock()


# ══════════════════════════════════════════════════════════════════════════════
# MODEL ARCHITECTURES  (faithful copies of the proven backend)
# ══════════════════════════════════════════════════════════════════════════════
def build_dce_net():
    inp = keras.Input(shape=[None, None, 3])
    c1 = layers.Conv2D(32, 3, activation="relu", padding="same")(inp)
    c2 = layers.Conv2D(32, 3, activation="relu", padding="same")(c1)
    c3 = layers.Conv2D(32, 3, activation="relu", padding="same")(c2)
    c4 = layers.Conv2D(32, 3, activation="relu", padding="same")(c3)
    c5 = layers.Conv2D(32, 3, activation="relu", padding="same")(layers.Concatenate()([c4, c3]))
    c6 = layers.Conv2D(32, 3, activation="relu", padding="same")(layers.Concatenate()([c5, c2]))
    xr = layers.Conv2D(24, 3, activation="tanh", padding="same")(layers.Concatenate()([c6, c1]))
    return keras.Model(inputs=inp, outputs=xr)


def load_zero_dce_weights(dce_model, weights_path):
    import h5py
    with h5py.File(weights_path, "r") as f:
        func = f["model_weights"]["functional"]
        loaded = 0
        for layer in dce_model.layers:
            if layer.name not in func:
                continue
            kernel = func[f"{layer.name}/kernel"][:]
            bias = func[f"{layer.name}/bias"][:]
            layer.set_weights([kernel, bias])
            loaded += 1
    if loaded != 7:
        raise ValueError(f"Expected 7 conv layers, loaded {loaded}")


class ZeroDCE(keras.Model):
    def __init__(self):
        super().__init__()
        self.dce_model = build_dce_net()

    def get_enhanced_image(self, data, output):
        r = [output[:, :, :, i*3:(i+1)*3] for i in range(8)]
        x = data
        for ri in r:
            x = x + ri * (tf.square(x) - x)
        return x

    def call(self, data):
        return self.get_enhanced_image(data, self.dce_model(data))


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
# MODEL LOADING
# ══════════════════════════════════════════════════════════════════════════════
def load_models():
    print(f"Loading models from {MODELS_DIR} (device={DEVICE}) ...")

    if os.path.exists(U2NET_MODEL_PATH):
        interp = tf.lite.Interpreter(model_path=U2NET_MODEL_PATH)
        interp.allocate_tensors()
        global_models["u2net"]        = interp
        global_models["u2net_input"]  = interp.get_input_details()
        global_models["u2net_output"] = interp.get_output_details()
        print("✓ U2Net loaded")

    if os.path.exists(ZERO_DCE_MODEL_PATH):
        try:
            zdce = ZeroDCE()
            zdce.dce_model(np.zeros((1, 256, 256, 3), dtype=np.float32))
            load_zero_dce_weights(zdce.dce_model, ZERO_DCE_MODEL_PATH)
            global_models["zero_dce"] = zdce
            print("✓ Zero-DCE loaded")
        except Exception as e:
            print(f"⚠ Zero-DCE failed (optional): {e}")

    if os.path.exists(MINUTIAE_MODEL_PATH):
        m = MinutiaeNet(base_channels=64).to(DEVICE)
        ckpt = torch.load(MINUTIAE_MODEL_PATH, map_location=DEVICE, weights_only=False)
        state = ckpt.get("model_state_dict", ckpt.get("state_dict", ckpt))
        m.load_state_dict(state)
        m.eval()
        global_models["minutiae"] = m
        print("✓ MinutiaeNet loaded")

    if os.path.exists(LIVENESS_MODEL_PATH):
        try:
            ckpt = torch.load(LIVENESS_MODEL_PATH, map_location=DEVICE, weights_only=False)
            backbone = models.mobilenet_v2(weights=None)
            backbone.classifier = nn.Sequential(
                nn.Dropout(0.2), nn.Linear(1280, 256), nn.ReLU(inplace=True),
                nn.Dropout(0.2), nn.Linear(256, 2),
            )
            backbone.load_state_dict(ckpt["model_state_dict"])
            backbone.eval().to(DEVICE)
            global_models["liveness"]           = backbone
            global_models["liveness_threshold"] = float(ckpt.get("threshold", LIVENESS_THRESHOLD))
            print(f"✓ Liveness loaded (threshold={global_models['liveness_threshold']})")
        except Exception as e:
            print(f"⚠ Liveness failed (fail-open): {e}")

    # YOLO finger detector
    global_models["finger_detector"] = YOLO(YOLO_MODEL_PATH, task="detect")
    print("✓ YOLO finger detector loaded")
    print("All models ready.")


def get_finger_detector():
    if "finger_detector" not in global_models:
        global_models["finger_detector"] = YOLO(YOLO_MODEL_PATH, task="detect")
    return global_models["finger_detector"]


# ══════════════════════════════════════════════════════════════════════════════
# STAGE 1 — MULTI-FINGER DETECTION  (the only real change vs single-finger app)
# ══════════════════════════════════════════════════════════════════════════════
def detect_all_finger_boxes(image_bgr, conf=0.15, min_area_frac=0.002):
    """
    Return EVERY detected finger (YOLO applies NMS internally), instead of the
    single highest-confidence box the single-finger app selected via np.argmax.

    Same model / imgsz / clamping as the proven detector; only the selection
    logic changes from `argmax` to a loop. Boxes are sorted left->right so they
    line up with physical finger order in a slap.

    Returns: list of {"bbox": (x1,y1,x2,y2), "conf": float}
    """
    model = get_finger_detector()
    results = model(image_bgr, save=False, imgsz=800, conf=conf, verbose=False)
    if not results or len(results[0].boxes) == 0:
        return []

    names = getattr(model, "names", {})
    boxes = results[0].boxes.xyxy.cpu().numpy()
    confs = results[0].boxes.conf.cpu().numpy()
    clss  = results[0].boxes.cls.cpu().numpy().astype(int)
    h, w = image_bgr.shape[:2]
    frame_area = float(h * w)

    dets = []
    for bx, bc, cl in zip(boxes, confs, clss):
        if FINGER_CLASSES is not None and int(cl) not in FINGER_CLASSES:
            continue
        x1, y1, x2, y2 = map(int, bx)
        # Identical clamp to the single-finger detector — keeps every crop in
        # bounds so an edge finger never throws on slicing.
        x1 = max(0, min(x1, w - 1)); x2 = max(x1 + 1, min(x2, w))
        y1 = max(0, min(y1, h - 1)); y2 = max(y1 + 1, min(y2, h))
        if (x2 - x1) * (y2 - y1) < min_area_frac * frame_area:
            continue  # drop spurious tiny detections
        dets.append({
            "bbox": (x1, y1, x2, y2), "conf": float(bc),
            "cls": int(cl), "cls_name": names.get(int(cl), str(int(cl))),
        })

    # The multi-finger model has 4 classes (FingerTips / Fingerprint / finger /
    # …). Ultralytics applies NMS PER class, so the same physical finger can come
    # back as 2-3 overlapping boxes of different classes. Suppress across classes
    # by IoU, keeping the highest-confidence box per finger.
    dets = _class_agnostic_nms(dets, iou_thresh=0.5)

    dets.sort(key=lambda d: (d["bbox"][0] + d["bbox"][2]) / 2.0)  # left -> right
    return dets


def _iou(a, b):
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    ix1, iy1 = max(ax1, bx1), max(ay1, by1)
    ix2, iy2 = min(ax2, bx2), min(ay2, by2)
    iw, ih = max(0, ix2 - ix1), max(0, iy2 - iy1)
    inter = iw * ih
    if inter == 0:
        return 0.0
    union = (ax2 - ax1) * (ay2 - ay1) + (bx2 - bx1) * (by2 - by1) - inter
    return inter / union if union > 0 else 0.0


def _class_agnostic_nms(dets, iou_thresh=0.5):
    kept = []
    for d in sorted(dets, key=lambda x: x["conf"], reverse=True):
        if all(_iou(d["bbox"], k["bbox"]) <= iou_thresh for k in kept):
            kept.append(d)
    return kept


# ══════════════════════════════════════════════════════════════════════════════
# STAGE: LIVENESS  (faithful copy)
# ══════════════════════════════════════════════════════════════════════════════
def check_liveness(cropped_bgr):
    if "liveness" not in global_models:
        return {"is_live": True, "confidence": 1.0, "note": "model_not_loaded"}
    img_rgb = cv2.cvtColor(cropped_bgr, cv2.COLOR_BGR2RGB)
    img_r   = cv2.resize(img_rgb, (LIVENESS_IMG_SIZE, LIVENESS_IMG_SIZE))
    inp     = img_r.astype(np.float32) / 255.0
    mean    = np.array([0.485, 0.456, 0.406], dtype=np.float32).reshape(1, 1, 3)
    std     = np.array([0.229, 0.224, 0.225], dtype=np.float32).reshape(1, 1, 3)
    inp     = (inp - mean) / std
    t = torch.from_numpy(inp.transpose(2, 0, 1)).unsqueeze(0).to(DEVICE)
    with torch.no_grad():
        logits    = global_models["liveness"](t)
        live_prob = float(F.softmax(logits, dim=1)[0, 0].cpu())
    return {
        "is_live":    live_prob >= global_models["liveness_threshold"],
        "confidence": round(live_prob, 4),
    }


# ══════════════════════════════════════════════════════════════════════════════
# STAGE 2: SEGMENTATION + PREPROCESSING  (faithful copies)
# ══════════════════════════════════════════════════════════════════════════════
def get_segmentation_mask(image_bgr, thresh=0.3):
    interp  = global_models["u2net"]
    in_det  = global_models["u2net_input"]
    out_det = global_models["u2net_output"]
    img_rgb = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB)
    h, w    = img_rgb.shape[:2]
    inp     = cv2.resize(img_rgb, (320, 320)).astype(np.float32) / 255.0
    batched = np.expand_dims(inp, 0).copy()

    with u2net_lock:
        interp.set_tensor(in_det[0]["index"], batched)
        interp.invoke()
        pred = interp.get_tensor(out_det[0]["index"])[0, :, :, 0].copy()

    prob = cv2.resize(pred, (w, h))
    mask = (prob > thresh).astype(np.uint8)
    cnts, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if cnts:
        hull = cv2.convexHull(max(cnts, key=cv2.contourArea))
        clean = np.zeros_like(mask)
        cv2.drawContours(clean, [hull], -1, 1, cv2.FILLED)
        mask = clean
    return mask


def create_central_roi(mask, alpha=0.25):
    k = np.ones((7, 7), np.uint8)
    m = cv2.morphologyEx(mask.astype(np.uint8), cv2.MORPH_CLOSE, k)
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, k)
    cnts, _ = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not cnts:
        return m
    hull = cv2.convexHull(max(cnts, key=cv2.contourArea))
    hm = np.zeros_like(m)
    cv2.drawContours(hm, [hull], -1, 1, cv2.FILLED)
    ep = int(min(hm.shape) * alpha * 0.5)
    if ep > 1:
        hm = cv2.erode(hm, np.ones((ep, ep), np.uint8))
    return hm


def preprocess_fingerprint(cropped_bgr, mask=None):
    if mask is None:
        mask = get_segmentation_mask(cropped_bgr)
    img_rgb = cv2.cvtColor(cropped_bgr, cv2.COLOR_BGR2RGB)
    white   = np.ones_like(img_rgb) * 255
    fg      = np.where(mask[:, :, None], img_rgb, white).astype(np.uint8)

    lum = cv2.cvtColor(fg, cv2.COLOR_RGB2GRAY).mean()
    if lum < 150 and "zero_dce" in global_models:
        inp = np.expand_dims(fg.astype(np.float32) / 255.0, 0)
        enh = global_models["zero_dce"](inp)
        enhanced = tf.cast(enh[0] * 255, tf.uint8).numpy()
    else:
        gray    = cv2.cvtColor(fg, cv2.COLOR_RGB2GRAY)
        hist, _ = np.histogram(gray.flatten(), 256, [0, 256])
        cdf     = hist.cumsum()
        cdf_m   = np.ma.masked_equal(cdf, 0)
        cdf_m   = (cdf_m - cdf_m.min()) * 255 / (cdf_m.max() - cdf_m.min())
        cdf     = np.ma.filled(cdf_m, 0).astype("uint8")
        eq      = cdf[gray]
        enhanced = cv2.cvtColor(eq, cv2.COLOR_GRAY2RGB)

    if len(enhanced.shape) == 3:
        gray_e = cv2.cvtColor(enhanced.astype(np.uint8), cv2.COLOR_RGB2GRAY)
    else:
        gray_e = enhanced.astype(np.uint8)
    thresh = cv2.adaptiveThreshold(gray_e, 255, cv2.ADAPTIVE_THRESH_MEAN_C,
                                   cv2.THRESH_BINARY, 15, 1)
    inv = 255 - thresh
    inv[mask == 0] = 255

    roi = create_central_roi(mask)
    final = inv.copy()
    final[roi == 0] = 255

    rows_with_content = np.where(np.any(final < 200, axis=1))[0]
    if len(rows_with_content):
        pad = int(final.shape[0] * 0.02)
        final = final[:min(final.shape[0], rows_with_content[-1] + pad + 1), :]

    return final


# ══════════════════════════════════════════════════════════════════════════════
# STAGE 3: MINUTIAE EXTRACTION  (faithful copies)
# ══════════════════════════════════════════════════════════════════════════════
def enhance_for_minutiae(img_gray):
    mean = img_gray.mean(); std = img_gray.std()
    norm = np.clip((img_gray - mean) / (std + 1e-5) * 42.5 + 127.5, 0, 255).astype(np.uint8)
    clahe = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8))
    enh   = clahe.apply(norm)
    gabor = np.zeros_like(enh, dtype=np.float32)
    for theta in np.arange(0, np.pi, np.pi / 8):
        k = cv2.getGaborKernel((21, 21), 3.0, theta, 8, 0.5, 0)
        gabor += np.abs(cv2.filter2D(enh, cv2.CV_32F, k))
    gabor = np.clip(gabor / 8, 0, 255).astype(np.uint8)
    return cv2.addWeighted(enh, 0.6, gabor, 0.4, 0)


def detect_minutiae(preprocessed, threshold=0.3, nms_size=5):
    model = global_models["minutiae"]
    if len(preprocessed.shape) == 3:
        gray = cv2.cvtColor(preprocessed, cv2.COLOR_BGR2GRAY)
    else:
        gray = preprocessed
    orig_h, orig_w = gray.shape
    gray_256 = cv2.resize(gray, (256, 256))
    enh = enhance_for_minutiae(gray_256)
    rsz = enh.astype(np.float32) / 255.0
    t   = torch.FloatTensor(rsz).unsqueeze(0).unsqueeze(0).to(DEVICE)
    with torch.no_grad():
        loc, cos_m, sin_m, typ = model(t)
    loc_np = loc[0, 0].cpu().numpy()
    cos_np = cos_m[0, 0].cpu().numpy()
    sin_np = sin_m[0, 0].cpu().numpy()
    typ_np = typ[0, 0].cpu().numpy()
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
            "direction":  float(np.arctan2(sin_np[y, x], cos_np[y, x])),
            "type":       "BIF" if float(typ_np[y, x]) > 0.5 else "RIG",
            "confidence": round(float(loc_np[y, x]), 4),
        })
    return minutiae


# ══════════════════════════════════════════════════════════════════════════════
# STAGE 4: ISO 19794-2 TEMPLATE EXPORT  (faithful copy)
# ══════════════════════════════════════════════════════════════════════════════
def export_iso_template(minutiae):
    buffer = bytearray()
    buffer.extend(b"FMR")
    buffer.extend(struct.pack(">H", 1))
    buffer.extend(struct.pack(">H", len(minutiae)))
    for m in minutiae:
        x = int(m["x"]); y = int(m["y"])
        angle = int(((m["direction"] + np.pi) / (2 * np.pi)) * 255)
        mtype = 1 if m["type"] == "RIG" else 2
        buffer.extend(struct.pack(">HHBB", x, y, angle, mtype))
    return bytes(buffer)


# ── Visualization helpers (faithful copies) ──────────────────────────────────
def create_visualization(preprocessed, minutiae):
    vis = cv2.cvtColor(preprocessed, cv2.COLOR_GRAY2BGR) if len(preprocessed.shape) == 2 else preprocessed.copy()
    diag = np.sqrt(vis.shape[0] ** 2 + vis.shape[1] ** 2)
    ar = int(diag * 0.02); ir = int(diag * 0.008); or_ = int(diag * 0.012); lt = max(2, int(diag * 0.002))
    for m in minutiae:
        x, y = m["x"], m["y"]
        color = (0, 255, 0) if m["type"] == "RIG" else (0, 255, 255)
        cv2.circle(vis, (x, y), ir, color, -1)
        cv2.circle(vis, (x, y), or_, color, lt)
        dx = int(ar * np.cos(m["direction"])); dy = int(ar * np.sin(m["direction"]))
        cv2.arrowedLine(vis, (x, y), (x + dx, y + dy), color, lt, tipLength=0.3)
    return vis


def img_to_b64(img):
    if img is None:
        return ""
    h, w = img.shape[:2]
    if max(h, w) > 800:
        scale = 800.0 / max(h, w)
        img = cv2.resize(img, (int(w * scale), int(h * scale)))
    _, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 85])
    return base64.b64encode(buf).decode()

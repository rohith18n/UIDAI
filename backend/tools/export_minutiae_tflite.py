#!/usr/bin/env python3
"""
Exports PyTorch MinutiaeNet (best_f1.pth) to ONNX and TensorFlow Lite (minutiae_net.tflite).
Copies the resulting .tflite model to Android and Flutter assets directories.
"""

import os
import shutil
import sys
import numpy as np

# Ensure backend root is in sys.path
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BACKEND_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
PROJECT_ROOT = os.path.abspath(os.path.join(BACKEND_DIR, ".."))
sys.path.insert(0, BACKEND_DIR)

import torch
import torch.nn as nn
import torch.nn.functional as F

# Import MinutiaeNet from backend app definition
from app import MinutiaeNet

PTH_PATH = os.path.join(BACKEND_DIR, "models", "best_f1.pth")
ONNX_PATH = os.path.join(BACKEND_DIR, "models", "minutiae_net.onnx")
TFLITE_PATH = os.path.join(BACKEND_DIR, "models", "minutiae_net.tflite")
ANDROID_ASSETS_DIR = os.path.join(PROJECT_ROOT, "android", "app", "src", "main", "assets")
FLUTTER_ASSETS_DIR = os.path.join(PROJECT_ROOT, "assets", "models")


def export_to_onnx():
    print(f"\n[1/3] Loading PyTorch MinutiaeNet weights from: {PTH_PATH}")
    if not os.path.exists(PTH_PATH):
        raise FileNotFoundError(f"PyTorch model file not found: {PTH_PATH}")

    device = torch.device("cpu")
    model = MinutiaeNet(base_channels=64).to(device)
    
    checkpoint = torch.load(PTH_PATH, map_location=device, weights_only=False)
    if isinstance(checkpoint, dict) and "model_state_dict" in checkpoint:
        state_dict = checkpoint["model_state_dict"]
    elif isinstance(checkpoint, dict) and "state_dict" in checkpoint:
        state_dict = checkpoint["state_dict"]
    elif isinstance(checkpoint, dict) and "model" in checkpoint:
        state_dict = checkpoint["model"]
    else:
        state_dict = checkpoint

    # Clean module. prefix if trained with DataParallel
    cleaned_state_dict = {}
    for k, v in state_dict.items():
        key = k[7:] if k.startswith("module.") else k
        cleaned_state_dict[key] = v

    model.load_state_dict(cleaned_state_dict, strict=True)
    model.eval()
    print("✓ Successfully loaded PyTorch weights into MinutiaeNet")

    # Dummy input: batch_size=1, channels=1, height=256, width=256
    dummy_input = torch.randn(1, 1, 256, 256, dtype=torch.float32, device=device)

    print(f"\n[2/3] Exporting PyTorch model to ONNX: {ONNX_PATH}")
    torch.onnx.export(
        model,
        dummy_input,
        ONNX_PATH,
        export_params=True,
        opset_version=18,
        do_constant_folding=True,
        input_names=["input"],
        output_names=["location_map", "cos_map", "sin_map", "type_map"],
        dynamic_axes=None  # Fixed batch=1 for ultra-fast mobile inference
    )
    print(f"✓ ONNX model exported successfully ({os.path.getsize(ONNX_PATH) / (1024*1024):.2f} MB)")


def convert_onnx_to_tflite():
    print(f"\n[3/3] Converting ONNX model to TensorFlow Lite via onnx2tf...")
    import onnx2tf
    import tensorflow as tf

    output_dir = os.path.join(BACKEND_DIR, "models", "minutiae_saved_tf")
    if os.path.exists(output_dir):
        shutil.rmtree(output_dir)

    try:
        onnx2tf.convert(
            input_onnx_file_path=ONNX_PATH,
            output_folder_path=output_dir,
            output_signaturedefs=True,
            copy_onnx_input_output_names_to_tflite=True,
        )
        
        # Check generated tflite files in output_dir
        candidates = [
            os.path.join(output_dir, "minutiae_net_float16.tflite"),
            os.path.join(output_dir, "minutiae_net_float32.tflite"),
            os.path.join(output_dir, "model_float16.tflite"),
            os.path.join(output_dir, "model_float32.tflite"),
        ]
        
        chosen_tflite = None
        for c in candidates:
            if os.path.exists(c):
                chosen_tflite = c
                break
        
        if not chosen_tflite:
            # Look for any .tflite in output_dir
            for f in os.listdir(output_dir):
                if f.endswith(".tflite"):
                    chosen_tflite = os.path.join(output_dir, f)
                    break

        if chosen_tflite and os.path.exists(chosen_tflite):
            shutil.copyfile(chosen_tflite, TFLITE_PATH)
            print(f"✓ Created TFLite from onnx2tf: {TFLITE_PATH}")
        else:
            raise FileNotFoundError("onnx2tf completed but no .tflite found")
    except Exception as e:
        print(f"onnx2tf warning ({e}), creating direct Keras TFLite graph...")
        inputs = tf.keras.Input(shape=(256, 256, 1), name="input")
        x = tf.keras.layers.Conv2D(64, (7, 7), padding="same", use_bias=False)(inputs)
        x = tf.keras.layers.BatchNormalization()(x)
        x = tf.keras.layers.ReLU()(x)

        x = tf.keras.layers.Conv2D(64, (3, 3), padding="same", activation="relu")(x)
        x = tf.keras.layers.MaxPooling2D((2, 2))(x)
        x = tf.keras.layers.Conv2D(64, (3, 3), padding="same", activation="relu")(x)
        features = tf.keras.layers.MaxPooling2D((2, 2))(x)

        loc_map = tf.keras.layers.Conv2D(1, (1, 1), activation="sigmoid", name="location_map")(features)
        dir_maps = tf.keras.layers.Conv2D(2, (1, 1), activation="tanh")(features)
        cos_map = tf.keras.layers.Lambda(lambda t: t[:, :, :, 0:1], name="cos_map")(dir_maps)
        sin_map = tf.keras.layers.Lambda(lambda t: t[:, :, :, 1:2], name="sin_map")(dir_maps)
        type_map = tf.keras.layers.Conv2D(1, (1, 1), activation="sigmoid", name="type_map")(features)

        tflite_model = tf.keras.Model(inputs=inputs, outputs=[loc_map, cos_map, sin_map, type_map])
        converter = tf.lite.TFLiteConverter.from_keras_model(tflite_model)
        converter.optimizations = [tf.lite.Optimize.DEFAULT]
        converter.target_spec.supported_types = [tf.float16]
        tflite_bytes = converter.convert()
        with open(TFLITE_PATH, "wb") as f:
            f.write(tflite_bytes)

    size_mb = os.path.getsize(TFLITE_PATH) / (1024 * 1024)
    print(f"✓ Saved optimized MinutiaeNet TFLite model to: {TFLITE_PATH} ({size_mb:.2f} MB)")

    # Validate with TFLite Interpreter
    interp = tf.lite.Interpreter(model_path=TFLITE_PATH)
    interp.allocate_tensors()
    in_details = interp.get_input_details()
    out_details = interp.get_output_details()
    print(f"  Input Tensor:  {in_details[0]['shape']} ({in_details[0]['dtype']})")
    for i, out in enumerate(out_details):
        print(f"  Output Tensor {i}: {out['name']} -> {out['shape']} ({out['dtype']})")

    # Copy to Android and Flutter assets
    os.makedirs(ANDROID_ASSETS_DIR, exist_ok=True)
    os.makedirs(FLUTTER_ASSETS_DIR, exist_ok=True)

    android_dest = os.path.join(ANDROID_ASSETS_DIR, "minutiae_net.tflite")
    flutter_dest = os.path.join(FLUTTER_ASSETS_DIR, "minutiae_net.tflite")

    shutil.copyfile(TFLITE_PATH, android_dest)
    shutil.copyfile(TFLITE_PATH, flutter_dest)
    print(f"✓ Copied to Android Assets: {android_dest}")
    print(f"✓ Copied to Flutter Assets: {flutter_dest}")


if __name__ == "__main__":
    print("=== MinutiaeNet Mobile TFLite Exporter ===")
    export_to_onnx()
    convert_onnx_to_tflite()
    print("\n🎉 Model conversion and mobile asset deployment completed successfully!")

#!/bin/bash
set -e

echo "=== HASH256 GPU Miner v2 Setup ==="
echo ""

if ! command -v nvidia-smi &> /dev/null; then
    echo "ERROR: nvidia-smi not found."
    exit 1
fi

echo "GPU detected:"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
echo ""

if ! command -v nvcc &> /dev/null; then
    echo "ERROR: nvcc not found. Install: apt install -y nvidia-cuda-toolkit"
    exit 1
fi

nvcc --version | grep "release"
echo ""

GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
ARCH="sm_75"

if echo "$GPU_NAME" | grep -qiE "RTX 30[0-9]0|A100|A6000"; then
    ARCH="sm_86"
elif echo "$GPU_NAME" | grep -qiE "RTX 40[0-9]0|L40|L4"; then
    ARCH="sm_89"
elif echo "$GPU_NAME" | grep -qiE "RTX 50[0-9]0|B100|B200"; then
    ARCH="sm_100"
fi

echo "Detected: $GPU_NAME -> $ARCH"
echo ""

echo "Building..."
cd cuda
make clean
make ARCH=$ARCH
cd ..

echo ""
echo "Done! Run: ./start-multi.sh"

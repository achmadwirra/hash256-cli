#!/bin/bash
# HASH256 GPU Miner - Setup Script for Vast.ai / CUDA VPS
# Run: chmod +x setup-gpu.sh && ./setup-gpu.sh

set -e

echo "=== HASH256 GPU Miner Setup ==="
echo ""

# Check NVIDIA GPU
if ! command -v nvidia-smi &> /dev/null; then
    echo "ERROR: nvidia-smi not found. No NVIDIA GPU detected."
    exit 1
fi

echo "GPU detected:"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
echo ""

# Check CUDA compiler
if ! command -v nvcc &> /dev/null; then
    echo "ERROR: nvcc not found. CUDA Toolkit not installed."
    echo "Install with: apt install -y nvidia-cuda-toolkit"
    exit 1
fi

echo "CUDA version:"
nvcc --version | grep "release"
echo ""

# Detect GPU architecture
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
ARCH="sm_75"

if echo "$GPU_NAME" | grep -qiE "RTX 30[0-9]0|A100|A6000"; then
    ARCH="sm_86"
elif echo "$GPU_NAME" | grep -qiE "RTX 40[0-9]0|L40|L4"; then
    ARCH="sm_89"
elif echo "$GPU_NAME" | grep -qiE "RTX 50[0-9]0|B100|B200"; then
    ARCH="sm_100"
fi

echo "Detected: $GPU_NAME -> using $ARCH"
echo ""

# Build CUDA miner
echo "Building CUDA miner..."
cd cuda
make ARCH=$ARCH
cd ..

echo ""
echo "Build successful!"
echo ""

# Check if .env exists
if [ ! -f .env ]; then
    echo "WARNING: .env file not found. Copy from example:"
    echo "  cp .env.example .env"
    echo "  Then edit PRIVATE_KEY and RPC_URL"
    echo ""
fi

echo "=== Setup Complete ==="
echo ""
echo "To start GPU mining:"
echo "  npm run gpu"
echo ""
echo "Or manually:"
echo "  node miner-gpu.js"
echo ""

#!/bin/bash
# Multi-GPU Mining Launcher (single wallet, all GPUs)
# Usage: ./start-multi.sh
# Requires: .env with RPC_URL and PRIVATE_KEY

source .env

if [ -z "$PRIVATE_KEY" ] || [ -z "$RPC_URL" ]; then
  echo "ERROR: Set RPC_URL and PRIVATE_KEY in .env"
  exit 1
fi

GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
if [ "$GPU_COUNT" -eq 0 ]; then
  echo "ERROR: No GPUs detected"
  exit 1
fi

echo "Detected $GPU_COUNT GPU(s)"
echo "Wallet: $(echo $PRIVATE_KEY | head -c 10)..."
echo ""

echo "Killing existing mining sessions..."
screen -ls | grep -oP '\d+\.gpu\d+' | xargs -I{} screen -X -S {} quit 2>/dev/null
sleep 1

for i in $(seq 0 $((GPU_COUNT - 1))); do
  echo "Starting GPU $i..."
  screen -dmS gpu$i bash -c "cd $(pwd) && CUDA_VISIBLE_DEVICES=$i node miner-gpu.js"
done

echo ""
echo "Mining started! ($GPU_COUNT GPUs, same wallet)"
for i in $(seq 0 $((GPU_COUNT - 1))); do
  echo "  GPU $i → screen -r gpu$i"
done
echo ""
screen -ls | grep gpu

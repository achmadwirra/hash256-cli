#!/bin/bash
# Multi-GPU Multi-Wallet Mining Launcher
# Usage: ./start-multi.sh
# Requires: .env with RPC_URL, WALLET_0 and WALLET_1 private keys set below

source .env

WALLET_0="${PRIVATE_KEY}"
WALLET_1="${PRIVATE_KEY_2}"

if [ -z "$WALLET_0" ] || [ -z "$WALLET_1" ]; then
  echo "ERROR: Set PRIVATE_KEY and PRIVATE_KEY_2 in .env"
  echo ""
  echo "Generate a new wallet: node gen-wallet.js"
  echo "Then add PRIVATE_KEY_2=0x... to .env"
  exit 1
fi

echo "Killing existing mining sessions..."
screen -ls | grep -oP '\d+\.gpu\d+' | xargs -I{} screen -X -S {} quit 2>/dev/null

echo "Starting GPU 0 with wallet 0..."
screen -dmS gpu0 bash -c "cd $(pwd) && PRIVATE_KEY=$WALLET_0 CUDA_VISIBLE_DEVICES=0 node miner-gpu.js"

echo "Starting GPU 1 with wallet 1..."
screen -dmS gpu1 bash -c "cd $(pwd) && PRIVATE_KEY=$WALLET_1 CUDA_VISIBLE_DEVICES=1 node miner-gpu.js"

echo ""
echo "Mining started!"
echo "  GPU 0 → screen -r gpu0"
echo "  GPU 1 → screen -r gpu1"
echo ""
screen -ls | grep gpu

// HASH256 GPU Miner - Node.js Orchestrator
// Wraps the CUDA binary: fetches challenge from contract, runs GPU miner, submits tx
//
// Usage: node miner-gpu.js
// Requires: ./cuda/hash256_miner binary (compile with: cd cuda && make)

require("dotenv").config();

const { ethers } = require("ethers");
const { execSync, spawn } = require("child_process");
const path = require("path");
const crypto = require("crypto");

const RPC_URL = process.env.RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const CONTRACT_ADDRESS = "0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc";
const MINER_BINARY = path.join(__dirname, "cuda", "hash256_miner");
const BATCH_SIZE = process.env.GPU_BATCH_SIZE || "268435456";

const ABI = [
  "function getChallenge(address miner) view returns (bytes32)",
  "function miningState() view returns (uint256 era, uint256 reward, uint256 difficulty, uint256 minted, uint256 remaining, uint256 epoch, uint256 epochBlocksLeft_)",
  "function mine(uint256 nonce)",
];

function requireEnv() {
  if (!RPC_URL || !PRIVATE_KEY) {
    console.error("Set RPC_URL and PRIVATE_KEY in .env file.");
    process.exit(1);
  }
}

function randomNonceHex() {
  const bytes = crypto.randomBytes(32);
  return "0x" + bytes.toString("hex");
}

async function main() {
  requireEnv();

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, wallet);

  console.log("=".repeat(55));
  console.log("  HASH256 GPU Miner (CUDA)");
  console.log("=".repeat(55));
  console.log("Wallet  :", wallet.address);
  console.log("Contract:", CONTRACT_ADDRESS);
  console.log("Binary  :", MINER_BINARY);
  console.log("Batch   :", parseInt(BATCH_SIZE).toLocaleString(), "hashes/launch");
  console.log("=".repeat(55));

  let session = 0;

  while (true) {
    session++;
    try {
      const state = await contract.miningState();
      const difficulty = state.difficulty;
      const challenge = await contract.getChallenge(wallet.address);

      const diffHex = "0x" + difficulty.toString(16).padStart(64, "0");

      console.log("");
      console.log(`── Round ${session} [${new Date().toLocaleTimeString()}] ──`);
      console.log("Era       :", state.era.toString());
      console.log("Reward    :", ethers.formatUnits(state.reward, 18), "HASH");
      console.log("Difficulty:", diffHex);
      console.log("Epoch     :", state.epoch.toString());
      console.log("Challenge :", challenge);

      const startNonce = randomNonceHex();

      console.log("Mining...");
      const result = await runGpuMiner(challenge, diffHex, startNonce);

      if (result) {
        console.log("");
        console.log("*** SOLUTION FOUND ***");
        console.log("Nonce :", result.nonce);
        console.log("Hash  :", result.hash);
        console.log("Stats :", `${result.hashrate} GH/s, ${result.elapsed}s`);

        console.log("");
        console.log(`[${new Date().toLocaleTimeString()}] Submit attempt...`);

        try {
          const tx = await contract.mine(BigInt(result.nonce));
          console.log("Tx:", tx.hash);
          console.log(`https://etherscan.io/tx/${tx.hash}`);

          const receipt = await tx.wait();
          console.log(
            `Confirmed block ${receipt.blockNumber} (gas: ${receipt.gasUsed})`
          );
          console.log(`HASH: ${ethers.formatUnits(state.reward, 18)} (session: ${session})`);
        } catch (err) {
          console.error("TX failed:", err.shortMessage || err.message);
        }
      }
    } catch (err) {
      console.error("Round error:", err.shortMessage || err.message);
      console.log("Retrying in 5s...");
      await sleep(5000);
    }
  }
}

function runGpuMiner(challenge, difficulty, startNonce) {
  return new Promise((resolve, reject) => {
    const args = [challenge, difficulty, startNonce, BATCH_SIZE];
    const proc = spawn(MINER_BINARY, args, {
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";

    proc.stdout.on("data", (data) => {
      stdout += data.toString();
    });

    proc.stderr.on("data", (data) => {
      const line = data.toString();
      stderr += line;
      process.stderr.write(line);
    });

    proc.on("close", (code) => {
      if (code === 0 && stdout.trim()) {
        try {
          const result = JSON.parse(stdout.trim().split("\n").pop());
          resolve(result);
        } catch (e) {
          console.error("Failed to parse miner output:", stdout);
          resolve(null);
        }
      } else if (code !== 0) {
        console.error("Miner exited with code:", code);
        resolve(null);
      } else {
        resolve(null);
      }
    });

    proc.on("error", (err) => {
      console.error("Failed to start miner binary:", err.message);
      console.error("Did you compile it? cd cuda && make");
      reject(err);
    });
  });
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

main().catch((err) => {
  console.error(err.shortMessage || err.message || err);
  process.exit(1);
});

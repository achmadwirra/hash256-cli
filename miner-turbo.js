require("dotenv").config();

const { Worker } = require("worker_threads");
const { ethers } = require("ethers");
const os = require("os");
const path = require("path");

const RPC_URL = process.env.RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const CONTRACT_ADDRESS = "0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc";
const NUM_WORKERS = parseInt(process.env.WORKERS || "0", 10) || os.cpus().length;

const ABI = [
  "function getChallenge(address miner) view returns (bytes32)",
  "function miningState() view returns (uint256 era,uint256 reward,uint256 difficulty,uint256 minted,uint256 remaining,uint256 epoch,uint256 epochBlocksLeft_)",
  "function mine(uint256 nonce)",
];

function requireEnv() {
  if (!RPC_URL || !PRIVATE_KEY) {
    console.error("Isi RPC_URL dan PRIVATE_KEY di file .env dulu.");
    console.error("Contoh: cp .env.example .env lalu edit PRIVATE_KEY.");
    process.exit(1);
  }

  if (!PRIVATE_KEY.startsWith("0x")) {
    console.error("PRIVATE_KEY harus diawali 0x.");
    process.exit(1);
  }
}

function randomBigNonce() {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  let hex = "0x";
  for (const b of bytes) {
    hex += b.toString(16).padStart(2, "0");
  }
  return BigInt(hex);
}

class HashrateTracker {
  constructor() {
    this.totalHashes = 0n;
    this.windowHashes = 0;
    this.windowStart = Date.now();
    this.startTime = Date.now();
  }

  add(count) {
    this.totalHashes += BigInt(count);
    this.windowHashes += count;
  }

  getRate() {
    const elapsed = (Date.now() - this.windowStart) / 1000;
    if (elapsed < 1) return 0;
    const rate = this.windowHashes / elapsed;
    this.windowHashes = 0;
    this.windowStart = Date.now();
    return rate;
  }

  getTotalRate() {
    const elapsed = (Date.now() - this.startTime) / 1000;
    if (elapsed < 1) return 0;
    return Number(this.totalHashes) / elapsed;
  }

  format(rate) {
    if (rate >= 1_000_000) return (rate / 1_000_000).toFixed(2) + " MH/s";
    if (rate >= 1_000) return (rate / 1_000).toFixed(2) + " KH/s";
    return rate.toFixed(0) + " H/s";
  }
}

async function main() {
  requireEnv();

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, wallet);

  console.log("=".repeat(50));
  console.log("HASH256 Multi-Thread Miner");
  console.log("=".repeat(50));
  console.log("Wallet:", wallet.address);
  console.log("Contract:", CONTRACT_ADDRESS);
  console.log("Workers:", NUM_WORKERS);
  console.log("CPU Cores:", os.cpus().length);
  console.log("=".repeat(50));

  while (true) {
    const state = await contract.miningState();
    const difficulty = state.difficulty.toString();
    const challenge = await contract.getChallenge(wallet.address);

    console.log("");
    console.log("Era:", state.era.toString());
    console.log("Reward:", ethers.formatUnits(state.reward, 18), "HASH");
    console.log("Difficulty:", difficulty);
    console.log("Epoch:", state.epoch.toString());
    console.log("Challenge:", challenge);
    console.log(`Mining with ${NUM_WORKERS} workers...`);

    const tracker = new HashrateTracker();
    let found = false;

    const result = await new Promise((resolve) => {
      const workers = [];

      const statsInterval = setInterval(() => {
        const rate = tracker.getRate();
        if (rate > 0) {
          process.stdout.write(
            `\r[${tracker.format(rate)}] Total: ${tracker.totalHashes.toLocaleString()} hashes`
          );
        }
      }, 3000);

      for (let i = 0; i < NUM_WORKERS; i++) {
        const startNonce = randomBigNonce().toString();

        const worker = new Worker(path.join(__dirname, "worker.js"), {
          workerData: {
            challenge,
            difficulty,
            workerId: i,
            startNonce,
            batchSize: 1_000_000,
          },
        });

        worker.on("message", (msg) => {
          if (msg.type === "hashrate") {
            tracker.add(msg.hashes);
          }

          if (msg.type === "found" && !found) {
            found = true;
            clearInterval(statsInterval);

            for (const w of workers) {
              w.terminate();
            }

            resolve(msg);
          }
        });

        worker.on("error", (err) => {
          console.error(`Worker ${i} error:`, err.message);
        });

        workers.push(worker);
      }
    });

    console.log("");
    console.log("");
    console.log(`FOUND by worker ${result.workerId}!`);
    console.log("Nonce:", result.nonce);
    console.log("Hash:", result.hash);

    try {
      const tx = await contract.mine(BigInt(result.nonce));
      console.log("TX sent:", tx.hash);

      const receipt = await tx.wait();
      console.log("Success block:", receipt.blockNumber);
      console.log("Gas used:", receipt.gasUsed.toString());
    } catch (err) {
      console.error("TX failed:", err.shortMessage || err.message);
    }

    console.log("");
    console.log("Fetching next challenge...");
  }
}

main().catch((err) => {
  console.error(err.shortMessage || err.message || err);
  process.exit(1);
});

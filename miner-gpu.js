require("dotenv").config();

const { ethers } = require("ethers");
const { spawn } = require("child_process");
const path = require("path");
const crypto = require("crypto");

const RPC_URL = process.env.RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const CONTRACT_ADDRESS = "0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc";
const MINER_BINARY = path.join(__dirname, "cuda", "hash256_miner");
const BATCH_SIZE = process.env.GPU_BATCH_SIZE || "0";
const GPU_ID = process.env.CUDA_VISIBLE_DEVICES || "0";
const PRIORITY_GWEI = BigInt(process.env.PRIORITY_GWEI || "10");

const ABI = [
  "function getChallenge(address miner) view returns (bytes32)",
  "function miningState() view returns (uint256 era, uint256 reward, uint256 difficulty, uint256 minted, uint256 remaining, uint256 epoch, uint256 epochBlocksLeft_)",
  "function mine(uint256 nonce)",
  "function getNonce(address miner) view returns (uint256)",
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
  console.log("  HASH256 GPU Miner v2 (Optimized)");
  console.log("=".repeat(55));
  console.log("Wallet  :", wallet.address);
  console.log("GPU     :", GPU_ID);
  console.log("Priority:", PRIORITY_GWEI.toString(), "gwei");
  console.log("=".repeat(55));

  let session = 0;
  let consecutiveFails = 0;

  while (true) {
    session++;
    try {
      const [state, challenge, feeData] = await Promise.all([
        contract.miningState(),
        contract.getChallenge(wallet.address),
        provider.getFeeData(),
      ]);

      const difficulty = state.difficulty;
      const diffHex = "0x" + difficulty.toString(16).padStart(64, "0");

      console.log("");
      console.log(`── Round ${session} [${new Date().toLocaleTimeString()}] GPU:${GPU_ID} ──`);
      console.log("Difficulty:", diffHex.slice(0, 20) + "...");
      console.log("Epoch     :", state.epoch.toString(), `(${state.epochBlocksLeft_.toString()} blocks left)`);

      const startNonce = randomNonceHex();

      console.log("Mining...");
      const result = await runGpuMiner(challenge, diffHex, startNonce);

      if (result) {
        console.log(`*** FOUND *** ${result.hashrate} GH/s, ${result.elapsed}s`);

        const nonceBI = BigInt(result.nonce);
        const localHash = ethers.solidityPackedKeccak256(
          ["bytes32", "uint256"],
          [challenge, nonceBI]
        );

        if (BigInt(localHash) >= difficulty) {
          console.error("LOCAL VERIFY FAILED — skipping");
          continue;
        }

        const currentChallenge = await contract.getChallenge(wallet.address);
        if (currentChallenge !== challenge) {
          console.log("Challenge changed — epoch rotated. Next round...");
          continue;
        }

        const boostPriority = PRIORITY_GWEI * 1000000000n;
        const baseFee = feeData.maxFeePerGas || 1000000000n;
        const maxFee = baseFee + boostPriority;

        try {
          const tx = await contract.mine(nonceBI, {
            maxPriorityFeePerGas: boostPriority,
            maxFeePerGas: maxFee,
          });
          console.log(`TX: ${tx.hash}`);

          const receipt = await tx.wait();
          if (receipt.status === 1) {
            console.log(`✅ Block ${receipt.blockNumber} | +${ethers.formatUnits(state.reward, 18)} HASH`);
            consecutiveFails = 0;
          } else {
            console.log("❌ Reverted on-chain");
            consecutiveFails++;
          }
        } catch (err) {
          const msg = err.shortMessage || err.message || "";
          if (msg.includes("revert") || msg.includes("execution")) {
            console.log("Race lost — next round...");
          } else {
            console.error("TX error:", msg);
          }
          consecutiveFails++;
        }

        if (consecutiveFails >= 5) {
          console.log("5 consecutive fails — cooling down 30s...");
          await sleep(30000);
          consecutiveFails = 0;
        }
      }
    } catch (err) {
      console.error("Round error:", err.shortMessage || err.message);
      await sleep(5000);
    }
  }
}

const ROUND_TIMEOUT_MS = parseInt(process.env.ROUND_TIMEOUT || "600") * 1000;

function runGpuMiner(challenge, difficulty, startNonce) {
  return new Promise((resolve, reject) => {
    const args = [challenge, difficulty, startNonce, BATCH_SIZE];
    const proc = spawn(MINER_BINARY, args, {
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let killed = false;

    const timeout = setTimeout(() => {
      killed = true;
      proc.kill("SIGTERM");
      console.log(`\nTimeout (${ROUND_TIMEOUT_MS / 1000}s) — restarting...`);
    }, ROUND_TIMEOUT_MS);

    proc.stdout.on("data", (data) => {
      stdout += data.toString();
    });

    proc.stderr.on("data", (data) => {
      process.stderr.write(data.toString());
    });

    proc.on("close", (code) => {
      clearTimeout(timeout);
      if (killed) {
        resolve(null);
      } else if (code === 0 && stdout.trim()) {
        try {
          const result = JSON.parse(stdout.trim().split("\n").pop());
          resolve(result);
        } catch (e) {
          console.error("Parse error:", stdout);
          resolve(null);
        }
      } else {
        if (code !== 0) console.error("Miner exit code:", code);
        resolve(null);
      }
    });

    proc.on("error", (err) => {
      clearTimeout(timeout);
      console.error("Binary not found:", err.message);
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

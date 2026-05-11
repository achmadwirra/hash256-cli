require("dotenv").config();

const { ethers } = require("ethers");
const { spawn } = require("child_process");
const path = require("path");
const crypto = require("crypto");
const https = require("https");

const RPC_URL = process.env.RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const CONTRACT_ADDRESS = "0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc";
const MINER_BINARY = path.join(__dirname, "cuda", "hash256_miner");
const BATCH_SIZE = process.env.GPU_BATCH_SIZE || "0";
const GPU_ID = process.env.CUDA_VISIBLE_DEVICES || "0";
const PRIORITY_GWEI = BigInt(process.env.PRIORITY_GWEI || "10");
const TG_BOT_TOKEN = process.env.TG_BOT_TOKEN || "";
const TG_CHAT_ID = process.env.TG_CHAT_ID || "";

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

        const [currentChallenge, freshFee] = await Promise.all([
          contract.getChallenge(wallet.address),
          provider.getFeeData(),
        ]);
        if (currentChallenge !== challenge) {
          console.log("Challenge changed — epoch rotated. Next round...");
          continue;
        }

        const boostPriority = PRIORITY_GWEI * 1000000000n;
        const baseFee = freshFee.maxFeePerGas || 1000000000n;
        const maxFee = baseFee + boostPriority;

        try {
          const tx = await contract.mine(nonceBI, {
            maxPriorityFeePerGas: boostPriority,
            maxFeePerGas: maxFee,
          });
          console.log(`TX: ${tx.hash}`);

          const receipt = await tx.wait();
          if (receipt.status === 1) {
            const reward = ethers.formatUnits(state.reward, 18);
            console.log(`✅ Block ${receipt.blockNumber} | +${reward} HASH`);
            sendTelegram(
              `⛏️ <b>Mining Success!</b>\n\n` +
              `+${reward} HASH\n` +
              `Block: ${receipt.blockNumber}\n` +
              `GPU: ${GPU_ID} | ${result.hashrate} GH/s\n` +
              `Time: ${result.elapsed}s\n` +
              `TX: <a href="https://etherscan.io/tx/${tx.hash}">${tx.hash.slice(0, 18)}...</a>`
            );
            consecutiveFails = 0;
          } else {
            console.log("❌ Reverted on-chain");
            consecutiveFails++;
          }
        } catch (err) {
          const msg = err.shortMessage || err.message || "";
          if (msg.includes("revert") || msg.includes("execution")) {
            console.log("Race lost — next round...");
            sendTelegram(`❌ Race lost\nGPU: ${GPU_ID}\nElapsed: ${result.elapsed}s`);
          } else if (msg.includes("nonce") || msg.includes("replacement")) {
            console.log("TX nonce conflict — retrying in 5s...");
            await sleep(5000);
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

const ROUND_TIMEOUT_MS = parseInt(process.env.ROUND_TIMEOUT || "0") * 1000;

function runGpuMiner(challenge, difficulty, startNonce) {
  return new Promise((resolve, reject) => {
    const args = [challenge, difficulty, startNonce, BATCH_SIZE];
    const proc = spawn(MINER_BINARY, args, {
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let killed = false;

    let timeout = null;
    if (ROUND_TIMEOUT_MS > 0) {
      timeout = setTimeout(() => {
        killed = true;
        proc.kill("SIGTERM");
        console.log(`\nTimeout (${ROUND_TIMEOUT_MS / 1000}s) — restarting...`);
      }, ROUND_TIMEOUT_MS);
    }

    proc.stdout.on("data", (data) => {
      stdout += data.toString();
    });

    proc.stderr.on("data", (data) => {
      process.stderr.write(data.toString());
    });

    proc.on("close", (code) => {
      if (timeout) clearTimeout(timeout);
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
      if (timeout) clearTimeout(timeout);
      console.error("Binary not found:", err.message);
      reject(err);
    });
  });
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function sendTelegram(message) {
  if (!TG_BOT_TOKEN || !TG_CHAT_ID) return;
  const url = `https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage`;
  const payload = JSON.stringify({
    chat_id: TG_CHAT_ID,
    text: message,
    parse_mode: "HTML",
  });
  const req = https.request(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) },
  });
  req.on("error", () => {});
  req.write(payload);
  req.end();
}

main().catch((err) => {
  console.error(err.shortMessage || err.message || err);
  process.exit(1);
});

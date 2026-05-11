const { parentPort, workerData } = require("worker_threads");
const { ethers } = require("ethers");

const { challenge, difficulty, workerId, startNonce, batchSize } = workerData;

const diffBigInt = BigInt(difficulty);
let nonce = BigInt(startNonce);
let hashes = 0;
const reportInterval = 50000;

function mine() {
  while (true) {
    const hash = ethers.solidityPackedKeccak256(
      ["bytes32", "uint256"],
      [challenge, nonce]
    );

    hashes++;

    const hashNum = BigInt(hash);

    if (hashNum < diffBigInt) {
      parentPort.postMessage({
        type: "found",
        nonce: nonce.toString(),
        hash,
        workerId,
      });
      return;
    }

    nonce++;

    if (hashes % reportInterval === 0) {
      parentPort.postMessage({
        type: "hashrate",
        hashes: reportInterval,
        workerId,
      });
    }
  }
}

mine();

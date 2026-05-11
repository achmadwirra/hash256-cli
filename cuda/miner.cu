// HASH256 GPU Miner - Main CUDA Kernel
// Brute-forces nonce for: keccak256(challenge || nonce) < difficulty
//
// Build: nvcc -O3 -arch=sm_75 -o hash256_miner miner.cu
// Usage: ./hash256_miner <challenge_hex> <difficulty_hex> <start_nonce_hex> <batch_size>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <cuda_runtime.h>

#include "keccak256.cuh"

// Result structure - GPU writes found nonce here
struct MiningResult {
    uint64_t found;         // 1 if solution found
    uint64_t nonce_lo;      // lower 64 bits of winning nonce
    uint64_t nonce_hi;      // upper 64 bits (we use 128-bit nonce space)
    uint64_t hash[4];       // the winning hash (32 bytes)
};

// Device constants
__device__ __constant__ uint64_t d_challenge[4];    // 32 bytes challenge
__device__ __constant__ uint64_t d_difficulty[4];   // 32 bytes difficulty (target)

// Compare hash < difficulty (big-endian comparison)
// Both are stored as uint64_t[4] in big-endian word order
__device__ __forceinline__ bool hash_less_than_difficulty(const uint64_t* hash, const uint64_t* difficulty)
{
    // Compare from most significant to least significant
    // Note: keccak output is little-endian, difficulty from contract is big-endian
    // We need to compare as big-endian 256-bit numbers
    
    // Byte-swap each uint64 for big-endian comparison
    #pragma unroll
    for (int i = 0; i < 4; i++)
    {
        uint64_t h = __byte_perm(hash[i] >> 32, hash[i], 0x0123);
        h = ((h & 0x00FF00FF00FF00FFULL) << 8) | ((h & 0xFF00FF00FF00FF00ULL) >> 8);
        
        uint64_t d = difficulty[i];
        
        if (h < d) return true;
        if (h > d) return false;
    }
    return false;
}

// Main mining kernel
// Each thread tries one nonce: start_nonce + global_thread_id
__global__ void mine_kernel(
    uint64_t start_nonce_lo,
    uint64_t start_nonce_hi,
    MiningResult* result
)
{
    // Already found? Early exit
    if (result->found) return;

    uint64_t tid = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    
    // Calculate nonce = start_nonce + tid
    uint64_t nonce_lo = start_nonce_lo + tid;
    uint64_t nonce_hi = start_nonce_hi;
    if (nonce_lo < start_nonce_lo) nonce_hi++; // overflow carry

    // Build 64-byte input: challenge (32 bytes) || nonce (32 bytes big-endian)
    uint64_t input[8];
    
    // Challenge bytes (already in correct byte order from contract)
    input[0] = d_challenge[0];
    input[1] = d_challenge[1];
    input[2] = d_challenge[2];
    input[3] = d_challenge[3];
    
    // Nonce as uint256 big-endian (Solidity abi.encodePacked stores uint256 as 32 bytes big-endian)
    // nonce_hi goes first (most significant), then nonce_lo
    // Each uint64 needs to be big-endian byte order
    input[4] = 0;  // upper 128 bits = 0 (we only use 128-bit nonce space)
    input[5] = 0;
    // Swap bytes for big-endian storage
    input[6] = __byte_perm(nonce_hi >> 32, nonce_hi, 0x0123);
    input[6] = ((input[6] & 0x00FF00FF00FF00FFULL) << 8) | ((input[6] & 0xFF00FF00FF00FF00ULL) >> 8);
    input[7] = __byte_perm(nonce_lo >> 32, nonce_lo, 0x0123);
    input[7] = ((input[7] & 0x00FF00FF00FF00FFULL) << 8) | ((input[7] & 0xFF00FF00FF00FF00ULL) >> 8);

    // Compute keccak256
    uint64_t hash[4];
    keccak256_64bytes(input, hash);

    // Check if hash < difficulty
    if (hash_less_than_difficulty(hash, d_difficulty))
    {
        // Atomic check - only first finder wins
        uint64_t old = atomicCAS((unsigned long long*)&result->found, 0ULL, 1ULL);
        if (old == 0)
        {
            result->nonce_lo = nonce_lo;
            result->nonce_hi = nonce_hi;
            result->hash[0] = hash[0];
            result->hash[1] = hash[1];
            result->hash[2] = hash[2];
            result->hash[3] = hash[3];
        }
    }
}

// Helper: parse hex string to uint64 array (big-endian)
void hex_to_uint64(const char* hex, uint64_t* out, int count)
{
    // Skip 0x prefix
    if (hex[0] == '0' && (hex[1] == 'x' || hex[1] == 'X')) hex += 2;
    
    int len = strlen(hex);
    // Pad with leading zeros
    char padded[128] = {0};
    int pad = count * 16 - len;
    if (pad < 0) pad = 0;
    memset(padded, '0', pad);
    memcpy(padded + pad, hex, len);
    
    for (int i = 0; i < count; i++)
    {
        char chunk[17] = {0};
        memcpy(chunk, padded + i * 16, 16);
        out[i] = strtoull(chunk, NULL, 16);
    }
}

// Helper: uint64 array to hex string
void uint64_to_hex(const uint64_t* data, int count, char* out)
{
    out[0] = '0';
    out[1] = 'x';
    int pos = 2;
    for (int i = 0; i < count; i++)
    {
        sprintf(out + pos, "%016llx", (unsigned long long)data[i]);
        pos += 16;
    }
    out[pos] = 0;
}

int main(int argc, char** argv)
{
    if (argc < 4)
    {
        fprintf(stderr, "Usage: %s <challenge_hex> <difficulty_hex> [start_nonce_hex] [batch_size]\n", argv[0]);
        fprintf(stderr, "  challenge_hex:  bytes32 from getChallenge()\n");
        fprintf(stderr, "  difficulty_hex: uint256 from miningState()\n");
        fprintf(stderr, "  start_nonce_hex: starting nonce (default: random)\n");
        fprintf(stderr, "  batch_size: hashes per kernel launch (default: 2^28 = 268M)\n");
        return 1;
    }

    const char* challenge_hex = argv[1];
    const char* difficulty_hex = argv[2];
    const char* start_nonce_hex = argc > 3 ? argv[3] : "0x0";
    uint64_t batch_size = argc > 4 ? strtoull(argv[4], NULL, 10) : (1ULL << 28); // 268M per batch

    // Parse inputs
    uint64_t challenge[4], difficulty[4];
    uint64_t nonce_lo = 0, nonce_hi = 0;
    
    hex_to_uint64(challenge_hex, challenge, 4);
    hex_to_uint64(difficulty_hex, difficulty, 4);
    
    if (argc > 3)
    {
        uint64_t nonce_parts[4];
        hex_to_uint64(start_nonce_hex, nonce_parts, 4);
        nonce_hi = nonce_parts[2];
        nonce_lo = nonce_parts[3];
    }
    else
    {
        // Random start nonce
        FILE* f = fopen("/dev/urandom", "rb");
        if (f) {
            fread(&nonce_lo, 8, 1, f);
            fread(&nonce_hi, 8, 1, f);
            fclose(f);
        }
    }

    // GPU setup
    int device;
    cudaGetDevice(&device);
    cudaDeviceProp props;
    cudaGetDeviceProperties(&props, device);
    
    fprintf(stderr, "=== hash-miner GPU (CUDA) ===\n");
    fprintf(stderr, "GPU       : %s\n", props.name);
    fprintf(stderr, "Challenge : %s\n", challenge_hex);
    fprintf(stderr, "Difficulty: %s\n", difficulty_hex);
    fprintf(stderr, "Batch size: %llu\n", (unsigned long long)batch_size);
    fprintf(stderr, "\n");

    // Copy constants to device
    cudaMemcpyToSymbol(d_challenge, challenge, 32);
    cudaMemcpyToSymbol(d_difficulty, difficulty, 32);

    // Allocate result on device
    MiningResult* d_result;
    MiningResult h_result;
    cudaMalloc(&d_result, sizeof(MiningResult));

    // Kernel launch config
    int threads_per_block = 256;
    int blocks = (int)(batch_size / threads_per_block);
    if (blocks < 1) blocks = 1;

    fprintf(stderr, "Mining started... (Ctrl+C to stop)\n\n");

    uint64_t total_hashes = 0;
    struct timespec start_time, current_time;
    clock_gettime(CLOCK_MONOTONIC, &start_time);

    while (1)
    {
        // Clear result
        memset(&h_result, 0, sizeof(MiningResult));
        cudaMemcpy(d_result, &h_result, sizeof(MiningResult), cudaMemcpyHostToDevice);

        // Launch kernel
        mine_kernel<<<blocks, threads_per_block>>>(nonce_lo, nonce_hi, d_result);
        cudaDeviceSynchronize();

        // Check for CUDA errors
        cudaError_t err = cudaGetLastError();
        if (err != cudaSuccess)
        {
            fprintf(stderr, "CUDA error: %s\n", cudaGetErrorString(err));
            return 1;
        }

        // Check result
        cudaMemcpy(&h_result, d_result, sizeof(MiningResult), cudaMemcpyDeviceToHost);

        total_hashes += batch_size;

        // Calculate hashrate
        clock_gettime(CLOCK_MONOTONIC, &current_time);
        double elapsed = (current_time.tv_sec - start_time.tv_sec) + 
                        (current_time.tv_nsec - start_time.tv_nsec) / 1e9;
        double hashrate = total_hashes / elapsed;

        if (h_result.found)
        {
            // Reconstruct full nonce as hex (uint256)
            char nonce_hex[67], hash_hex[67];
            uint64_t full_nonce[4] = {0, 0, h_result.nonce_hi, h_result.nonce_lo};
            uint64_to_hex(full_nonce, 4, nonce_hex);
            uint64_to_hex(h_result.hash, 4, hash_hex);

            fprintf(stderr, "\n*** SOLUTION FOUND ***\n");
            fprintf(stderr, "Nonce : %s\n", nonce_hex);
            fprintf(stderr, "Hash  : %s\n", hash_hex);
            fprintf(stderr, "Total : %llu hashes\n", (unsigned long long)total_hashes);
            fprintf(stderr, "Time  : %.2f s\n", elapsed);
            fprintf(stderr, "Rate  : %.2f GH/s\n", hashrate / 1e9);

            // Output JSON to stdout for the Node.js wrapper to parse
            printf("{\"nonce\":\"%s\",\"hash\":\"%s\",\"hashrate\":%.2f,\"elapsed\":%.2f}\n",
                   nonce_hex, hash_hex, hashrate / 1e9, elapsed);
            fflush(stdout);

            break;
        }

        // Progress update
        fprintf(stderr, "\rHashes: %llu | Rate: %.2f GH/s | Elapsed: %.1fs",
                (unsigned long long)total_hashes, hashrate / 1e9, elapsed);

        // Advance nonce
        nonce_lo += batch_size;
        if (nonce_lo < batch_size) nonce_hi++; // overflow
    }

    cudaFree(d_result);
    return 0;
}

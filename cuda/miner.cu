#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <cuda_runtime.h>
#include <time.h>

#include "keccak256.cuh"

struct MiningResult {
    uint64_t found;
    uint64_t nonce_lo;
    uint64_t nonce_hi;
    uint64_t hash[4];
};

__device__ __constant__ uint64_t d_challenge[4];
__device__ __constant__ uint64_t d_difficulty[4];

__device__ __forceinline__ uint64_t bswap64(uint64_t x)
{
    uint64_t lo = __byte_perm((uint32_t)x, 0, 0x0123);
    uint64_t hi = __byte_perm((uint32_t)(x >> 32), 0, 0x0123);
    return (lo << 32) | hi;
}

__device__ __forceinline__ bool hash_less_than_difficulty(const uint64_t* hash)
{
    #pragma unroll
    for (int i = 0; i < 4; i++)
    {
        uint64_t h = bswap64(hash[i]);
        uint64_t d = d_difficulty[i];
        if (h < d) return true;
        if (h > d) return false;
    }
    return false;
}

__global__ void mine_kernel(
    uint64_t start_nonce_lo,
    uint64_t start_nonce_hi,
    uint64_t stride,
    MiningResult* result
)
{
    uint64_t tid = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;

    uint64_t nonce_lo = start_nonce_lo + tid * stride;
    uint64_t nonce_hi = start_nonce_hi;
    if (nonce_lo < start_nonce_lo) nonce_hi++;

    uint64_t input[8];
    input[0] = bswap64(d_challenge[0]);
    input[1] = bswap64(d_challenge[1]);
    input[2] = bswap64(d_challenge[2]);
    input[3] = bswap64(d_challenge[3]);
    input[4] = 0;
    input[5] = 0;
    input[6] = bswap64(nonce_hi);
    input[7] = bswap64(nonce_lo);

    uint64_t hash[4];
    keccak256_64bytes(input, hash);

    if (hash_less_than_difficulty(hash))
    {
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

__global__ void mine_kernel_multi(
    uint64_t start_nonce_lo,
    uint64_t start_nonce_hi,
    uint32_t iterations,
    MiningResult* result
)
{
    uint64_t tid = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t total_threads = (uint64_t)gridDim.x * blockDim.x;

    uint64_t nonce_lo = start_nonce_lo + tid;
    uint64_t nonce_hi = start_nonce_hi;
    if (nonce_lo < start_nonce_lo) nonce_hi++;

    uint64_t input[8];
    input[0] = bswap64(d_challenge[0]);
    input[1] = bswap64(d_challenge[1]);
    input[2] = bswap64(d_challenge[2]);
    input[3] = bswap64(d_challenge[3]);
    input[4] = 0;
    input[5] = 0;

    for (uint32_t iter = 0; iter < iterations; iter++)
    {
        if (result->found) return;

        input[6] = bswap64(nonce_hi);
        input[7] = bswap64(nonce_lo);

        uint64_t hash[4];
        keccak256_64bytes(input, hash);

        if (hash_less_than_difficulty(hash))
        {
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
            return;
        }

        nonce_lo += total_threads;
        if (nonce_lo < total_threads) nonce_hi++;
    }
}

void hex_to_uint64(const char* hex, uint64_t* out, int count)
{
    if (hex[0] == '0' && (hex[1] == 'x' || hex[1] == 'X')) hex += 2;

    int len = strlen(hex);
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
    if (argc < 3)
    {
        fprintf(stderr, "Usage: %s <challenge_hex> <difficulty_hex> [start_nonce_hex] [batch_size]\n", argv[0]);
        return 1;
    }

    const char* challenge_hex = argv[1];
    const char* difficulty_hex = argv[2];
    const char* start_nonce_hex = argc > 3 ? argv[3] : "0x0";
    uint64_t batch_size = argc > 4 ? strtoull(argv[4], NULL, 10) : 0;

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
        FILE* f = fopen("/dev/urandom", "rb");
        if (f) {
            fread(&nonce_lo, 8, 1, f);
            fread(&nonce_hi, 8, 1, f);
            fclose(f);
        }
    }

    int device;
    cudaGetDevice(&device);
    cudaDeviceProp props;
    cudaGetDeviceProperties(&props, device);

    int opt_block_size = 0;
    int opt_min_grid = 0;
    cudaOccupancyMaxPotentialBlockSize(&opt_min_grid, &opt_block_size,
        mine_kernel_multi, 0, 0);

    int sm_count = props.multiProcessorCount;
    int max_threads_per_sm = props.maxThreadsPerMultiProcessor;
    int blocks_per_sm = max_threads_per_sm / opt_block_size;
    int total_blocks = sm_count * blocks_per_sm;
    uint64_t total_threads = (uint64_t)total_blocks * opt_block_size;

    uint32_t iterations = 16;
    if (batch_size > 0)
    {
        iterations = (uint32_t)(batch_size / total_threads);
        if (iterations < 1) iterations = 1;
    }
    else
    {
        batch_size = total_threads * iterations;
    }

    fprintf(stderr, "=== HASH256 GPU Miner v2 (Optimized) ===\n");
    fprintf(stderr, "GPU       : %s (%d SMs)\n", props.name, sm_count);
    fprintf(stderr, "Config    : %d blocks x %d threads (%llu total)\n",
            total_blocks, opt_block_size, (unsigned long long)total_threads);
    fprintf(stderr, "Iterations: %u per thread (batch: %llu)\n",
            iterations, (unsigned long long)batch_size);
    fprintf(stderr, "Challenge : %s\n", challenge_hex);
    fprintf(stderr, "Difficulty: %s\n", difficulty_hex);
    fprintf(stderr, "\n");

    cudaMemcpyToSymbol(d_challenge, challenge, 32);
    cudaMemcpyToSymbol(d_difficulty, difficulty, 32);

    MiningResult* d_result;
    MiningResult h_result;
    cudaMalloc(&d_result, sizeof(MiningResult));

    fprintf(stderr, "Mining started...\n\n");

    uint64_t total_hashes = 0;
    struct timespec start_time, current_time;
    clock_gettime(CLOCK_MONOTONIC, &start_time);

    while (1)
    {
        memset(&h_result, 0, sizeof(MiningResult));
        cudaMemcpy(d_result, &h_result, sizeof(MiningResult), cudaMemcpyHostToDevice);

        mine_kernel_multi<<<total_blocks, opt_block_size>>>(
            nonce_lo, nonce_hi, iterations, d_result);
        cudaDeviceSynchronize();

        cudaError_t err = cudaGetLastError();
        if (err != cudaSuccess)
        {
            fprintf(stderr, "CUDA error: %s\n", cudaGetErrorString(err));
            return 1;
        }

        cudaMemcpy(&h_result, d_result, sizeof(MiningResult), cudaMemcpyDeviceToHost);

        total_hashes += batch_size;

        clock_gettime(CLOCK_MONOTONIC, &current_time);
        double elapsed = (current_time.tv_sec - start_time.tv_sec) +
                        (current_time.tv_nsec - start_time.tv_nsec) / 1e9;
        double hashrate = total_hashes / elapsed;

        if (h_result.found)
        {
            char nonce_hex[67], hash_hex[67];
            uint64_t full_nonce[4] = {0, 0, h_result.nonce_hi, h_result.nonce_lo};
            uint64_to_hex(full_nonce, 4, nonce_hex);

            uint64_t hash_be[4];
            for (int i = 0; i < 4; i++) hash_be[i] = bswap64(h_result.hash[i]);
            uint64_to_hex(hash_be, 4, hash_hex);

            fprintf(stderr, "\n*** SOLUTION FOUND ***\n");
            fprintf(stderr, "Nonce : %s\n", nonce_hex);
            fprintf(stderr, "Hash  : %s\n", hash_hex);
            fprintf(stderr, "Total : %llu hashes\n", (unsigned long long)total_hashes);
            fprintf(stderr, "Time  : %.2f s\n", elapsed);
            fprintf(stderr, "Rate  : %.2f GH/s\n", hashrate / 1e9);

            printf("{\"nonce\":\"%s\",\"hash\":\"%s\",\"hashrate\":%.2f,\"elapsed\":%.2f}\n",
                   nonce_hex, hash_hex, hashrate / 1e9, elapsed);
            fflush(stdout);
            break;
        }

        fprintf(stderr, "\rHashes: %llu | Rate: %.2f GH/s | Elapsed: %.1fs",
                (unsigned long long)total_hashes, hashrate / 1e9, elapsed);

        nonce_lo += batch_size;
        if (nonce_lo < batch_size) nonce_hi++;
    }

    cudaFree(d_result);
    return 0;
}

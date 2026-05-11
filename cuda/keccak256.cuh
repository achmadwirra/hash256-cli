// HASH256 GPU Miner - Keccak256 CUDA Implementation
// Optimized for 64-byte input: keccak256(bytes32 challenge || uint256 nonce)

#ifndef KECCAK256_CUH
#define KECCAK256_CUH

#include <stdint.h>

// Keccak-256 round constants
__device__ __constant__ uint64_t RC[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL,
    0x800000000000808AULL, 0x8000000080008000ULL,
    0x000000000000808BULL, 0x0000000080000001ULL,
    0x8000000080008081ULL, 0x8000000000008009ULL,
    0x000000000000008AULL, 0x0000000000000088ULL,
    0x0000000080008009ULL, 0x000000008000000AULL,
    0x000000008000808BULL, 0x800000000000008BULL,
    0x8000000000008089ULL, 0x8000000000008003ULL,
    0x8000000000008002ULL, 0x8000000000000080ULL,
    0x000000000000800AULL, 0x800000008000000AULL,
    0x8000000080008081ULL, 0x8000000000008080ULL,
    0x0000000080000001ULL, 0x8000000080008008ULL
};

// Rotation offsets
#define ROL64(x, n) (((x) << (n)) | ((x) >> (64 - (n))))

__device__ __forceinline__ void keccak_f1600(uint64_t state[25])
{
    uint64_t t, bc[5];

    #pragma unroll
    for (int round = 0; round < 24; round++)
    {
        // Theta
        bc[0] = state[0] ^ state[5] ^ state[10] ^ state[15] ^ state[20];
        bc[1] = state[1] ^ state[6] ^ state[11] ^ state[16] ^ state[21];
        bc[2] = state[2] ^ state[7] ^ state[12] ^ state[17] ^ state[22];
        bc[3] = state[3] ^ state[8] ^ state[13] ^ state[18] ^ state[23];
        bc[4] = state[4] ^ state[9] ^ state[14] ^ state[19] ^ state[24];

        t = bc[4] ^ ROL64(bc[1], 1); state[0] ^= t; state[5] ^= t; state[10] ^= t; state[15] ^= t; state[20] ^= t;
        t = bc[0] ^ ROL64(bc[2], 1); state[1] ^= t; state[6] ^= t; state[11] ^= t; state[16] ^= t; state[21] ^= t;
        t = bc[1] ^ ROL64(bc[3], 1); state[2] ^= t; state[7] ^= t; state[12] ^= t; state[17] ^= t; state[22] ^= t;
        t = bc[2] ^ ROL64(bc[4], 1); state[3] ^= t; state[8] ^= t; state[13] ^= t; state[18] ^= t; state[23] ^= t;
        t = bc[3] ^ ROL64(bc[0], 1); state[4] ^= t; state[9] ^= t; state[14] ^= t; state[19] ^= t; state[24] ^= t;

        // Rho + Pi
        t = state[1];
        state[1]  = ROL64(state[6], 44);
        state[6]  = ROL64(state[9], 20);
        state[9]  = ROL64(state[22], 61);
        state[22] = ROL64(state[14], 39);
        state[14] = ROL64(state[20], 18);
        state[20] = ROL64(state[2], 62);
        state[2]  = ROL64(state[12], 43);
        state[12] = ROL64(state[13], 25);
        state[13] = ROL64(state[19], 8);
        state[19] = ROL64(state[23], 56);
        state[23] = ROL64(state[15], 41);
        state[15] = ROL64(state[4], 27);
        state[4]  = ROL64(state[24], 14);
        state[24] = ROL64(state[21], 2);
        state[21] = ROL64(state[8], 55);
        state[8]  = ROL64(state[16], 45);
        state[16] = ROL64(state[5], 36);
        state[5]  = ROL64(state[3], 28);
        state[3]  = ROL64(state[18], 21);
        state[18] = ROL64(state[17], 15);
        state[17] = ROL64(state[11], 10);
        state[11] = ROL64(state[7], 6);
        state[7]  = ROL64(state[10], 3);
        state[10] = ROL64(t, 1);

        // Chi
        #pragma unroll 5
        for (int j = 0; j < 25; j += 5)
        {
            bc[0] = state[j + 0];
            bc[1] = state[j + 1];
            bc[2] = state[j + 2];
            bc[3] = state[j + 3];
            bc[4] = state[j + 4];
            state[j + 0] ^= (~bc[1]) & bc[2];
            state[j + 1] ^= (~bc[2]) & bc[3];
            state[j + 2] ^= (~bc[3]) & bc[4];
            state[j + 3] ^= (~bc[4]) & bc[0];
            state[j + 4] ^= (~bc[0]) & bc[1];
        }

        // Iota
        state[0] ^= RC[round];
    }
}

// Keccak256 for exactly 64 bytes input (challenge[32] + nonce[32])
// Solidity abi.encodePacked(bytes32, uint256) = 64 bytes
__device__ __forceinline__ void keccak256_64bytes(
    const uint64_t* input,  // 8 x uint64 = 64 bytes
    uint64_t* output        // 4 x uint64 = 32 bytes hash
)
{
    uint64_t state[25];

    // Initialize state to zero
    #pragma unroll
    for (int i = 0; i < 25; i++)
        state[i] = 0;

    // Absorb: XOR 64 bytes of input into state (rate = 136 bytes for keccak256)
    // Input is 64 bytes = 8 uint64s, fits in one block (rate=136 > 64)
    #pragma unroll
    for (int i = 0; i < 8; i++)
        state[i] = input[i];

    // Padding: 0x01 at byte 64, 0x80 at byte 135 (rate-1)
    state[8] ^= 0x0000000000000001ULL;  // pad byte at position 64
    state[16] ^= 0x8000000000000000ULL; // last byte of rate (byte 135)

    // Permute
    keccak_f1600(state);

    // Squeeze: first 32 bytes = 4 uint64s
    #pragma unroll
    for (int i = 0; i < 4; i++)
        output[i] = state[i];
}

#endif // KECCAK256_CUH

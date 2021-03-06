/* Copyright (C) 2013 David G. Andersen. All rights reserved.
 * with modifications by Christian Buchner
 *
 * Use of this code is covered under the Apache 2.0 license, which
 * can be found in the file "LICENSE"
 */

// TODO: attempt V.Volkov style ILP (factor 4)

#ifdef WIN32
#include <windows.h>
#endif
#include <stdio.h>
#include <time.h>
#include <sys/time.h>
#include <unistd.h>
#include <inttypes.h>

#include <cuda.h>

#include "kepler_kernel.h"

// scratchbuf constants (pointers to scratch buffer for each warp, i.e. 32 hashes)
__constant__ uint32_t* c_V[1024];

// using texture references for the "tex" variants of the B kernels
texture<uint4, 1, cudaReadModeElementType> texRef1D_4_V;
texture<uint4, 2, cudaReadModeElementType> texRef2D_4_V;

static const int THREADS_PER_SCRYPT_BLOCK = 4;

/* write_keys writes the 8 keys being processed by a warp to the global
 * scratchpad. To effectively use memory bandwidth, it performs the writes
 * (and reads, for read_keys) 128 bytes at a time per memory location
 * by __shfl'ing the 4 entries in bx to the threads in the next-up
 * thread group. It then has eight threads together perform uint4
 * (128 bit) writes to the destination region. This seems to make
 * quite effective use of memory bandwidth. An approach that spread
 * uint32s across more threads was slower because of the increased
 * computation it required.
 *
 * "start" is the loop iteration producing the write - the offset within
 * the block's memory.
 *
 * Internally, this algorithm first __shfl's the 4 bx entries to
 * the next up thread group, and then uses a conditional move to
 * ensure that odd-numbered thread groups exchange the b/bx ordering
 * so that the right parts are written together.
 *
 * Thanks to Babu for helping design the 128-bit-per-write version.
 *
 * _direct lets the caller specify the absolute start location instead of
 * the relative start location, as an attempt to reduce some recomputation.
 */

__device__ __forceinline__
void write_keys_direct(const uint32_t b[4], const uint32_t bx[4], uint32_t start) {

  uint4 t, t2;
  t.x = b[0]; t.y = b[1]; t.z = b[2]; t.w = b[3];

  int target_thread = (threadIdx.x + 4)%32;
  t2.x = __shfl((int)bx[0], target_thread);
  t2.y = __shfl((int)bx[1], target_thread);
  t2.z = __shfl((int)bx[2], target_thread);
  t2.w = __shfl((int)bx[3], target_thread);

  int t2_start = __shfl((int)start, target_thread) + 4;

  bool c = (threadIdx.x & 0x4);

  uint32_t *scratch = c_V[(blockIdx.x*blockDim.x + threadIdx.x)/(THREADS_PER_SCRYPT_BLOCK * warpSize)];

  int loc = c ? t2_start : start;
  *((uint4 *)(&scratch[loc%(SCRATCH*WU_PER_WARP)])) = (c ? t2 : t);
  loc = c ? start : t2_start;
  *((uint4 *)(&scratch[loc%(SCRATCH*WU_PER_WARP)])) = (c ? t : t2);
}

template <int TEX_DIM> __device__  __forceinline__ void read_keys_direct(uint32_t b[4], uint32_t bx[4], uint32_t start) {

  uint4 t, t2;

  // Tricky bit: We do the work on behalf of thread+4, but then when
  // we steal, we have to steal from (thread+28)%32 to get the right
  // stuff back.
  start = __shfl((int)start, (threadIdx.x & 0x7c)) + 8*(threadIdx.x%4);

  int target_thread = (threadIdx.x + 4)%32;
  int t2_start = __shfl((int)start, target_thread) + 4;

  bool c = (threadIdx.x & 0x4);

  uint32_t *scratch = c_V[(blockIdx.x*blockDim.x + threadIdx.x)/(THREADS_PER_SCRYPT_BLOCK * warpSize)];

  int loc = c ? t2_start : start;
       if (TEX_DIM == 0) t = *((uint4 *)(&scratch[loc%(SCRATCH*WU_PER_WARP)]));
  else if (TEX_DIM == 1) t = tex1Dfetch(texRef1D_4_V, loc/4);
  else if (TEX_DIM == 2) t = tex2D(texRef2D_4_V, 0.5f + (loc%SCRATCH)/4, 0.5f + loc/SCRATCH);
  loc = c ? start : t2_start;
       if (TEX_DIM == 0) t2 = *((uint4 *)(&scratch[loc%(SCRATCH*WU_PER_WARP)]));
  else if (TEX_DIM == 1) t2 = tex1Dfetch(texRef1D_4_V, loc/4);
  else if (TEX_DIM == 2) t2 = tex2D(texRef2D_4_V, 0.5f + (loc%SCRATCH)/4, 0.5f + loc/SCRATCH);

  uint4 tmp = t; t = (c ? t2 : t); t2 = (c ? tmp : t2);
  
  b[0] = t.x; b[1] = t.y; b[2] = t.z; b[3] = t.w;

  int steal_target = (threadIdx.x + 28)%32;

  bx[0] = __shfl((int)t2.x, steal_target);
  bx[1] = __shfl((int)t2.y, steal_target);
  bx[2] = __shfl((int)t2.z, steal_target);
  bx[3] = __shfl((int)t2.w, steal_target);
}


template <int TEX_DIM> __device__  __forceinline__ void read_xor_keys_direct(uint32_t b[4], uint32_t bx[4], uint32_t start) {

  uint4 t, t2;

  // Tricky bit: We do the work on behalf of thread+4, but then when
  // we steal, we have to steal from (thread+28)%32 to get the right
  // stuff back.
  start = __shfl((int)start, (threadIdx.x & 0x7c)) + 8*(threadIdx.x%4);

  int target_thread = (threadIdx.x + 4)%32;
  int t2_start = __shfl((int)start, target_thread) + 4;

  bool c = (threadIdx.x & 0x4);

  uint32_t *scratch = c_V[(blockIdx.x*blockDim.x + threadIdx.x)/(THREADS_PER_SCRYPT_BLOCK * warpSize)];

  int loc = c ? t2_start : start;
       if (TEX_DIM == 0) t = *((uint4 *)(&scratch[loc%(SCRATCH*WU_PER_WARP)]));
  else if (TEX_DIM == 1) t = tex1Dfetch(texRef1D_4_V, loc/4);
  else if (TEX_DIM == 2) t = tex2D(texRef2D_4_V, 0.5f + (loc%SCRATCH)/4, 0.5f + loc/SCRATCH);
  loc = c ? start : t2_start;
       if (TEX_DIM == 0) t2 = *((uint4 *)(&scratch[loc%(SCRATCH*WU_PER_WARP)]));
  else if (TEX_DIM == 1) t2 = tex1Dfetch(texRef1D_4_V, loc/4);
  else if (TEX_DIM == 2) t2 = tex2D(texRef2D_4_V, 0.5f + (loc%SCRATCH)/4, 0.5f + loc/SCRATCH);

  uint4 tmp = t; t = (c ? t2 : t); t2 = (c ? tmp : t2);
  
  b[0] ^= t.x; b[1] ^= t.y; b[2] ^= t.z; b[3] ^= t.w;

  int steal_target = (threadIdx.x + 28)%32;

  bx[0] ^= __shfl((int)t2.x, steal_target);
  bx[1] ^= __shfl((int)t2.y, steal_target);
  bx[2] ^= __shfl((int)t2.z, steal_target);
  bx[3] ^= __shfl((int)t2.w, steal_target);
}


template <int TEX_DIM> __device__  __forceinline__ void read_xor_keys(uint32_t b[4], uint32_t bx[4], uint32_t start) {
  int scrypt_block = (blockIdx.x*blockDim.x + threadIdx.x)/THREADS_PER_SCRYPT_BLOCK;
  start = scrypt_block*SCRATCH + (32*start);
  read_xor_keys_direct<TEX_DIM>(b, bx, start);
}


__device__  __forceinline__ void primary_order_shuffle(uint32_t b[4], uint32_t bx[4]) {
  /* Inner loop shuffle targets */
  int x1_target_lane = (threadIdx.x & 0xfc) + (((threadIdx.x & 0x03)+1)&0x3);
  int x2_target_lane = (threadIdx.x & 0xfc) + (((threadIdx.x & 0x03)+2)&0x3);
  int x3_target_lane = (threadIdx.x & 0xfc) + (((threadIdx.x & 0x03)+3)&0x3);
  
  b[3] = __shfl((int)b[3], x1_target_lane);
  b[2] = __shfl((int)b[2], x2_target_lane);
  b[1] = __shfl((int)b[1], x3_target_lane);
  uint32_t tmp = b[1]; b[1] = b[3]; b[3] = tmp;
  
  bx[3] = __shfl((int)bx[3], x1_target_lane);
  bx[2] = __shfl((int)bx[2], x2_target_lane);
  bx[1] = __shfl((int)bx[1], x3_target_lane);
  tmp = bx[1]; bx[1] = bx[3]; bx[3] = tmp;
}

/*
 * load_key loads a 32*32bit key from a contiguous region of memory in B.
 * The input keys are in external order (i.e., 0, 1, 2, 3, ...).
 * After loading, each thread has its four b and four bx keys stored
 * in internal processing order.
 */

__device__  __forceinline__ void load_key(const uint32_t *B, uint32_t b[4], uint32_t bx[4]) {
  int scrypt_block = (blockIdx.x*blockDim.x + threadIdx.x)/THREADS_PER_SCRYPT_BLOCK;
  int key_offset = scrypt_block * 32;
  uint32_t thread_in_block = threadIdx.x % 4;

  // Read in permuted order. Key loads are not our bottleneck right now.
#pragma unroll 4
  for (int i = 0; i < 4; i++) {
    b[i] = B[key_offset + 4*thread_in_block + (thread_in_block+i)%4];
    bx[i] = B[key_offset + 4*thread_in_block + (thread_in_block+i)%4 + 16];
  }

  primary_order_shuffle(b, bx);
  
}

/*
 * store_key performs the opposite transform as load_key, taking
 * internally-ordered b and bx and storing them into a contiguous
 * region of B in external order.
 */

__device__  __forceinline__ void store_key(uint32_t *B, uint32_t b[4], uint32_t bx[4]) {
  int scrypt_block = (blockIdx.x*blockDim.x + threadIdx.x)/THREADS_PER_SCRYPT_BLOCK;
  int key_offset = scrypt_block * 32;
  uint32_t thread_in_block = threadIdx.x % 4;

  primary_order_shuffle(b, bx);

#pragma unroll 4
  for (int i = 0; i < 4; i++) {
    B[key_offset + 4*thread_in_block + (thread_in_block+i)%4] = b[i];
    B[key_offset + 4*thread_in_block + (thread_in_block+i)%4 + 16] = bx[i];
  }
}


/*
 * salsa_xor_core does the equivalent of the xor_salsa8 loop from
 * tarsnap's implementation of scrypt. The original scrypt called:
 * xor_salsa8(&X[0], &X[16]); <-- the "b" loop
 * xor_salsa8(&X[16], &X[0]); <-- the "bx" loop
 * This version is unrolled to handle both of these loops in a single
 * call to avoid unnecessary data movement.
 */

#define XOR_ROTATE_ADD(dst, s1, s2, amt) { uint32_t tmp = x[s1]+x[s2]; x[dst] ^= ((tmp<<amt)|(tmp>>(32-amt))); }

__device__  __forceinline__ void salsa_xor_core(uint32_t b[4], uint32_t bx[4],
                                 const int x1_target_lane,
                                 const int x2_target_lane,
                                 const int x3_target_lane) {
    uint32_t x[4];

#pragma unroll 4
    for (int i = 0; i < 4; i++) {
      b[i] ^= bx[i];
      x[i] = b[i];
    }

    // Enter in "column" mode (t0 has 0, 4, 8, 12)

#pragma unroll 4
    for (int j = 0; j < 4; j++) {
    
      // Mixing phase of salsa
      XOR_ROTATE_ADD(1, 0, 3, 7);
      XOR_ROTATE_ADD(2, 1, 0, 9);
      XOR_ROTATE_ADD(3, 2, 1, 13);
      XOR_ROTATE_ADD(0, 3, 2, 18);
      
      /* Transpose rows and columns. */
      /* Unclear if this optimization is needed: These are ordered based
       * upon the dependencies needed in the later xors. Compiler should be
       * able to figure this out, but might as well give it a hand. */
      x[1] = __shfl((int)x[1], x3_target_lane);
      x[3] = __shfl((int)x[3], x1_target_lane);
      x[2] = __shfl((int)x[2], x2_target_lane);
      
      /* The next XOR_ROTATE_ADDS could be written to be a copy-paste of the first,
       * but the register targets are rewritten here to swap x[1] and x[3] so that
       * they can be directly shuffled to and from our peer threads without
       * reassignment. The reverse shuffle then puts them back in the right place.
       */
      
      XOR_ROTATE_ADD(3, 0, 1, 7);
      XOR_ROTATE_ADD(2, 3, 0, 9);
      XOR_ROTATE_ADD(1, 2, 3, 13);
      XOR_ROTATE_ADD(0, 1, 2, 18);
      
      x[3] = __shfl((int)x[3], x3_target_lane);
      x[1] = __shfl((int)x[1], x1_target_lane);
      x[2] = __shfl((int)x[2], x2_target_lane);
    }

#pragma unroll 4
    for (int i = 0; i < 4; i++) {
      b[i] += x[i];
      // The next two lines are the beginning of the BX-centric loop iteration
      bx[i] ^= b[i];
      x[i] = bx[i];
    }

    // This is a copy of the same loop above, identical but stripped of comments.
    // Duplicated so that we can complete a bx-based loop with fewer register moves.
#pragma unroll 4
    for (int j = 0; j < 4; j++) {
      XOR_ROTATE_ADD(1, 0, 3, 7);
      XOR_ROTATE_ADD(2, 1, 0, 9);
      XOR_ROTATE_ADD(3, 2, 1, 13);
      XOR_ROTATE_ADD(0, 3, 2, 18);
      
      x[1] = __shfl((int)x[1], x3_target_lane);
      x[3] = __shfl((int)x[3], x1_target_lane);
      x[2] = __shfl((int)x[2], x2_target_lane);
      
      XOR_ROTATE_ADD(3, 0, 1, 7);
      XOR_ROTATE_ADD(2, 3, 0, 9);
      XOR_ROTATE_ADD(1, 2, 3, 13);
      XOR_ROTATE_ADD(0, 1, 2, 18);
      
      x[3] = __shfl((int)x[3], x3_target_lane);
      x[1] = __shfl((int)x[1], x1_target_lane);
      x[2] = __shfl((int)x[2], x2_target_lane);
    }

    // At the end of these iterations, the data is in primary order again.
#undef XOR_ROTATE_ADD

#pragma unroll 4
    for (int i = 0; i < 4; i++) {
      bx[i] += x[i];
    }
}


/*
 * The hasher_gen_kernel operates on a group of 1024-bit input keys
 * in B, stored as:
 * B = { k1B k1Bx k2B k2Bx ... }
 * and fills up the scratchpad with the iterative hashes derived from
 * those keys:
 * scratch { k1h1B k1h1Bx K1h2B K1h2Bx ... K2h1B K2h1Bx K2h2B K2h2Bx ... }
 * scratch is 1024 times larger than the input keys B.
 * It is extremely important to stream writes effectively into scratch;
 * less important to coalesce the reads from B.
 *
 * Key ordering note: Keys are input from B in "original" order:
 * K = {k1, k2, k3, k4, k5, ..., kx15, kx16, kx17, ..., kx31 }
 * After inputting into kernel_gen, each component k and kx of the
 * key is transmuted into a permuted internal order to make processing faster:
 * K = k, kx with:
 * k = 0, 4, 8, 12, 5, 9, 13, 1, 10, 14, 2, 6, 15, 3, 7, 11
 * and similarly for kx.
 */

__global__
void kepler_scrypt_core_kernelA(const uint32_t *d_idata) {

  /* Each thread operates on four of the sixteen B and Bx variables. Thus,
   * each key is processed by four threads in parallel. salsa_scrypt_core
   * internally shuffles the variables between threads (and back) as
   * needed.
   */
  uint32_t b[4], bx[4];

  load_key(d_idata, b, bx);
  
  /* Inner loop shuffle targets */
  int x1_target_lane = (threadIdx.x & 0xfc) + (((threadIdx.x & 0x03)+1)&0x3);
  int x2_target_lane = (threadIdx.x & 0xfc) + (((threadIdx.x & 0x03)+2)&0x3);
  int x3_target_lane = (threadIdx.x & 0xfc) + (((threadIdx.x & 0x03)+3)&0x3);

  int scrypt_block = (blockIdx.x*blockDim.x + threadIdx.x)/THREADS_PER_SCRYPT_BLOCK;
  int start = scrypt_block*SCRATCH + 8*(threadIdx.x%4);

  write_keys_direct(b, bx, start);
  for (int i = 1; i < 1024; i++) {
    salsa_xor_core(b, bx, x1_target_lane, x2_target_lane, x3_target_lane);
    write_keys_direct(b, bx, start+32*i);
  }
}


/*
 * hasher_hash_kernel runs the second phase of scrypt after the scratch
 * buffer is filled with the iterative hashes: It bounces through
 * the scratch buffer in pseudorandom order, mixing the key as it goes.
 */

template <int TEX_DIM> __global__
void kepler_scrypt_core_kernelB(uint32_t *d_odata) {

  /* Each thread operates on a group of four variables that must be processed
   * together. Shuffle between threaads in a warp between iterations.
   */
  uint32_t b[4], bx[4];

  int scrypt_block = (blockIdx.x*blockDim.x + threadIdx.x)/THREADS_PER_SCRYPT_BLOCK;
  int start = scrypt_block*SCRATCH + 8*(threadIdx.x%4);

  read_keys_direct<TEX_DIM>(b, bx, start+32*1023);

  /* Inner loop shuffle targets */
  int x1_target_lane = (threadIdx.x & 0xfc) + (((threadIdx.x & 0x03)+1)&0x3);
  int x2_target_lane = (threadIdx.x & 0xfc) + (((threadIdx.x & 0x03)+2)&0x3);
  int x3_target_lane = (threadIdx.x & 0xfc) + (((threadIdx.x & 0x03)+3)&0x3);

  salsa_xor_core(b, bx, x1_target_lane, x2_target_lane, x3_target_lane);

  for (int i = 0; i < 1024; i++) {

    // Bounce through the key space and XOR the new keys in.
    // Critical thing: (X[16] & 1023) tells us the next slot to read.
    // X[16] in the original is bx[0]
    int slot = bx[0] & 1023;
    read_xor_keys<TEX_DIM>(b, bx, slot);
    salsa_xor_core(b, bx, x1_target_lane, x2_target_lane, x3_target_lane);
  }

  store_key(d_odata, b, bx);
}

KeplerKernel::KeplerKernel() : KernelInterface()
{
}

bool KeplerKernel::bindtexture_1D(uint32_t *d_V, size_t size)
{
    cudaChannelFormatDesc channelDesc4 = cudaCreateChannelDesc<uint4>();
    texRef1D_4_V.normalized = 0;
    texRef1D_4_V.filterMode = cudaFilterModePoint;
    texRef1D_4_V.addressMode[0] = cudaAddressModeClamp;
    checkCudaErrors(cudaBindTexture(NULL, &texRef1D_4_V, d_V, &channelDesc4, size));
    return true;
}

bool KeplerKernel::bindtexture_2D(uint32_t *d_V, int width, int height, size_t pitch)
{
    cudaChannelFormatDesc channelDesc4 = cudaCreateChannelDesc<uint4>();
    texRef2D_4_V.normalized = 0;
    texRef2D_4_V.filterMode = cudaFilterModePoint;
    texRef2D_4_V.addressMode[0] = cudaAddressModeClamp;
    texRef2D_4_V.addressMode[1] = cudaAddressModeClamp;
    checkCudaErrors(cudaBindTexture2D(NULL, &texRef2D_4_V, d_V, &channelDesc4, width, height, pitch));
    return true;
}

bool KeplerKernel::unbindtexture_1D()
{
    checkCudaErrors(cudaUnbindTexture(texRef1D_4_V));
    return true;
}

bool KeplerKernel::unbindtexture_2D()
{
    checkCudaErrors(cudaUnbindTexture(texRef2D_4_V));
    return true;
}

void KeplerKernel::set_scratchbuf_constants(int MAXWARPS, uint32_t** h_V)
{
    // this currently REQUIRES single memory allocation mode (-m 1 flag)
    checkCudaErrors(cudaMemcpyToSymbol(c_V, h_V, MAXWARPS*sizeof(uint32_t*), 0, cudaMemcpyHostToDevice));
}

bool KeplerKernel::run_kernel(dim3 grid, dim3 threads, int WARPS_PER_BLOCK, int thr_id, cudaStream_t stream, uint32_t* d_idata, uint32_t* d_odata, bool interactive, bool benchmark, int texture_cache)
{
    bool success = true;

    // clear CUDA's error variable
    cudaGetLastError();

    // this kernel needs 4 threads per work unit. We scale up the grid x dimension to compensate.
    grid.x *= 4;

    // First phase: Sequential writes to scratchpad.

    kepler_scrypt_core_kernelA<<< grid, threads, 0, stream >>>(d_idata);

    // Optional millisecond sleep in between kernels

    if (!benchmark && interactive) {
        checkCudaErrors(MyStreamSynchronize(stream, 1, thr_id));
#ifdef WIN32
        Sleep(1);
#else
        usleep(1000);
#endif
    }

    // Second phase: Random read access from scratchpad.

    if (texture_cache)
    {
        if (texture_cache == 1)
            kepler_scrypt_core_kernelB<1><<< grid, threads, 0, stream >>>(d_odata);
        else if (texture_cache == 2)
            kepler_scrypt_core_kernelB<2><<< grid, threads, 0, stream >>>(d_odata);
    }
    else
        kepler_scrypt_core_kernelB<0><<< grid, threads, 0, stream >>>(d_odata);

    // catch any kernel launch failures
    if (cudaPeekAtLastError() != cudaSuccess) success = false;

    return success;
}

#ifndef TEST_KERNEL_H
#define TEST_KERNEL_H

#include "salsa_kernel.h"

class TestKernel : public KernelInterface
{
public:
    TestKernel();

    virtual void set_scratchbuf_constants(int MAXWARPS, uint32_t** h_V);
    virtual bool run_kernel(dim3 grid, dim3 threads, int WARPS_PER_BLOCK, int thr_id, cudaStream_t stream, uint32_t* d_idata, uint32_t* d_odata, bool interactive, bool benchmark, int texture_cache);

    virtual char get_identifier() { return 'X'; };
#if __CUDA_ARCH__ >= 350
    virtual int get_major_version() { return 3; };
    virtual int get_minor_version() { return 5; };
#else
    virtual int get_major_version() { return 3; };
    virtual int get_minor_version() { return 0; };
#endif
    virtual int max_warps_per_block() { return 32; };
    virtual int get_texel_width() { return 4; };
    virtual bool no_textures() { return true; };
    virtual bool single_memory() { return true; };
    virtual cudaFuncCache cache_config() { return cudaFuncCachePreferL1; }
};

#endif // #ifndef TEST_KERNEL_H

// Copyright 2004-present Facebook. All Rights Reserved.

#pragma once

#include "cuda/Complex.cuh"
#include "cuda/ComputeCapabilities.cuh"
#include "cuda/CudaUtils.cuh"
#include "cuda/DeviceTensor.cuh"
#include "cuda/fbfft/FBFFTCommon.cuh"
#include "cuda/fbfft/FBFFTParameters.h"
#include "cuda/fbfft/FFT2D32.cuh"
#include "cuda/util/CachedDeviceProperties.h"

#include <cuda_runtime.h>
#include <glog/logging.h>

using namespace facebook::cuda;

namespace facebook { namespace cuda { namespace fbfft {

namespace detail {

template <typename T, int FFTSize, int Dim>
__device__ __forceinline__ void load2D(
    const DeviceTensor<T, Dim>& complex,
    FFT1DCoeffs<FFTSize>& coeffs,
    const int batch,
    const int offsetRow,
    const int indexRow,
    const int indexCol) {
  int LogFFTSize = getMSB(FFTSize);
  // adjustedThreadIdxX<FFTSize>() crams multiple < WARP_SIZE FFTs in a warp
  int col = adjustedThreadIdxX<FFTSize>() + indexCol * blockDim.x;
  // adjustedThreadIdxX<FFTSize>() crams multiple < WARP_SIZE FFTs in a warp
  int row = offsetRow + adjustedThreadIdxY<FFTSize>() + indexRow * blockDim.y;

  assert(FFTSize / 2 + 1 == complex.getSize(1));
  assert(FFTSize == complex.getSize(2));
  assert(col < FFTSize);
  assert(row < FFTSize);

  // IFFT, no need to pad by construction
  if (row < FFTSize / 2 + 1) {
    coeffs[indexCol] = ldg(complex[batch][row][col].template dataAs<Complex>());
  } else {
    int rrow = FFTSize - row;
    int ccol = (FFTSize - col) % FFTSize;
    assert(rrow >= 0);
    assert(rrow < FFTSize / 2 + 1);
    assert(ccol >= 0);
    assert(ccol < FFTSize);
    coeffs[indexCol] =
      ldg(complex
          [batch]
          [rrow]
          [ccol]
          .template dataAs<Complex>()).conjugate();
  }
}

template <typename T, int FFTSize, int Dim>
__device__ __forceinline__ void load2D2a(
    const DeviceTensor<T, Dim>& complex,
    FFT1DCoeffs<FFTSize>& coeffs,
    const int batch,
    const int offsetRow,
    const int indexRow,
    const int indexCol) {
  int LogFFTSize = getMSB(FFTSize);
  // adjustedThreadIdxX<FFTSize>() crams multiple < WARP_SIZE FFTs in a warp
  int col = adjustedThreadIdxX<FFTSize>() + indexCol * blockDim.x;
  // adjustedThreadIdxX<FFTSize>() crams multiple < WARP_SIZE FFTs in a warp
  int row = offsetRow + adjustedThreadIdxY<FFTSize>() + indexRow * blockDim.y;

  assert(FFTSize / 2 + 1 == complex.getSize(1));
  assert(FFTSize == complex.getSize(2));
  assert(col < FFTSize);
  assert(row < FFTSize);

  // IFFT, no need to pad by construction
  if (row < FFTSize / 2 + 1) {
    coeffs[indexCol] = ldg(complex[batch][row][col].template dataAs<Complex>());
  } else {
    int rrow = FFTSize - row;
    int ccol = (FFTSize - col) % FFTSize;
    assert(rrow >= 0);
    assert(rrow < FFTSize / 2 + 1);
    assert(ccol >= 0);
    assert(ccol < FFTSize);
    coeffs[indexCol] =
      ldg(complex
          [batch]
          [rrow]
          [ccol]
          .template dataAs<Complex>()).conjugate();
  }
}

template <typename T, int FFTSize, int Dim>
__device__ __forceinline__ void load2D2b(
    const DeviceTensor<T, Dim>& complex,
    FFT1DCoeffs<FFTSize>& coeffs,
    const int batch,
    const int offsetRow,
    const int indexRow,
    const int indexCol) {
  if (batch < complex.getSize(0)) {
    int LogFFTSize = getMSB(FFTSize);
    // adjustedThreadIdxX<FFTSize>() crams multiple < WARP_SIZE FFTs in a warp
    int col = adjustedThreadIdxX<FFTSize>() + indexCol * blockDim.x;
    // adjustedThreadIdxX<FFTSize>() crams multiple < WARP_SIZE FFTs in a warp
    int row = offsetRow + adjustedThreadIdxY<FFTSize>() + indexRow * blockDim.y;

    assert(FFTSize / 2 + 1 == complex.getSize(1));
    assert(FFTSize == complex.getSize(2));
    assert(col < FFTSize);
    assert(row < FFTSize);

    // IFFT, no need to pad by construction
    if (row < FFTSize / 2 + 1) {
      Complex tmp(ldg(complex[batch][row][col].template dataAs<Complex>()));
      coeffs[indexCol] += Complex(-tmp.im(), tmp.re());
    } else {
      int rrow = FFTSize - row;
      int ccol = (FFTSize - col) % FFTSize;
      assert(rrow >= 0);
      assert(rrow < FFTSize / 2 + 1);
      assert(ccol >= 0);
      assert(ccol < FFTSize);
      Complex tmp(ldg(complex
                      [batch]
                      [rrow]
                      [ccol]
                      .template dataAs<Complex>()).conjugate());
      coeffs[indexCol] += Complex(-tmp.im(), tmp.re());
    }
  }
}

template <int FFTSize>
__device__ __forceinline__ void store2D(
    DeviceTensor<float, 3>& real,
    const FFT1DCoeffs<FFTSize>& coeffs,
    const int batch,
    const int indexCol,
    const int indexRow,
    const int padL,
    const int padU) {
  // adjustedThreadIdxX<FFTSize>() crams multiple < WARP_SIZE FFTs in a warp
  int col = adjustedThreadIdxX<FFTSize>() + indexCol * blockDim.x;
  // adjustedThreadIdxX<FFTSize>() crams multiple < WARP_SIZE FFTs in a warp
  int row = adjustedThreadIdxY<FFTSize>() + indexRow * blockDim.y;
  if (inBounds(row, col, padU, padL, real)) {
    // TODO: try to do something with float4 and shuffles
    real[batch][row - padU][col - padL] = coeffs[indexCol].re();
  }
}

template <int FFTSize, int FFTPerWarp>
__device__ __forceinline__ void store2D2(
    DeviceTensor<float, 3>& real,
    const FFT1DCoeffs<FFTSize>& coeffs,
    const int batch,
    const int indexCol,
    const int indexRow,
    const int padL,
    const int padU) {
  // adjustedThreadIdxX<FFTSize>() crams multiple < WARP_SIZE FFTs in a warp
  int col = adjustedThreadIdxX<FFTSize>() + indexCol * blockDim.x;
  // adjustedThreadIdxX<FFTSize>() crams multiple < WARP_SIZE FFTs in a warp
  int row = adjustedThreadIdxY<FFTSize>() + indexRow * blockDim.y;
  if (inBounds(row, col, padU, padL, real)) {
    // TODO: try to do something with float4 and shuffles
    real[batch][row - padU][col - padL] = coeffs[indexCol].re();
    if (batch + gridDim.x < real.getSize(0)) {
      real[batch + FFTPerWarp * gridDim.x][row - padU][col - padL] =
        coeffs[indexCol].im();
    }
  }
}


template <int FFTSize, int FFTPerWarp, bool BitReverse>
__global__ void decimateInFrequencyInverseHermitian2DWarpKernel(
    DeviceTensor<Complex, 3> src,
    DeviceTensor<float, 3> dst,
    const int padL,
    const int padU) {
  assert(src.getStride(2) == 1);
  assert(dst.getStride(2) == 1);

  cuda_static_assert(!(FFTPerWarp & (FFTPerWarp - 1)));
  cuda_static_assert(FFTPerWarp * FFTSize <= WARP_SIZE);
  // Only let FFTs <= 8 have multiple per warp, 16 and 32 perform better with
  // 1 per warp.
  cuda_static_assert(FFTSize <= 16 || FFTPerWarp == 1);
  assert(FFTPerWarp * FFTSize == blockDim.x);
  assert(src.getSize(0) % FFTPerWarp == 0);

  // Enforce that the number of FFTs we perform is divisible by the number of
  // FFTs per warp, otherwise weird divergence will occur and possibly bugs.
  const int batch = adjustedBatch<FFTSize, FFTPerWarp>();
  assert (batch < src.getSize(0) / 2 + 1);

  FFT1DCoeffs<FFTSize> coeffs;
  __shared__ Complex buffer[WARP_SIZE][WARP_SIZE + 1];

  cuda_static_assert(FFTSize <= WARP_SIZE);

  // Twiddles is the same as for 1D but fully data parallel across threadIdx.y
  FFT1DRoots<FFTSize> roots;
  roots.template twiddles<false>();

  load2D2a<Complex, FFTSize, 3>(src, coeffs, batch, 0, 0, 0);
  load2D2b<Complex, FFTSize, 3>(
    src, coeffs, batch + FFTPerWarp * gridDim.x, 0, 0, 0);

  decimateInFrequency1DWarp<FFTSize>(coeffs[0], roots[0]);
  FFT1DBitReversal<FFTSize> bits;
  if (BitReverse) {
    bits.computeBitReversal(0);
    bitReverse1DWarp<FFTSize, FFTPerWarp>(coeffs, bits, 0);
  }

  if (FFTPerWarp > 1) {
    transpose2DMultiple<FFTSize, WARP_SIZE, 1, FFTPerWarp>(
      coeffs,
      (Complex(*)[WARP_SIZE][WARP_SIZE + 1])buffer);
  } else {
    transpose2D<FFTSize, WARP_SIZE, 1>(
      coeffs,
      (Complex(*)[WARP_SIZE][WARP_SIZE + 1])buffer);
  }

  decimateInFrequency1DWarp<FFTSize>(coeffs[0], roots[0]);
  if (BitReverse) {
    // Bit reversal is the same as for 1D but fully data parallel across
    // threadIdx.y
    bitReverse1DWarp<FFTSize, FFTPerWarp>(coeffs, bits, 0);
  }

  // If needed, could reintroduce the "untranspose" feature but this is
  // expensive for sizes > 32

  store2D2<FFTSize, FFTPerWarp>(dst, coeffs, batch, 0, 0, padL, padU);
}


// First half of the inverse 2-D transform for >= 64.
// Not called for <= 32
// 2-D IFFT after untransposed 2-D FFT
template <int FFTSize, int RowsPerKernel, int BlockDimY, bool BitReverse>
__device__ __forceinline__ void decimateInFrequencyInverse2DKernel(
    DeviceTensor<float, 4> src,
    DeviceTensor<float, 4> dst) {
  assert(src.getStride(2) == 2);
  assert(dst.getStride(2) == 2);
  assert(blockDim.x == WARP_SIZE);
  assert(blockDim.y == BlockDimY);
  assert(src.getSize(0) == dst.getSize(0));
  // This version does not deal with a whole N x N FFT within a single block.
  // It *cannot* update in place transposed -> ensure we have the same
  // dimensions to update one row at a time.
  assert(src.getSize(1) == FFTSize / 2 + 1);
  assert(src.getSize(2) == FFTSize);
  assert(dst.getSize(1) == FFTSize);
  assert(dst.getSize(2) == FFTSize);

  int LogFFTSize = getMSB(FFTSize);
  // Enforce that the number of FFTs we perform is divisible by the number of
  // FFTs per warp, otherwise weird divergence will occur and possibly bugs
  const int batch = adjustedBatch<FFTSize, 1>();
  assert (batch < src.getSize(0) / 2 + 1);

  for (int yiter = 0; yiter < FFTSize; yiter += RowsPerKernel * BlockDimY) {
    FFT1DCoeffs<FFTSize> coeffsArray[RowsPerKernel];
    const int ColumnsPerWarp = coeffsArray[0].ColumnsPerWarp;

    __shared__ Complex buffer[BlockDimY][FFTSize];

    // At this point, the buffer contains data in the form:
    //                          e^-iy (FFTSize of them)
    //       e^-ix         /---------------------------
    // (FFTSize / 2 + 1)   |
    //                     |
    //
    // With Hermitian symmetry 2-D Hermitian symmetry (X_{r,c} = X*_{N-r,N-c})
    // where N-r and N-c are taken modulo N
#pragma unroll
    for (int row = 0; row < RowsPerKernel; ++row) {
#pragma unroll
      for (int reg = 0; reg < ColumnsPerWarp; ++reg) {
        load2D2a<float, FFTSize, 4>(
          src, coeffsArray[row], batch, yiter, row, reg);
        load2D2b<float, FFTSize, 4>(
          src, coeffsArray[row], batch + gridDim.x, yiter, row, reg);
      }
    }

    // At this point, the data is loaded in the form:
    //                          e^-iy (FFTSize of them)
    //       e^-ix         /---------------------------
    // (FFTSize of them)   |
    //                     |
    {
      // Twiddles is the same as for 1D but fully data parallel on threadIdx.y
      FFT1DRoots<FFTSize> roots;
      roots.template twiddles<false>();

      decimateInFrequency1D<FFTSize, 1, RowsPerKernel, 0, RowsPerKernel>(
        coeffsArray, roots, batch);
    }

    if (BitReverse) {
      FFT1DBitReversal<FFTSize> bits;
#pragma unroll
      for (int reg = 0; reg < ColumnsPerWarp; ++reg) {
        bits.computeBitReversal(reg);
      }

      Complex (*buffer2) [FFTSize] = (Complex(*)[FFTSize])buffer;
      // bitReverse all
#pragma unroll
      for (int row = 0; row < RowsPerKernel; ++row) {
#pragma unroll
        for (int reg = 0; reg < ColumnsPerWarp; ++reg) {
          int y = getLaneId() + reg * WARP_SIZE;
          buffer2[threadIdx.y][y] = coeffsArray[row][reg];
        }
#pragma unroll
        for (int reg = 0; reg < ColumnsPerWarp; ++reg) {
          coeffsArray[row][reg] = buffer2[threadIdx.y][bits[reg]];
        }
      }
      // No need to sync up here, no following kernel
    }

    // Store as:
    //                     1^y (FFTSize of them)
    //       e^-ix     /---------------------------
    //     (FFTSize)   |
    //                 |
    // Here we store the whole thing, no symmetry
#pragma unroll
    for (int row = 0; row < RowsPerKernel; ++row) {
      int y = yiter + threadIdx.y + row * blockDim.y;
#pragma unroll
      for (int reg = 0; reg < ColumnsPerWarp; ++reg) {
        int x = threadIdx.x + reg * blockDim.x;
        if (y < dst.getSize(1) && x < dst.getSize(2)) {
          dst[batch][y][x][0].as<Complex>() = coeffsArray[row][reg];
        }
      }
    }
  }
}

// Second half of the 2-D transform for >= 64
// Only transform to be called for <= 32
template <int FFTSize, int RowsPerKernel, int BlockDimY, bool BitReverse>
__device__ __forceinline__ void decimateInFrequencyInverse2DKernel(
    const DeviceTensor<Complex, 3> src,
    DeviceTensor<float, 3> real,
    const int padL,
    const int padU) {
  assert(src.getStride(2) == 1);
  assert(real.getStride(2) == 1);
  assert(blockDim.x == WARP_SIZE);
  assert(blockDim.y == BlockDimY);
  assert(src.getSize(0) == real.getSize(0));
  // This version does not deal with a whole N x N FFT within a single block.
  // It *cannot* update in place transposed -> ensure we are writing to 2
  // different storage areas
  assert(src.dataAs<float>() != real.data());

  int LogFFTSize = getMSB(FFTSize);
  // Enforce that the number of FFTs we perform is divisible by the number of
  // FFTs per warp, otherwise weird divergence will occur and possibly bugs
  const int batch = adjustedBatch<FFTSize, 1>();
  if (batch >= src.getSize(0)) {
    return;
  }

  const int UpperBound = FFTSize;
#pragma unroll
  for (int yiter = 0;
       yiter < UpperBound;
       yiter += RowsPerKernel * BlockDimY) {
    // Split into lower and upper half, upper half will be cut by symmetry
    FFT1DCoeffs<FFTSize> coeffsArray[RowsPerKernel];
    const int ColumnsPerWarp = coeffsArray[0].ColumnsPerWarp;

    __shared__ Complex buffer[BlockDimY][FFTSize];

    // At this point, the buffer contains data in the form
    //                         1^y (FFTSize of them)
    //       e^-ix     /---------------------------
    //     (FFTSize)   |
    //                 |
    // We store the whole thing, no symmetry
#pragma unroll
    for (int row = 0; row < RowsPerKernel; ++row) {
      int x = yiter + threadIdx.y + row * blockDim.y;
#pragma unroll
      for (int reg = 0; reg < ColumnsPerWarp; ++reg) {
        int y = threadIdx.x + reg * blockDim.x;
        // This is the key: uncoalesced, transposed reads using ldg work
        // really well and remove the need for doing an actual transpose.
        coeffsArray[row][reg] = ldg(src[batch][y][x].dataAs<Complex>());
      }
    }

    {
      // Twiddles is the same as for 1D but fully data parallel wrt threadIdx.y
      FFT1DRoots<FFTSize> roots;
      roots.template twiddles<false>();

      decimateInFrequency1D<FFTSize,
                            1,
                            RowsPerKernel,
                            0,
                            RowsPerKernel>(coeffsArray, roots, batch);
    }

    if (BitReverse) {
      {
        FFT1DBitReversal<FFTSize> bits;
#pragma unroll
        for (int reg = 0; reg < ColumnsPerWarp; ++reg) {
          bits.computeBitReversal(reg);
        }

        Complex (*buffer2) [FFTSize] = (Complex(*)[FFTSize])buffer;
        // bitReverse all
#pragma unroll
        for (int row = 0; row < RowsPerKernel; ++row) {
#pragma unroll
          for (int reg = 0; reg < ColumnsPerWarp; ++reg) {
            int x = getLaneId() + reg * WARP_SIZE;
            buffer2[threadIdx.y][x] = coeffsArray[row][reg];
          }
#pragma unroll
          for (int reg = 0; reg < ColumnsPerWarp; ++reg) {
            coeffsArray[row][reg] = buffer2[threadIdx.y][bits[reg]];
          }
        }
        // No need to sync up here, no following smem access
      }
    }


    // FFT is untransposed, this is untransposed -> back to correct order
    // Eventually store the final result
    //                       1^x (FFTSize of them)
    //        1^y       /---------------------------
    //      (FFTSize)   |
    //                  |
#pragma unroll
    for (int row = 0; row < RowsPerKernel; ++row) {
      int rrow = yiter + threadIdx.y + row * blockDim.y;
#pragma unroll
      for (int reg = 0; reg < ColumnsPerWarp; ++reg) {
        int ccol = threadIdx.x + reg * blockDim.x;
        if (inBounds(rrow, ccol, padU, padL, real)) {
          real[batch][rrow - padU][ccol - padL] = coeffsArray[row][reg].re();
          if (batch + gridDim.x < real.getSize(0)) {
            real[batch + gridDim.x][rrow - padU][ccol - padL] =
              coeffsArray[row][reg].im();
          }
        }
      }
    }
  }
}

template <int FFTSize, int RowsPerKernel, int BlockDimY, bool BitReverse>
__launch_bounds__(32 * 32, 2)
__global__ void decimateInFrequencyInverse2DKernel64(
    DeviceTensor<float, 4> src,
    DeviceTensor<float, 4> dst) {
  decimateInFrequencyInverse2DKernel<FFTSize,
                                     RowsPerKernel,
                                     BlockDimY,
                                     BitReverse>(src, dst);
}

template <int FFTSize, int RowsPerKernel, int BlockDimY, bool BitReverse>
 __launch_bounds__(32 * 32, 1)
__global__ void decimateInFrequencyInverse2DKernel128(
    DeviceTensor<float, 4> src,
    DeviceTensor<float, 4> dst) {
  decimateInFrequencyInverse2DKernel<FFTSize,
                                     RowsPerKernel,
                                     BlockDimY,
                                     BitReverse>(src, dst);
}

template <int FFTSize, int RowsPerKernel, int BlockDimY, bool BitReverse>
__launch_bounds__(32 * 32, 2)
__global__ void decimateInFrequencyInverse2DKernel64(
    const DeviceTensor<Complex, 3> src,
    DeviceTensor<float, 3> real,
    const int padL,
    const int padU) {
  decimateInFrequencyInverse2DKernel<FFTSize,
                                     RowsPerKernel,
                                     BlockDimY,
                                     BitReverse>(src, real, padL, padU);
}

template <int FFTSize, int RowsPerKernel, int BlockDimY, bool BitReverse>
__global__ void decimateInFrequencyInverse2DKernel128(
    const DeviceTensor<Complex, 3> src,
    DeviceTensor<float, 3> real,
    const int padL,
    const int padU) {
  decimateInFrequencyInverse2DKernel<FFTSize,
                                     RowsPerKernel,
                                     BlockDimY,
                                     BitReverse>(src, real, padL, padU);
}

} // namespace


// First half of the inverse 2-D transform for >= 64.
// Not called for <= 32
// 2-D IFFT after untransposed 2-D FFT
template <int BatchDims>
FBFFTParameters::ErrorCode fbifft2D(
    DeviceTensor<float, BatchDims + 3>& srcComplexAsFloat,
    DeviceTensor<float, BatchDims + 3>& dstComplexAsFloat,
    cudaStream_t s) {

  initTwiddles();

  if (srcComplexAsFloat.getSize(1) !=
      numHermitian(srcComplexAsFloat.getSize(2)) ||
      srcComplexAsFloat.getSize(2) > 128 ||
      srcComplexAsFloat.getSize(2) < 32) {
    return FBFFTParameters::UnsupportedSize;
  }

#define SELECT_FBFFT_2D_DIF_SINGLE(                                     \
  FFTSize, ROWS_PER_KERNEL, BLOCKDIMY, BIT_REVERSE)                    \
  if (srcComplexAsFloat.getSize(2) == FFTSize) {                       \
    dim3 blocks(ceil(srcComplexAsFloat.getSize(0), 2));                 \
    dim3 threads(32, BLOCKDIMY);                                        \
    detail::decimateInFrequencyInverse2DKernel##FFTSize<               \
      FFTSize,  ROWS_PER_KERNEL, BLOCKDIMY, BIT_REVERSE>               \
      <<<blocks, threads, 0, s>>>(srcComplexAsFloat, dstComplexAsFloat);\
      if (cudaSuccess != cudaPeekAtLastError()) {                       \
        return FBFFTParameters::CudaError;                              \
      }                                                                 \
      return FBFFTParameters::Success;                                  \
  }

  SELECT_FBFFT_2D_DIF_SINGLE(64, 2, 16, true);
  SELECT_FBFFT_2D_DIF_SINGLE(128, 2, 16, true);

  #undef SELECT_FBFFT_2D_DIF_SINGLE
  return FBFFTParameters::UnsupportedSize;
}

// Second half of the 2-D transform for >= 64
// Only transform to be called for <= 32
template <int BatchDims>
FBFFTParameters::ErrorCode fbifft2D(
    DeviceTensor<Complex, BatchDims + 2>& srcComplex,
    DeviceTensor<float, BatchDims + 2>& realDst,
    const int padL,
    const int padU,
    cudaStream_t s) {

  initTwiddles();

  bool inputProperlySizedLE32 =
    srcComplex.getSize(BatchDims + 1) > 32 ||
    (srcComplex.getSize(BatchDims + 1) <= 32 &&
     srcComplex.getSize(BatchDims) !=
     numHermitian(srcComplex.getSize(BatchDims + 1)));
  bool inputProperlySizedGT32 =
    srcComplex.getSize(BatchDims + 1) <= 32 ||
    (srcComplex.getSize(BatchDims + 1) > 32 &&
     srcComplex.getSize(BatchDims) != srcComplex.getSize(BatchDims + 1));
  if ((!inputProperlySizedLE32 && !inputProperlySizedGT32) ||
      srcComplex.getSize(BatchDims + 1) > 128) {
    return FBFFTParameters::UnsupportedSize;
  }

  {
    constexpr int FFTSize = 32;
    constexpr int BatchesPerBlock = 2;
    if (srcComplex.getSize(BatchDims + 1) == FFTSize) {
      CHECK_EQ(1, BatchDims);
      int maxBlocks =
        facebook::cuda::getCurrentDeviceProperties().maxGridSize[0];
      int blx = 1;
      int bly = 1;
      if (realDst.getSize(0) / (BatchesPerBlock) > maxBlocks) {
        blx = maxBlocks;
        bly = ceil(realDst.getSize(0), maxBlocks * BatchesPerBlock);
      } else {
        blx = ceil(realDst.getSize(0), BatchesPerBlock);
      }
      CHECK_LE(1, blx);
      CHECK_LE(1, bly);
      CHECK_LE(blx, maxBlocks);
      CHECK_LE(bly, maxBlocks);
      CHECK_LE(realDst.getSize(0), blx * bly * BatchesPerBlock);
      dim3 blocks(blx, bly);
      dim3 threads(FFTSize, BatchesPerBlock);
      detail::fbifft2DVertical_32<BatchDims, BatchesPerBlock>
        <<<blocks, threads, 0, s>>>(srcComplex, realDst, padL, padU);
      if (cudaSuccess != cudaPeekAtLastError()) {
        return FBFFTParameters::CudaError;
      }
      return FBFFTParameters::Success;
    }
  }

  {
    constexpr int FFTSize = 16;
    constexpr int BatchesPerBlock = 4;
    if (srcComplex.getSize(BatchDims + 1) == FFTSize) {
      CHECK_EQ(1, BatchDims);
      int maxBlocks =
        facebook::cuda::getCurrentDeviceProperties().maxGridSize[0];
      int blx = 1;
      int bly = 1;
      if (realDst.getSize(0) / (BatchesPerBlock) > maxBlocks) {
        blx = maxBlocks;
        bly = ceil(realDst.getSize(0), maxBlocks * BatchesPerBlock);
      } else {
        blx = ceil(realDst.getSize(0), BatchesPerBlock);
      }
      CHECK_LE(1, blx);
      CHECK_LE(1, bly);
      CHECK_LE(blx, maxBlocks);
      CHECK_LE(bly, maxBlocks);
      CHECK_LE(realDst.getSize(0), blx * bly * BatchesPerBlock);
      dim3 blocks(blx, bly);
      dim3 threads(FFTSize, BatchesPerBlock);
      detail::fbifft2DVertical_16<BatchDims, BatchesPerBlock>
        <<<blocks, threads, 0, s>>>(srcComplex, realDst, padL, padU);
      if (cudaSuccess != cudaPeekAtLastError()) {
        return FBFFTParameters::CudaError;
      }
      return FBFFTParameters::Success;
    }
  }

  {
    constexpr int FFTSize = 8;
    constexpr int BatchesPerBlock = 16;
    if (srcComplex.getSize(BatchDims + 1) == FFTSize) {
      CHECK_EQ(1, BatchDims);
      int maxBlocks =
        facebook::cuda::getCurrentDeviceProperties().maxGridSize[0];
      int blx = 1;
      int bly = 1;
      if (realDst.getSize(0) / (BatchesPerBlock) > maxBlocks) {
        blx = maxBlocks;
        bly = ceil(realDst.getSize(0), maxBlocks * BatchesPerBlock);
      } else {
        blx = ceil(realDst.getSize(0), BatchesPerBlock);
      }
      CHECK_LE(1, blx);
      CHECK_LE(1, bly);
      CHECK_LE(blx, maxBlocks);
      CHECK_LE(bly, maxBlocks);
      CHECK_LE(realDst.getSize(0), blx * bly * BatchesPerBlock);
      dim3 blocks(blx, bly);
      dim3 threads(FFTSize, BatchesPerBlock);
      detail::fbifft2DVertical_8<BatchDims, BatchesPerBlock>
        <<<blocks, threads, 0, s>>>(srcComplex, realDst, padL, padU);
      if (cudaSuccess != cudaPeekAtLastError()) {
        return FBFFTParameters::CudaError;
      }
      return FBFFTParameters::Success;
    }
  }

  // TODO: this drops to 1 FFT per warp if batch size is not an even multiple
  // of 2 * FFTS_PER_WARP -> implement kernel and epilogue to handle most
  // cases efficiently.
#define SELECT_FBFFT_2D_DIF_WARP_SINGLE(                                \
  FFTSize, FFTS_PER_WARP, BIT_REVERSE)                                 \
  if (srcComplex.getSize(BatchDims + 1) == FFTSize) {                  \
    if (srcComplex.getSize(0) % (2 * FFTS_PER_WARP) == 0) {             \
      dim3 blocks(ceil(srcComplex.getSize(0), 2 * FFTS_PER_WARP));      \
      /* The factor 2 is already included as Hermitian symmetry */      \
      /* in the implementation -> just multiply by FFTS_PER_WARP */     \
      dim3 threads(FFTSize * FFTS_PER_WARP,                            \
                   FFTSize);                                           \
      detail::decimateInFrequencyInverseHermitian2DWarpKernel<          \
        FFTSize, FFTS_PER_WARP, BIT_REVERSE>                           \
        <<<blocks, threads, 0, s>>>(srcComplex, realDst, padL, padU);   \
    } else {                                                            \
      dim3 blocks(ceil(srcComplex.getSize(0), 2));                      \
      dim3 threads(FFTSize,                                            \
                   FFTSize);                                           \
      detail::decimateInFrequencyInverseHermitian2DWarpKernel<          \
        FFTSize, 1, BIT_REVERSE>                                       \
        <<<blocks, threads, 0, s>>>(srcComplex, realDst, padL, padU);   \
    }                                                                   \
    if (cudaSuccess != cudaPeekAtLastError()) {                         \
      return FBFFTParameters::CudaError;                                \
    }                                                                   \
    return FBFFTParameters::Success;                                    \
  }

#define SELECT_FBFFT_2D_DIF_SINGLE(                                     \
  FFTSize, ROWS_PER_KERNEL, BLOCKDIMY, BIT_REVERSE)                    \
  if (srcComplex.getSize(BatchDims + 1) == FFTSize) {                  \
    dim3 blocks(ceil(srcComplex.getSize(0), 2));                        \
    dim3 threads(32, BLOCKDIMY);                                        \
    detail::decimateInFrequencyInverse2DKernel##FFTSize<               \
      FFTSize,  ROWS_PER_KERNEL, BLOCKDIMY, BIT_REVERSE>               \
      <<<blocks, threads, 0, s>>>(srcComplex, realDst, padL, padU);     \
      if (cudaSuccess != cudaPeekAtLastError()) {                       \
      return FBFFTParameters::CudaError;                                \
    }                                                                   \
    return FBFFTParameters::Success;                                    \
  }

  SELECT_FBFFT_2D_DIF_WARP_SINGLE(2, 16, true);
  SELECT_FBFFT_2D_DIF_WARP_SINGLE(4, 8, true);
  SELECT_FBFFT_2D_DIF_WARP_SINGLE(8, 4, true);
  SELECT_FBFFT_2D_DIF_WARP_SINGLE(16, 2, true);
  SELECT_FBFFT_2D_DIF_WARP_SINGLE(32, 1, true);
  // force 32 registers and unroll outer loop gives best perf
  SELECT_FBFFT_2D_DIF_SINGLE(64, 1, 16, true);
  SELECT_FBFFT_2D_DIF_SINGLE(128, 1, 8, true);

#undef SELECT_FBFFT_2D_DIF_WARP_SINGLE
#undef SELECT_FBFFT_2D_DIF_SINGLE

  LOG(INFO) << "FBIFFT unsupported size: " << srcComplex << \
    " with batchdims = " << BatchDims;
  return FBFFTParameters::UnsupportedSize;
}

} } } // namespace

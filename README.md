## Multi-step LRU

This is a [Nim](https://nim-lang.org) implementation of the paper

> H. Inoue, "Multi-step LRU: SIMD-based Cache Replacement for Lower Overhead and Higher Precision," 2021 IEEE International Conference on Big Data (Big Data), Orlando, FL, USA, 2021, pp. 174-180, doi: 10.1109/BigData52589.2021.9671363. keywords: {Conferences;Memory management;Metadata;Big Data;Throughput;Registers;History;Cache replacement;LRU;SIMD},


 ### Requirements and current Limitations 
 
- this version requires a X64-CPU with AVX2-support. Support for other SIMD-variants (AArch64, RISC-V, AVX10) might be done as soon as i find a suitable dev- and test-environment. So maybe you better do-it-yourself :) There is not much SIMD-intrinsics-code in here. See the intrinsic-operations at the end of Inoues-paper and `./src/util_simd_avx2.nim`
- the supported Cache key- and value-types are `int64` or `uint64` only.
- A zero-value `0` is not a valid key - instead the zero-value represents a deleted-key a.k.a. empty-slot.
- the concurrent-version `-d:multi` uses a naive spin-lock. This might be done more efficiently.

### Compile-Options

- `-d:multi --mm:atomicArc` enables threading-support. `atomicArc` **must** be set.
- `-d:usageOptimization` is a optimization not found in Inoues paper. It does not allow for 'gaps' inside vector-segments. Gaps might occur when elements are deleted from the cache. See the remarks and example in `./src/sizeOptimization.include.nim` to understand how its done.
- `-d:debug` gives detailed step-by-step debug-infos.
- `-d:profile` produces a detailed measurement of operations on the cache.
  

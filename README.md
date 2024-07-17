## Multi-step LRU

This is a pure [Nim](https://nim-lang.org) implementation of this [paper (click to download) : ](https://arxiv.org/pdf/2112.09981.pdf)

> H. Inoue, "Multi-step LRU: SIMD-based Cache Replacement for Lower Overhead and Higher Precision," 2021 IEEE International Conference on Big Data (Big Data), Orlando, FL, USA, 2021, pp. 174-180, doi: 10.1109/BigData52589.2021.9671363. keywords: {Conferences;Memory management;Metadata;Big Data;Throughput;Registers;History;Cache replacement;LRU;SIMD},


 ### Requirements and current Limitations 
 
- this version requires a X64-CPU with AVX2-support. Support for other SIMD-variants (AArch64, RISC-V, AVX10) might be done as soon as i find a suitable dev- and test-environment. So maybe you better do-it-yourself :) There is not much SIMD-intrinsics-code in here. See the intrinsic-operations at the end of the paper and `./src/util_simd_avx2.nim`
- atm the supported Cache key- and value-types are `int64` or `uint64` only.
- a zero-value `0` is not a valid cache-key - instead the zero-value represents a deleted-key a.k.a. empty-slot.
- the concurrent-version `-d:multi` uses a naive spin-lock. This might be done more efficiently.


### Compile-Options

- `-d:multi --mm:atomicArc` enables threading-support. `atomicArc` **must** be set.
- `-d:increaseCacheUsage` activates a usage optimization not found in H. Inoues paper. It does not allow for 'gaps' to appear inside vector-segments. Gapsmight occur when elements are deleted/zeroed from the cache. See remarks and example in `./src/sizeOptimization.include.nim` to understand the idea behind it.
- `-d:debug` gives detailed step-by-step debug-infos.
- `-d:profile` produces a detailed measurement of operations on the `Cache[K,V]` object.


### Compilation

#### single-threaded
    `nim c -d:release ./test/test_multiStepLRU.nim`

#### multi-threaded
    `nim c -d:release -d:multi --mm:atomicArc ./test/test_multiStepLRU.nim`

#### with increased cache usage ( concurrent )
  `nim c -d:release -d:increaseCacheUsage -d:multi --mm:atomicArc ./test/test_multiStepLRU.nim`


### TODO 

- [ ] bench against *a classic/single-threaded* LRU-implementation -> `github.com/jackhftang/lrucache`.
- [ ] find a cache-trace and test/compare against the trace-data.
- [ ] generate a zipfian-distribution and use it during testing.
- [ ] maybe create some MarkDeep-schema.

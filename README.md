## Multi-step LRU

This is a pure [Nim](https://nim-lang.org) implementation of the [paper (click to download) : ](https://arxiv.org/pdf/2112.09981.pdf)

> H. Inoue, "Multi-step LRU: SIMD-based Cache Replacement for Lower Overhead and Higher Precision," 2021 IEEE International Conference on Big Data (Big Data), Orlando, FL, USA, 2021, pp. 174-180, doi: 10.1109/BigData52589.2021.9671363. keywords: {Conferences;Memory management;Metadata;Big Data;Throughput;Registers;History;Cache replacement;LRU;SIMD},


 ### Requirements and current Limitations 
 
- this implementation requires a X64-CPU with AVX2-support. Support for other SIMD-variants (AArch64, RISC-V, AVX512) might be done as soon as i find a suitable dev- and test-environment. So you may decide to do-it-yourself :) There is not much SIMD-intrinsics-code in here. See the intrinsic-operations at the end of the paper and `src/util_simd_avx2.nim`
- atm the supported `Cache[K,V]` key-/value-types are `int64` or `uint64` only.
- a zero-key=`0` represents a deleted-key a.k.a. empty-slot. Thus a zero-key is *not a valid* cache-key.
- the concurrent-version `-d:multi` uses a naive spin-lock. This could be done more efficiently. Lock-byte aligning might prevent false sharing on certain platforms in multithreaded-mode. 


### Compile-Options

- `-d:multi --mm:atomicArc` enables threading-support. `atomicArc` **must** be set.
- `-d:increaseCacheUsage` activates a usage optimization not found in H. Inoues paper. It does not allow for 'gaps' to appear inside vector-segments. Gaps might occur when a member is deleted from the cache via `.delete( key )`. See remarks and example in `./src/sizeOptimization.include.nim` to understand the idea behind it.
- `-d:debug` produces detailed step-by-step debug-infos.
- `-d:profile` produces a detailed measurement of operations on the `Cache[K,V]`.


### Checkout and Compilation

    git clone https://github.com/Asc2011/Multi-step-LRU.git
    cd ./Multi-step-LRU

#### single-threaded
    nim c -d:release ./test/test_multiStepLRU.nim

#### multi-threaded
    nim c -d:release -d:multi --mm:atomicArc ./test/test_multiStepLRU.nim

#### with optimized cache usage ( concurrent )
    nim c -d:release -d:increaseCacheUsage -d:multi --mm:atomicArc ./test/test_multiStepLRU.nim


### Preliminary results

I can not yet reproduce the excellent thruput/hit-ratio numbers from H. Inoues paper. Since Multi-step-LRU does neither require a lock-free Hash-Map nor a lock-free Doubly-Linked-List a 'fair' comparison would stay in single-threaded mode.
From a quick&dirty comparison against *LRUCache* from `github.com/jackhftang/lrucache` i can confirm a gain in thruput around 3-to-5-times during single-threaded mode (see `test/test_lrucache.nim`).    


### TODO 
- [ ] find a cache-trace and test/compare against the trace-data.
- [ ] generate a zipfian-distribution and use it during testing.
- [ ] bench against *a classic/single-threaded* LRU-implementation -> `github.com/jackhftang/lrucache`. Partly done, see `test/test_lrucache.nim`
- [ ] maybe create some MarkDeep-schema.

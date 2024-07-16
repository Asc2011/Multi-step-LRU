## Multi-step LRU

This is a Nim implementation of 

> H. Inoue, "Multi-step LRU: SIMD-based Cache Replacement for Lower Overhead and Higher Precision," 2021 IEEE International Conference on Big Data (Big Data), Orlando, FL, USA, 2021, pp. 174-180, doi: 10.1109/BigData52589.2021.9671363. keywords: {Conferences;Memory management;Metadata;Big Data;Throughput;Registers;History;Cache replacement;LRU;SIMD},


 ### Requirements and current Limitations 
 
- this version requires a X64-CPU with AVX2-support. A ARM/NEON-version will be done as soon as i find a suitable testing environment.
- the supported Cache key- and value-types are `int64` or `uint64` only.
- A zero-value `0` is not a valid key - instead the zero-value represents a deleted-key a.k.a. empty-slot.   

### Compile-Options

- `-d:multi --mm:atomicArc` enables thread-support. `atomicArc` **must** be set.
- `-d:usageOptimization` is a optimization not taken from Inoues paper, but my contribution. It does not allow for 'gaps' inside vector-segments. Gaps occur when elements are deleted from the cache. See the remarks in `./src/sizeOptimization.include.nim`.
- `-d:debug` gives detailed step-by-step debug-infos.
- `-d:profile` produces a detailed measurement of operations on the cache. 

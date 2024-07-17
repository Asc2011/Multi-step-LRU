# TODO: get rid of dependency
# requires NimSIMD updates for :
# - BM1 / BM2
# - cache-line-detection in CPUID
# - maybe more ?
#

static:
  when defined(multi) and not compileOption("mm", "atomicArc") :
    echo "In multi-threaded-mode you MUST use '--mm:atomicArc'."
    quit(1)


import nimsimd/[ avx2 ]
# import murmur3

import std/[
  atomics,
  strformat,
  bitops,
  hashes
]

# TODO: decide the import on avail SIMD-Vector-width
#
import ./util_simd_avx2   #  minimal SIMD-wrappers for AVX2
# TODO: try a NEON-version 'util_simd_neon'

import ./utils            #
export atomics            # TODO: maybe use std/atomics if possible

export avx2
export util_simd_avx2

profile:
  var stat* {.global.} :array[ 8, Atomic[int] ]

# TODO: still needed ?
converter toUint64( x :int64  ) :uint64 = x.uint64
converter toInt64(  x :uint64 ) :int64  = x.int64


# decide upon -d:simd=sse2|avx1/avx2/avx512|neon|arm2 etc.
# on avail. SIMD-vector-width.
# assume at least  a width of 128-bit to be available.
#
when defined(gcc) or defined(clang) :
  {.localPassc: "-mavx2".}

type UArr[T] = UncheckedArray[T]

# FUTURE:  provide the cache-geometry maybe as module-global or the Query-obj needs a reference to the CacheObj.
#

# the Query[K,V]-Object
#
include ./queryObject.include.nim


type
  # TODO: Howto make this a template with dynamic array-length ?
  # FUTURE: bucket-region & locks-region into one allocation..
  KVSets[K,V] = UArr[ tuple[
    ks :array[(64 div K.sizeof), K],    #   keys-bucket = 2 x M256i(32-byte) == 64
    vs :array[(64 div V.sizeof), V]     # values-bucket = 2 x M256i(32-byte) == 64
  ]]


type
  CacheObj[K,V] = object
    cap               :int                        # bucketCount
    vecCount, vecLen  :int                        # associativity e.g. "2x4"
    usage             :Atomic[uint]               # debug/profile only
    ops, hits, misses :uint                       # filler used for cache-metrics
    buckets*          :ptr KVSets[K,V]            # ptr to memory-region for bucket-sets
    when defined( multi ):
      locks           :ptr UArr[ Atomic[bool] ]   # row-of-locks size=(byte..cacheline) per bucket

  Cache*[K,V] = ref CacheObj[K,V]


func capacity*[K,V](       lru :Cache[K,V] ) :int = lru.cap * lru.vecCount * lru.vecLen
func slotCount*[K,V](      lru :Cache[K,V] ) :int = lru.capacity
func bucketCount*[K,V](    lru :Cache[K,V] ) :int = lru.cap
func bucketLength*[K,V](   lru :Cache[K,V] ) :int = lru.vecCount * lru.vecLen
proc len*[K,V](            lru :Cache[K,V] ) :int
proc associativity*[K,V](  lru :Cache[K,V] ) :tuple[ M :int, P :int ] =
  ( lru.vecCount, lru.vecLen )

func setLengthBytes*[K,V]( lru :Cache[K,V] ) :int =
  #
  # length of one Key-/Value-Set in bytes. Must be aligned(64) and
  # setLengthBytes mod 64 == 0
  #
  # FUTURE: alignment on X86-cacheline-width is typically 64-bytes. CPUID/NimSIMD can detect this.
  # On ARM/AppleSillicon its 128-bytes. RISC-V & others ?
  #
  result = ( K.sizeof + V.sizeof ) * ( lru.vecLen * lru.vecCount )
  assert result mod 64 == 0


proc `$`*[K,V]( lru :Cache[K,V] ) :string =
  result = fmt"{lru.vecCount}x{lru.vecLen}-LRU({$K.typeof}:{$V.typeof}) buckets-{lru.cap} slots-{lru.capacity}"
  profile:
    result &= "\n" & fmt"  used-{lru.usage.load}|len-{lru.len} hits-{lru.hits} misses-{lru.misses} ops-{lru.ops}"


when defined( multi ) :
  #
  # spin-lock for multi-threaded-mode
  #
  proc lockBucket*[K,V]( lru :Cache[K,V], bucketIdx :int ) :bool =
    #
    # a naive spin-lock
    #
    while lru.locks[ bucketIdx ].exchange( true ) : discard
    return true

  proc unlockBucket*[K,V]( lru :Cache[K,V], bucketIdx :int ) =
    lru.locks[ bucketIdx ].store false

  proc lockBucket*[K,V]( lru :Cache[K,V], q :var Query[K,V] ) :bool =
    q.lockState = lru.lockBucket q.bucketIdx
    return true

  proc unlockBucket*[K,V]( lru :Cache[K,V], q :var Query[K,V] ) =
    lru.unlockBucket q.bucketIdx
    q.lockState = false
  #
else :
  #
  # no-ops for single-threaded-mode.
  #
  proc lockBucket*[K,V](   lru :Cache[K,V], bucketIdx :int )   :bool = true
  proc lockBucket*[K,V](   lru :Cache[K,V], q :var Query[K,V] ):bool = true
  proc unlockBucket*[K,V]( lru :Cache[K,V], bucketIdx :int )    = discard
  proc unlockBucket*[K,V]( lru :Cache[K,V], q :var Query[K,V] ) = discard


proc vecPts[K,V](   lru :Cache[K,V], bucketIdx :int ) :tuple[ ks :ptr K, vs :ptr V] =
  result = (
    cast[ ptr K ]( lru.buckets[ bucketIdx ].ks.addr ),
    cast[ ptr V ]( lru.buckets[ bucketIdx ].vs.addr )
  )

func getBucketIdx*[K,V](   lru :Cache[K,V], k :K ) :int =
  #result = ( murmur_hash($k)[1].uint mod lru.cap.uint).int     # 3rd/murmur-3
  (k.hash.uint mod lru.cap.uint).int

# TODO: implement rotation-by-pattern

# forward-declarations
#
proc get*[K,V](          lru :Cache[K,V], k :K ) :V
proc getWithQuery[K,V](  lru :Cache[K,V], q :var Query[K,V] ) :V
proc occupiedSlots[K,V]( lru :Cache[K,V] ) :int


proc find[K,V]( lru :Cache[K,V], q :var Query[K,V] ) =
  #
  # the zero-key/'0' represents a empty-slot !
  #
  assert q.needle != 0, "::find got called with a zero-key !"

  q.bucketIdx = lru.getBucketIdx q.needle
  ( q.keyLoc, q.valLoc ) = lru.vecPts( q.bucketIdx )

  multithreaded:
    assert lru.lockBucket( q ), fmt"Could not lock bucket-{q.bucketIdx} ?!"

  dbg: echo fmt"    ::find key-{q.needle} in bucket-{q.bucketIdx}"
  #
  while true :
    q.keyVec = mm256_load_si256 q.keyLoc
    dbg: dump[K]( q.keyVec, fmt"    keys in {q.bucketIdx=}/{q.segmentIdx=}" )
    q.slot   = q.keyVec.has q.needle
    q.found  = q.slot > -1
    if q.found : break
    if q.segmentIdx.succ == lru.vecCount : break

    q.keyLoc += lru.vecLen    # pointer-math here.
    q.valLoc += lru.vecLen    # see ./utils.nim
    q.segmentIdx.inc

  if q.found :
    profile: lru.hits.inc
    dbg: echo fmt"   ::key-{q.needle=} {q.found=} in {q.bucketIdx=} {q.segmentIdx=} {q.slot=}"
    discard
  else :
    q.segmentIdx.dec
    profile: lru.misses.inc
    dbg: echo fmt"   ::key-{q.needle=} {q.found=}"


proc clear*[K,V](   lru :Cache[K,V] ) =
  #
  # clears the entire key- and value-space.
  # PERF: clearing the keys only would be enough.
  #
  dbg: echo fmt"::clear before {lru.occupiedSlots=}"
  system.zeroMem( lru.buckets[0].addr, lru.capacity * (K.sizeof + V.sizeof) )

  assert lru.occupiedSlots == 0, "not all slots cleared ?!"

  multithreaded: system.zeroMem( lru.locks, lru.bucketCount )
  profile: stat.reset

  dbg: echo fmt"/::clear after  {lru.occupiedSlots=}"

# proc reset*[K,V](   lru :Cache[K,V] ) = lru.clear

proc occupiedSlots[K,V]( lru :Cache[K,V] ) :int =
  #
  # ! this is expensive and the result during concurrent-mode
  # gives at best a estimate of the cache-usage !
  #
  var cmpV0, cmpV1: M256i
  var mask :int32

  # PERF: maybe 'unroll'. make this dynamic.
  # this only works for 2 x 4 M256i-vectors.
  #
  for i in 0 ..< lru.bucketCount :
    let
      vpt  = lru.vecPts i
      seg0 = mm256_load_si256 cast[pointer]( vpt.ks )
      seg1 = mm256_load_si256 cast[pointer]( vpt.ks + lru.vecLen )

    cmpV0  = seg0.mm256_cmpgt_epi64 zeroVec
    cmpV1  = seg1.mm256_cmpgt_epi64 zeroVec
    mask   = mm256_movemask_pd( cmpV0.asM256d ) shl 4
    # TODO : BMI1 ?
    result.inc popcount( mask or mm256_movemask_pd cmpV1.asM256d )

proc len*[K,V]( lru :Cache[K,V] ) :int = lru.occupiedSlots


proc has[K,V]( lru :Cache[K,V], k :K ) :bool =
  assert k != 0, "::has got zero-key !"

  dbg: echo "\n" , fmt"::has {k=}"
  var q = Query[K,V]( needle :k, vectorLen :lru.vecLen )
  lru.find q
  lru.unlockBucket( q )
  profile: stat[5].atomicInc
  return q.found

# TODO: rework peek/has/contains

proc contains*[K,V]( lru :Cache[K,V], k :K ) :bool = return lru.has k


proc peek*[K,V](   lru :Cache[K,V], k :K ) :V =
  assert k != 0, "::peek got zero-key !"

  dbg: echo "\n" , fmt"::peek key-{k}"
  var q = Query[K,V]( needle :k, vectorLen :lru.vecLen )
  lru.find q

  if not q.found :
    dbg: echo fmt"/peek key-{k} not in {q.bucketIdx=}"
    lru.unlockBucket( q )
    profile: stat[5].atomicInc
    return

  result = lru.buckets[ q.bucketIdx ].vs[ q.slotIdx ]
  dbg: echo fmt"/peek +found key-{k} in {q.bucketIdx=}/{q.segmentIdx=}/{q.slot=} value-{result}"
  profile: stat[6].atomicInc
  lru.unlockBucket( q )


proc put*[K,V](   lru :Cache[K,V], k :K, v :V ) =
  assert k != 0, "::put got zero-key !"

  dbg: echo "\n" , fmt"::put key-{k} value-{v}"
  var q = Query[K,V]( needle :k, vectorLen :lru.vecLen )
  lru.find q

  if q.found :
    dbg: echo fmt"  update of value-{v} in {q.slot=} of {q.segmentIdx=}"

    # if lru.buckets[ q.bucketIdx ].vs[ q.slotIdx ] != v :
    lru.buckets[ q.bucketIdx ].vs[ q.slotIdx ] = v
    profile: stat[7].atomicInc

    dbg: echo fmt"{q.slot=} after ", ppArr lru.buckets[ q.bucketIdx ].vs

    # TODO: Should a value-update promote/reset the key-position or leave it as is ?
    # unclear, check case if value was changed ?
    when defined( increaseCacheUsage ) :
      #dbg: echo "-d: increaseCacheUsage"
      # the bucket must stay locked !
      discard lru.getWithQuery( q ) # forward for update/promotion.
      return
    else :
      lru.unlockBucket( q )
      return
    #
    #/ end-of if q.found

  # PERF: maybe prefetch( valueVector ) here.
  #

  # key was not found in keys-vector, so we insert on segment-0.MRU
  #
  assert q.segmentIdx == 0, fmt"update on LRU-segment/vector ? {q.segmentIdx=}"
  #
  q.slot   = 0
  q.keyVec = q.keyVec.rotate
  var needleVec = mm256_set_epi64x( 0,0,0,k )
  q.keyVec = q.keyVec.mm256_blend_epi64( needleVec, 1'i32 )

  mm256_store_si256( q.keyLoc, q.keyVec )

  # why this reload ? not needed ...
  #q.keyVec = mm256_load_si256( q.keyLoc )

  dbg: dump[K]( q.keyVec, fmt"  added key-{k} " )
  profile: lru.usage.atomicInc

  var valVec = mm256_load_si256 q.valLoc
  dbg: dump[V]( valVec, "  ::put vals-before " )

  valVec    = valVec.rotate
  needleVec = mm256_set_epi64x( 0,0,0,v )
  valVec    = mm256_blend_pd(
    valVec.asM256d, needleVec.asM256d, 1'u32
  ).asM256i

  mm256_store_si256( q.valLoc, valVec )
  profile: stat[0].atomicInc

  lru.unlockBucket( q )
  dbg:
    dump[V]( valVec, "  ::put vals-after  " )
    echo "  values ", lru.buckets[ q.bucketIdx ].vs.ppArr
    echo "  keys   ", lru.buckets[ q.bucketIdx ].ks.ppArr

  dbg: echo fmt"/put key-{k} val-{v} {q.bucketIdx=} done.."


proc get*[K,V](   lru :Cache[K,V], k :K ) :V =

  assert k != 0, "::get called with zero-key !"

  dbg: echo "\n", fmt"::get  key-{k}"
  var q = Query[K,V]( needle : k, vectorLen : lru.vecLen )
  lru.find q

  if not q.found :
    lru.unlockBucket( q )
    dbg: echo fmt"  key-{k} not in {q.bucketIdx=}"
    profile: stat[5].atomicInc
    return

  return lru.getWithQuery( q )


proc getWithQuery[K,V](   lru :Cache[K,V], q :var Query[K,V] ) :V =

  var valVec :M256i
  let k = q.needle
  # PERF: maybe prefetch the keyVector ?

  dbg: echo fmt"  +found key-{k} in {q.bucketIdx=}/{q.segmentIdx=}/{q.slot}"
  if q.isBucketMRU : #q.slot + q.segmentIdx == 0 :  # q.slotIdx == 0
    #
    # key already sits in MRU-pos, we're done :)
    #
    # benchmark: measure extract from SIMD-Vector
    result = lru.buckets[q.bucketIdx].vs[0]
    lru.unlockBucket( q )
    profile: stat[2].atomicInc  # no mutation, scalar-read
    return
    #
  elif q.isMRU : # q.slot == 0
    #
    # key sits in lower segment.MRU and needs upgrade.
    #
    dbg: echo fmt"  get upgrades key-{k} in {q.segmentIdx=}.mru"
    #
    result = lru.buckets[ q.bucketIdx ].vs[ q.slotIdx ]

    profileAndDebug:
      if result != q.needle.int64 :
        echo fmt"  get upgrades key-{k} in {q.segmentIdx=}.mru {q.slot=}"
        echo "  ::get bad k-" & $q.needle, " val-", $result
        echo lru.buckets[ q.bucketIdx ].ks.ppArr
        echo lru.buckets[ q.bucketIdx ].vs.ppArr
        echo ""

    valVec = mm256_load_si256 q.valLoc
    dbg :
      dump[V]( valVec ,  " vals   ")
      dump[K]( q.keyVec, " keys   ")
      echo "k-before ", ppArr( lru.buckets[ q.bucketIdx ].ks )
      echo "v-before ", ppArr( lru.buckets[ q.bucketIdx ].vs )

    let
      leftSegmentKeyPt = cast[pointer](q.keyLoc - lru.vecLen)
      leftSegmentValPt = cast[pointer](q.valLoc - lru.vecLen)
    var
      leftKeyVec = mm256_load_si256 leftSegmentKeyPt
      leftValVec = mm256_load_si256 leftSegmentValPt

    upgrade( leftKeyVec, q.keyVec )
    upgrade( leftValVec, valVec )
    #
    # stream/store all changed segments-0/1 to memory.
    #
    mm256_store_si256( leftSegmentKeyPt,  leftKeyVec )
    mm256_store_si256( q.keyLoc,          q.keyVec )

    mm256_store_si256( leftSegmentValPt,  leftValVec )
    mm256_store_si256( q.valLoc,          valVec )
    lru.unlockBucket( q )

    profile: stat[3].atomicInc
    #
    dbg :
      dump[K]( q.keyVec, " keys   ")
      dump[V](   valVec, " vals   ")
      echo "k-after  ", lru.buckets[ q.bucketIdx ].ks.ppArr
      echo "v-after  ", lru.buckets[ q.bucketIdx ].vs.ppArr
    #
    return

  elif q.isLRU : # q.slot == 3 for 2x4-Cache
    #
    # key sits in segments' LRU-pos
    # regular rotate-right for key- & value-Vectors
    #
    dbg: echo fmt"  get cheap-insert for key-{k} in {q.segmentIdx=}.lru"
    #
    valVec    = mm256_load_si256  q.valLoc
    q.keyVec  = q.keyVec.rotate
    valVec    = valVec.rotate
    result    = valVec.mm256_extract_epi64 0
    #
    profile: stat[4].atomicInc # get :: rotate
    #
  else :
    #
    # key sits in-between MRU..LRU-pos
    # TODO: shuffle by pattern
    #
    dbg: echo fmt"  in-between for key-{k} {q.slot=} {q.segmentIdx=}.lru"
    valVec   = mm256_load_si256 q.valLoc
    #
    case q.slot
    of 1 :
      #
      # The key is one-off from the MRU-position. So we
      # swap its position-1 with the MRU in position-0.
      #
      q.keyVec.swapLoLane()
      valVec.swapLoLane()
      #
    of 2 :
      #
      valVec.swapHiLane()
      valVec = valVec.rotate
      # DONE: check this ! needed ? no comes afterwards..below
      #result = valVec.mm256_extract_epi64 0
      #
      q.keyVec.swapHiLane()
      q.keyVec = q.keyVec.rotate()
      #
    else :
      echo "   ::get illegal case > 2 ?"
      quit(1)
    #/end-of case q.slot :: in-between 1 and 2
    #
    result = valVec.mm256_extract_epi64 0
    profile: stat[4].atomicInc # rotate & shuffle

  #/end-of if-else
  #
  # finally stream/store key- & value-Vector
  #
  mm256_store_si256( q.keyLoc, q.keyVec )
  mm256_store_si256( q.valLoc, valVec )
  lru.unlockBucket( q )
  #
  dbg:
    echo fmt"  key-{k} {q.slot=} rotates-{q.slot != 0} {result=}"
    dump[K]( q.keyVec, " keys   ")
    dump[V](   valVec, " values ")
    echo "k-after  ", lru.buckets[ q.bucketIdx ].ks.ppArr
    echo "v-after  ", lru.buckets[ q.bucketIdx ].vs.ppArr


proc unset*[K,V]( lru :Cache[K,V], k :K ) =

  dbg: echo fmt"::unset  key-{k}"
  var q = Query[K,V]( needle :k, vectorLen :lru.vecLen )
  lru.find q

  # DONE: wrap in template
  multithreaded:
    var msg = fmt"  ::unset start has open lock ! {q.bucketIdx=}"
    #assert lru.locks[q.bucketIdx].load( Acquire ) == true, msg
    assert lru.locks[q.bucketIdx].load( moAcquire ) == true, msg

  if not q.found :
    dbg: echo fmt"  key-{k} not in {q.bucketIdx=}"
    lru.unlockBucket( q )
    profile: stat[5].atomicInc  # lookup in key-Vector
    return

  profile: stat[1].atomicInc   # TODO: check, maybe double counted ?


  #when compileOption( "opt", "size" ):
  when defined( increaseCacheUsage ) :
    include ./sizeOptimization.include.nim
  else : # -d:increaseCacheUsage NOT set.
    #
    lru.buckets[ q.bucketIdx ].ks[ q.slotIdx ] = 0
    profile: stat[7].atomicInc   # scalar-delete on slot in key-Vector only


  multithreaded:
    msg = fmt"  ::unset has open lock ! {q.bucketIdx=}"
    #assert lru.locks[q.bucketIdx].load( Acquire ) == true, msg
    assert lru.locks[q.bucketIdx].load( moAcquire ) == true, msg

  lru.unlockBucket( q )
  dbg:
    echo fmt"  removed key-{k} from {q.slot=} in {q.bucketIdx=}"
    echo "  vals ", lru.buckets[ q.bucketIdx ].vs.ppArr
    echo "  keys ", lru.buckets[ q.bucketIdx ].ks.ppArr



iterator pairs*[K,V]( lru :Cache[K,V] ) :(K,V) =

  for bkt in 0 ..< lru.bucketCount :
    assert lru.lockBucket( bkt ), "::iterator pairs, could not lock bucket !"
    for i in 0 ..< lru.bucketLength :
      if lru.buckets[ bkt ].ks[i] == 0 : continue
      yield(
        lru.buckets[ bkt ].ks[i],
        lru.buckets[ bkt ].vs[i]
      )
    lru.unlockBucket( bkt )


proc initCache*[K, V]( cap, vecCount, vecLen :int ) :Cache[K,V] =

  let setCount = vecCount * vecLen
  profileAndDebug:
    echo fmt"{cap} x K-{$K.typeof}/V-{$V.typeof}-pairs with {setCount=}"

  assert vecLen * K.sizeof <= 32
  assert vecLen * V.sizeof <= 32
  assert ( setCount * K.sizeof ) mod 64 == 0
  assert ( setCount * V.sizeof ) mod 64 == 0

  var bytes = 0 # 64
  let bucketLen = vecCount * vecLen
  bytes += cap * K.sizeof * bucketLen  # key-space
  bytes += cap * V.sizeof * bucketLen  # value-space
  #multithreaded:
  #  bytes += cap * 1                   # K/V plus lock-space in one alloc ?

  result = new CacheObj[K,V]
  result[].buckets = cast[ ptr KVSets[K,V] ]( allocAligned( bytes, 64 ) )
  
  profileAndDebug:
    echo fmt"{bytes div 1024}-KB key/value-space allocated (aligned=64)."

  let base = cast[int]( result )
  result[].cap        = cap
  result[].vecLen     = vecLen
  result[].vecCount   = vecCount

  multithreaded:
    result[].locks    = cast[ptr UArr[ Atomic[bool] ] ](
      createShared( Atomic[bool], cap )
    )


proc `=destroy`*[K,V]( lru :CacheObj[K,V] ) =
  debugEcho "=destroying -> ", $lru
  multithreaded:
    deallocShared lru.locks
  mm_free lru.buckets

proc `=copy`[K,V]( dest: var CacheObj[K,V]; src: CacheObj[K,V]) {.error.}


proc ppBkt*[K,V]( lru :Cache[K,V], bkt :int, withVals :bool = false ) =
  echo fmt"bkt-{bkt} keys-", lru.buckets[bkt].ks
  if withVals :
    echo fmt"bkt-{bkt} vals-", lru.buckets[bkt].vs


when isMainModule:
  echo "./inoue_mt.nim :: main"
  let lru = initCache[int64, int64]( 128, 2, 4 )
  echo "byte-sizeof Cache ", sizeof(lru), " is aligned ", isAligned( lru[].addr )
  let loc = cast[int]( lru[].cap )
  echo "cap aligned 64 ? ", isAligned lru[].cap.addr
  lru.put( 1, 11 )
  lru.put( 2, 12 )
  echo lru
  let ret = lru.get 1
  echo "return for 1 -> ", ret
  assert ret == 11, fmt" returned value-{ret} expected 11"
  lru.put( 2, 12 )

  echo " expect 11 ? ", lru.get( 1 ) == 11
  lru.unset( 1 )
  echo lru.get( 2 )
  lru.ppBkt 20
  lru.ppBkt 61

  for i in 3..10 :
    lru.put( i.uint64, i*100 )
  echo $lru

  echo " bucket 3 :: "
  lru.put(259, 259)     # 2st
  lru.ppBkt 3
  echo ""
  discard lru.get(4)
  lru.ppBkt 3

  lru.put( 470, 470 )   # 3rd
  lru.ppBkt 3

  #discard lru.get(4)
  #lru.ppBkt 3

  #discard lru.get(4)
  #lru.ppBkt 3

  lru.put( 516, 516 )   # 4th
  lru.ppBkt 3

  lru.put(540, 540)
  lru.ppBkt 3

  echo "remove and shift"
  #lru.unset 540
  #lru.ppBkt 3

  #lru.unset 516
  #lru.ppBkt 3

  lru.unset 470
  lru.ppBkt 3

  #lru.unset 4
  #lru.ppBkt 3

  echo "============="

  discard lru.get 259
  lru.ppBkt 3

  lru.put( 4, 400 )
  lru.ppBkt 3

  discard lru.get 259
  discard lru.get 259
  lru.ppBkt 3

  #assert 259 == lru.peek 259
  #assert 400 == lru.peek 4
  #assert 516 == lru.peek 516
  #assert 470 == lru.peek 470

  discard lru.get(4)
  lru.ppBkt 3

  discard lru.get(470)
  lru.ppBkt 3

  lru.put(540, 540)
  lru.ppBkt 3

  lru.put(884, 884)
  lru.ppBkt 3

  lru.put(887, 887)
  discard lru.get 887
  discard lru.get 887
  lru.ppBkt 3

  discard lru.get 470
  discard lru.get 470
  discard lru.get 470

  discard lru.get 540
  discard lru.get 540
  lru.ppBkt 3

  lru.put(1099, 1099)

  # lru.unset 1099

  #lru.clear()

  echo "\n"
  for i in 2..4 : lru.ppBkt(i, false)

  # var i = 1100
  # while true :
  #   if lru.bucket( i.uint64 ) == 3 :
  #     echo " ", i
  #     break
  #   i.inc

  echo lru
  echo "len-", lru.len, " cap-", lru.cap, " capacity-", lru.capacity, " setLength-", lru.setLengthBytes

  multithreaded:
    for l in 0 ..< lru.cap :
      #echo l, ".lock-", lru.locks[l]
      #assert lru.locks[l] == 0, "locked "
      discard


  echo fmt"typeof {$lru.typeof} "
  #lru[] = nil
  # TODO: should call destroy automatically ?
  # no leaks reported via `leaks`-tool.
  #lru[].`=destroy`()

  echo "done.."


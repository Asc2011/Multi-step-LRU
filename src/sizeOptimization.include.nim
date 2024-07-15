#[
  Cache-Usage-Optimization

  Instead of simply removing a key, and leaving
  a 'gap', like when removing key-3 :

  before: mru-{1 2 3 4}-lru del(3) -> mru-{1 2 0 4}-lru :after

  With the optimization the gap will be closed immediately.
  This promotes all keys to the right of the removed key.
  Costs are one additional register-shuffle plus one register-blend.
  E.g. when removing key-3 :

  before: mru-{1 2 3 4}-lru del(3) -> mru-{1 2 4 0}-lru :after

]#

if q.isLRU : # q.slot == 3 for 2x4-Cache
  #
  # key is in lru-position -> scalar-delete, no rotation
  #
  lru.buckets[ q.bucketIdx ].ks[ q.slotIdx ] = 0
  profile: stat[4].atomicInc  # scalar-write into key-Vector

  lru.unlockBucket( q )
  return

var valVec = mm256_load_si256 q.valLoc

case q.slot
of 0 :
  # mru-position, rotate-left, move slots 1..3
  q.keyVec  = q.keyVec.rotateLeft
  valVec    = valVec.rotateLeft
  #
of 1 :
  # position in-between -> rotate-left, moves slots 2+3
  q.keyVec  = mm256_permute4x64_epi64( q.keyVec, 0b00_11_10_00'u32 )
  valVec    = mm256_permute4x64_epi64(   valVec, 0b00_11_10_00'u32 )
  #
of 2 :
  # position in-between -> rotate-left, moves slot-3 only
  q.keyVec  = mm256_permute4x64_epi64( q.keyVec, 0b10_11_01_00'u32 )
  valVec    = mm256_permute4x64_epi64(   valVec, 0b10_11_01_00'u32 )
  #
else :
  assert false, "::unset with d:size in else."
  quit(1)

profile: stat[4].atomicInc  # operation on key- & value-Vector

# clear LRU.pos in rightmost slot.
#
q.keyVec = q.keyVec.mm256_blend_epi64( zeroVec, 0b10_00 )

mm256_store_si256( q.keyLoc, q.keyVec )
mm256_store_si256( q.valLoc, valVec )
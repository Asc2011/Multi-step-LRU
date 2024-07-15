# DONE: move the Query-Obj into a seperate file or include.
#
##[
A Query-object is created for any operation on the LRU-Cache. A operation always begins with the lookup for a given key. The proc `lru.find( Query )` expects a Query-object that contains the key-to-search-for in `needle`. The bucket, that is supposed to hold `needle` is `bucketIdx`. A bucket in a 2x4-associative Cache is comprised of two segments with four member-slots each. A slot can hold a key or value. In this X86-implementation a segment represents a one-to-one M256i-Vector. `segmentIdx` stores the segment where the given key is supposed to be found. Finally the `slot`-member indicates the position inside the segment/vector. E.g.
  key(67) in segment-1, slot-2 -> { segment-0 : 01 02 03 04 } { segment-1 : 00 11 67 33 }.
  The function-`q.slotIdx()` returns the absolute index - the "bucket-index" of the key. In the example from above `q.slotIdx()` == 6.

A `true` bool in `q.found` indicates a successfull search.
The member `q.keyVec` is the already loaded SIMD-Vector itself. Whereas `keyLoc` is the keys-vector location-in-memory. Accordingly `valLoc` is the values-vector location-in-memory. Since some operations don't require to load/read any values - e.g. a `lru.unset( key )`-operation only removes the key from the keys-vector and does not touch the values-vector at all. Same can be said for a `lru.contains( key )`-operation, asking for the existence of `key`. Reading from the values-vector is not required either.
In contrast `lru.put(key, value)`- and `lru.get( key )`-operations mutate the values-vector.
A segment can be read/written-to either scalar or via a intrinsic vector-operation.
For scalar-reads/-writes the `Cache[K,V]`-object provides the member `buckets`. Given a Query-object with `q.buckeIdx` and a `q.slot` one can access the buckets' keys and values via ´lru.buckets[q.bucketIdx].ks[q.slotIdx]´ and ´lru.buckets[q.bucketIdx].vs[q.slotIdx]´.
To perform intrinsic operations on a SIMD-vector like `rotateLeft`, `blend`, `rotate`, or a `shuffle`, only the values-vector needs to be loaded from its memory-location. The keys-vector is guaranteed to be availiable inside the Query-object.
The query gets passed around until either a update on one or both vectors is performed or the operation failed.
In multi-threaded-mode, the Query-object contains a additional member `lockState`. Tt indicates that the bucket `bucketIdx` is locked=`true` or not=`false`. It is a copy of the current state of the atomic-spin-lock from the `lru.locks`-array. Since it happens so easily to forget about unlocking, this copy of the lock-state-of the bucket is checked before the Query-object will be released. Thus a `q.lockState=true` in the destructor must always be wrong and is fatal/aborts during debug-mode.
Every bucket has a MRU- and a LRU-position. And every segment has a MRU-/LRU-position as well (see Inoues-paper). A call to `q.isBucketMRU()` returns `true` for the left-most position=0 in segment=0. This is equal to `q.slotIdx()` == 0.
A MRU-position is always a first-slot in some segment. And it is the bucketMRU-position, if the key happens-to-be found in segment-0 of the bucket. So `q.isMRU()` returns `true` for any key found in a left-most slot of some-segment. Analog `q.isLRU()` reports `true` if the key was found in a right-most slot.
]##


type
  Query*[K,V] = object
    needle                      :K        # the key, that we are searching for.
    bucketIdx, segmentIdx, slot :int      # position in bucket/segment=SIMD-Vector/slot
    vectorLen                   :int      # width of vector. A M256i on X86 can hold 4xInt64.
    keyVec                      :M256i    # the keys-Vector where `needle` is supposed to exist.
    keyLoc                      :ptr K    # memory-address of keys-Vector
    valLoc                      :ptr V    # memory-address of values-Vector
    found                       :bool     # if `needle` was found in 'keyVec' or not.
    when defined( multi ):
      lockState                 :bool     # lock-state of the bucket. (only multi-threaded-mode)

multithreaded:
  # paranoid check of lock-state on exit.
  proc `=destroy`[K,V]( q :Query[K, V] ) =
    if q.lockState == true :
      echo fmt"  Query.destroy {q.bucketIdx=} seems still locked ?"
      quit(1)

profileAndDebug:
  proc `$`*[K, V]( q :Query[K,V] ) :string =
    if q.found :
      fmt"+ Query[{$K.typeof}] '{q.needle}' ->  bkt/segment/slot {q.bucketIdx}/{q.segmentIdx}/{q.slot}"
    else :
      fmt"- Query[{$K.typeof}] '{q.needle}' -> {q.found}"


# DONE: wording maybe 'slot-index in bucket' ? -> explained see text above.
#
func slotIdx*[K,V]( q :Query[K,V] ) :int = (q.segmentIdx * q.vectorLen) + q.slot

func isMRU*[K,V]( q :Query[K,V] ) :bool = q.slot == 0
func isLRU*[K,V]( q :Query[K,V] ) :bool = q.slot == q.vectorLen.pred

# DONE: clarify segmentIdx / bucketIdx and slot / slotIdx
#
#func isSegmentMRU*[K,V]( q :Query[K,V] ) :bool = q.slot == 0
#func isSegmentLRU*[K,V]( q :Query[K,V] ) :bool = q.slot == q.vectorLen.pred

#func isBucketMRU*[K,V]( q :Query[K,V] ) :bool = q.segmentIdx == 0 and q.slotIdx = 0
func isBucketMRU*[K,V]( q :Query[K,V] ) :bool = q.segmentIdx + q.slot == 0

# TODO: missing P here, ... not needed ?
# func isBucketLRU() :bool = q.slotIdx ==

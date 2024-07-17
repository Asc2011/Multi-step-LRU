
import std/[
  monotimes,
  unicode,
  random,
  sets,
  bitops,
  sequtils,
  #strutils,
  strformat,
  math
]

# TODO: maybe change to std/atomics
# import threading/atomics

import ../src/multiStepLRU
import ../src/prettyPrint


template dbg*( body :untyped ) :untyped =
  when defined( debug ) :
    body

template single*( tc :int, body :untyped ) :untyped =
  if tc > 1 : discard
  else :
    body

randomize(678)

func tics() :int64 = getMonoTime().ticks

type tstat = array[8, int]

var
  threadCount {.global.} :int

  ds        :Cache[int64, int64]
  slots     :Atomic[int]  # = Atomic[int](1)  # TODO: ugly, howto init a std/atomics ?
 
  thr       :array[ 16, Thread[int] ] # thread-array
  stats     :array[ 16, tstat ]       # results-array

  # thread-local vars
  thId*    {.threadvar.} :int
  thValues {.threadvar.} :seq[int]
  thTime   {.threadvar.} :array[2, int64]
  inCache  {.threadvar.} :HashSet[int64]

slots.store 1

proc mkSet( s :int ) :HashSet[int] =
  while result.len <= s :
    result.incl rand( s * 2 )
  if 0 in result : result.excl 0   # A zero represents a empty Cache-slot !


proc th_work( setLen :int ) {.thread.} =

  thId = slots.fetchAdd(1)

  {.gcsafe.}:
    thValues = mkSet( setLen ).toSeq
    echo fmt"thread-{thId} thValues.len-{thValues.len.sep} head-{$thValues[0] }"

    var 
      turns :int            # no of turns
      thOps :tstat          # thread operations-counter
      tOps  :seq[ tstat ]   #

    while true :
      shuffle thValues
      thTime[0] = tics()

      for v in thValues :
        let operation = sample @[ "put", "get", "unset", "peek", "update" ]
        #echo thId," operation-", operation, " value-", v

        case operation
        of "put" :
          ds.put( v, v )
          inCache.incl v
          thOps[1].inc
          single( threadCount ) :
            if ds.peek(v) != v : echo thId, " ! maybe bad write ?"

        of "get" :
          if v notin ds :
            ds.put(v,v)
            thOps[1].inc
            inCache.incl v

          let retries = v mod 4
          for r in 1 .. retries :
            thOps[2].inc
            let vv = ds.get v
            if vv > 0 :
              if vv != v :
                echo fmt" ! thread-{thId} retry-{r} key-{v} != value-{vv}"
          if retries == 3 :
            ds.unset v
            thOps[3].inc
            inCache.excl v

        of "unset" :
          if inCache.card > 0 :
            let k = inCache.pop
            ds.unset k

            thOps[3].inc
            single( threadCount ) :
              if k in ds :
                echo threadCount, " ?? not removed-" & $k
                echo "val-", ds.peek( k )
                let bkt = ds.getBucketIdx(k)
                echo $ds.buckets[ bkt ].ks.toSeq
                echo $ds.buckets[ bkt ].vs.toSeq
                quit(1)
          else :
            ds.put( v, v )
            thOps[1].inc
            single( threadCount ) :
              if v notin ds : echo " ?? not inserted-" & $v

        of "peek" :
          discard ds.peek( v )
          thOps[4].inc

        of "update" :
          if inCache.card > 0 :
            let tmp = inCache.pop
            ds.put( tmp, tmp )
            thOps[5].inc
          else :
            for i in 0 .. rand(2) :
              let vv = ds.get v
              if vv == 0 : break
              thOps[2].inc


      turns.inc
      thTime[1] = tics()
      thOps[7]  = thTime[1] - thTime[0]
      thOps[0]  = sum thOps[ tstat.low.succ ..< tstat.high ]
      tOps.add thOps
      thOps.reset
      if turns == 4 :
        # echo "thread-",thId, " inCache.len-", inCache.card
        inCache.clear
        break
    
    # simple stat-aggregate
    #
    var st :tstat
    for probe in tOps :
      for x in 0..7 : st[x] += probe[x]
    for x in 0 ..< tstat.high : st[x] = st[x] div turns
    stats[thId] = st


proc checkCache[K,V]( lru :Cache[K,V] ) =
  #
  # walks all buckets in Cache[K,V] and tests for :
  #   (1) expect `key == value` in every occupied slots.
  #   (2) existence of key-doubles in every bucket.
  #
  var corrupt, slots, usedByCount :int
  var doubles :HashSet[K]

  for i in 0 ..< lru.bucketCount :
    for j in 0 ..< lru.bucketLength :
      slots.inc
      let key = lru.buckets[ i ].ks[ j ]
      if key == 0 : continue
      if key in doubles :
        let bucketIdx = lru.getBucketIdx key
        echo "  doublette in bkt-", bucketIdx, " key-", key
        echo "  ", lru.buckets[ bucketIdx ].ks.toSeq
        echo "  ", lru.buckets[ bucketIdx ].vs.toSeq
      else :
        doubles.incl key
      usedByCount.inc
      let val = lru.buckets[ i ].vs[ j ]
      if val != key :
        echo fmt"! corrupt in bkt-{i} got '{val}' for key-'{key}'"
        corrupt.inc

  let usedSlots = lru.len   # walks SIMD-vectors
  echo fmt"slots-{slots.sep}({usedByCount * 100 div slots}%-usage) {corrupt}-corrupt. counted-{usedByCount.sep}={usedByCount==usedSlots}={usedSlots.sep}-reported"


proc ppStats( arr :var array[8, Atomic[int] ] ) =
  let msgs = @[
    "put",
    "unset",
    "get :: just read -> mru.segment == slot == 0",
    "get :: upgrade/promote -> mru.segment > 0 slot==0",
    "get :: rotate | shuffle -> slot > 0",
    "lookup/keys -> (not)-found in put|get|unset|peek",
    "read/values -> found in get|peek",
    "write/value -> single/scalar update -> put"
  ]
  var su :int
  for i in 0 .. arr.high :
    let (msg, val) = ( msgs[i], arr[i].exchange(0) )
    echo fmt"{val.sep 9} x {msg}"
    su.inc val
  echo "============================================"
  echo fmt"{su.sep 9} total-operations"


proc test_cache( setLen :int, tc :int = 1 ) =
  echo "\n" & fmt"test '{$ds.typeof}' threads-{tc} dataSet={setLen.sep}"
  let t0 = tics()  
  for i in 1 .. tc :
    createThread( thr[i], th_work, setLen )
  joinThreads thr

  let t = (tics() - t0) div 1_000_000           # totalTime
  var ops, tht :int
  for x in 1 .. tc : ops += stats[x][tstat.low]   # sum-of-operations
  # tht is threadTime :
  #   totalTime - time spent for shuffling-of-values in proc.th_work
  for x in 1 .. tc :
    tht += stats[x][tstat.high]  # threads-time-share(s)
    echo fmt"  thread-{x} time-{ stats[x][tstat.high].sep }"
  tht = ( tht div 1_000_000 ) div tc

  echo fmt"totalTime {t}-ms({tht}-thread) {(tht * 100 div t)}-%"
  echo fmt"{tc}-threads {ops.sep}-ops {t}-ms | {ops div t}-op/ms"

  profile:
    echo "\n", $ds
    multiStepLRU.stat.ppStats

  dbg:
    var x = 25
    for (k,v) in ds.pairs :
      echo fmt"{(25-x).sep 3}. ( {k.sep 10}-key : {v.sep 10}.value )"
      x.dec
      if x == 0 : break
    echo ""

  ds.checkCache # paranoid consistency-test of all key/value-pairs
  ds.clear
  assert ds.len == 0, "not all slots cleared ?"
 

when isMainModule:

  let cacheSize =    20_000 # 2x4 = times 8 => slotCount 160_000
  let setSize   = 1_000_000 # size of data-set, will be 4-times in th_work
  threadCount   = 4

  ds = initCache[int64, int64]( cacheSize, 2, 4 )
  echo fmt"Test of '{$ds.typeof}' setSize-{cacheSize}"

  when defined( multi ) :
    for tc in 1 .. threadCount :
      test_cache( setSize, tc )
      slots.store 1
  else :
    test_cache( setSize, 1 )
    slots.store 1

  echo $ds

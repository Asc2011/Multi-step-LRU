
import std/[
  monotimes,
  unicode,
  random,
  sets,
  #bitops,
  sequtils,
  #strutils,
  strformat,
  math
]
import threading/atomics
import lrucache

from prettyPrint import sep

template dbg*( body :untyped ) :untyped =
  when defined( debug ) :
    body

template single*( tc :int, body :untyped ) :untyped =
  if tc > 1 : discard
  else :
    body

randomize(678)

proc `$`[K,T]( lru :LruCache[K,T] ) :string =
  result = fmt"{$lru.typeof} cap-{$lru.capacity} len-{$lru.len}"

proc tics :int64 = getMonoTime().ticks

type tstat = array[8, int]

var
  threadCount {.global.} :int

  ds        :LRUCache[int64, int64]
  slots     :Atomic[int] = Atomic[int](1)
 
  thr       :array[ 16, Thread[int] ] # thread-array
  stats     :array[ 16, tstat ]       # results-array

  # thread-local vars
  #
  thId*    {.threadvar.} :int
  thValues {.threadvar.} :seq[int]
  thTime   {.threadvar.} :array[2, int64]
  inCache  {.threadvar.} :HashSet[int64]


proc mkSet( s :int ) :HashSet[int] =
  while result.len <= s :
    result.incl rand( s * 2 )
  if 0 in result : result.excl 0


proc th_work( setLen :int ) {.thread.} =

  thId = slots.fetchAdd(1)

  {.gcsafe.}:
    thValues = mkSet( setLen ).toSeq
    var
      turns :int            # no of turns
      thOps :tstat          # thread operations-counter
      tOps  :seq[ tstat ]   #

    while true :
      shuffle thValues
      thTime[0] = tics()

      for v in thValues :
        let op = sample @[ "put", "get", "del", "peek", "update" ]

        case op
        of "put" :
          discard ds.put( v, v )
          inCache.incl v
          thOps[1].inc
          #single( threadCount ) :
          #  if ds.peek(v) != v : echo thId, " ! maybe bad write ?"

        of "get" :
          if v notin ds :
            discard ds.put(v,v)
            thOps[1].inc
            inCache.incl v

          let retries = v mod 4
          for r in 1..retries :
            thOps[2].inc
            let vv = ds.get v
            if vv > 0 :
              if vv != v :
                echo fmt" ! thread-{thId} retry-{r} key-{v} != value-{vv}"
          if retries == 3 :
            ds.del v
            thOps[3].inc
            inCache.excl v

        of "unset" :
          if inCache.card > 0 :
            let k = inCache.pop
            ds.del k

            thOps[3].inc
            # single( threadCount ) :
            #   if k in ds :
            #     echo threadCount, " ?? not removed-" & $k
            #     echo "val-", ds.peek( k )
            #     let bkt = ds.getBucketIdx(k)
            #     echo $ds.buckets[ bkt ].ks.toSeq
            #     echo $ds.buckets[ bkt ].vs.toSeq
            #     quit(1)
          else :
            discard ds.put( v, v )
            thOps[1].inc
            #single( threadCount ) :
            #  if v notin ds : echo " ?? not inserted-" & $v

        of "peek" :
          try :
            discard ds.peek( v )
            thOps[4].inc
          except : discard

        of "update" :
          if inCache.card > 0 :
            let tmp = inCache.pop
            discard ds.put( tmp, tmp )
            thOps[5].inc
          else :
            inCache.incl v
            discard ds.put( v, v )
            thOps[5].inc
            for i in 0..rand(2) :
              let vv = ds.get( v )
              #if vv == 0 : break
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


proc test_cache( setLen :int, tc :int = 1 ) =
  threadCount = tc
  echo "\n" & fmt"test '{$ds.typeof}' {tc}-threads dataSet={setLen.sep}"
  let t0 = tics()
  for i in 1 .. threadCount :
    createThread( thr[i], th_work, setLen )
  joinThreads thr

  let t = (tics() - t0) div 1_000_000           # totalTime
  var ops, tht :int
  for x in 1..tc : ops += stats[x][tstat.low]   # sum-of-operations
  # tht is threadTime :
  #   totalTime - time spent for shuffling-of-values in proc.th_work
  for x in 1..tc : tht += stats[x][tstat.high]  # threads-time-share(s)
  tht = ( tht div 1_000_000 ) div threadCount
  echo fmt"totalTime {t}-ms({tht}-thread) {(tht * 100 div t)}-%"
  echo fmt"{tc}-threads {ops.sep}-ops {t}-ms | {ops div t}-op/ms"
  ds.clear()
 

when isMainModule:
  let setSize   = 150_000
  let cacheSize =  50_000

  ds = newLRUCache[int64, int64]( cacheSize )
  echo fmt"Test of '{$ds.typeof}' setSize-{cacheSize}"

  for tc in 1..1 :
    test_cache( setSize, tc )
    slots.store 1
  echo $ds



  


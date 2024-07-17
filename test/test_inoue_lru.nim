import ../inoue_single
import std/[sequtils, strformat ]

# template prof*( body: untyped ) :untyped =
#   when defined( profile ):
#     body
#
# template dbg*( body: untyped ) :untyped =
#   when defined( debug ):
#     body

var
  Lru = initCache[int, int]( 8, 2, 4 )
  ll  = toSeq( 1..8 )
  k   = 1
  ks :seq[int]


proc ctrlc() {.noconv.} =
  log "Ctrl+C fired!"
  Lru.free()
  log "cleaned up."
  quit()
setControlCHook ctrlc

for v in ll:
  Lru.put( v, v )
  discard Lru.get( v )
  discard Lru.get( v )

Lru.keys()

var step = 3
for d in 9 .. (Lru.cap.int*8 ):
  Lru.put( d, d )
  discard Lru.get( d )
#  let re = eLru.get( d )
#  discard Lru.get( d )
  if step == 0:
    discard Lru.get sample( ll )
    step = 3
  else:
    step.dec
  ks.add d
  k = d

Lru.keys()
log "filled :", (Lru.cap.int*8) - Lru.freeSlots()

# warm-up phase
var fs :int = Lru.freeSlots()

# while fs > 2_000_000:
#   let v = sample(ll)
#   Lru.put( v, v )
#   #ks.add k
#   k.inc
#   fs = Lru.freeSlots()

#log fmt"warmup done.. k-{k} free-slots-{fs}"
stats.reset

# measurement phase
let
  ops = 20 #_000_000
  s0  = ns()

var c = ops
while true:
  case rand(6):
    of 0: Lru.del( sample( ks ) )
    of 1: discard Lru.get( rand(k).int+1 )
    of 2: Lru.put( sample(ks), 1'i32 )
    of 3: discard Lru.get( sample(ll) )
    else: Lru.put( sample(ll), 2 )

  if c == 0: break
  else: c.dec

let s1 = ns() - s0

for v in 0 ..< Lru.cap.int:
  log fmt"{v}.", "\t",Lru.buckets[v].keys

log "free slots-", Lru.freeSlots()
log fmt"inoue_lru ns-{s1} ops-{stats.ops} hits-{stats.hits} misses-{stats.misses}"
log fmt"ns/op-{s1 div stats.ops} hitrate~{(stats.hits*100) div stats.ops} missrate~{(stats.misses*100) div stats.ops}"
Lru.free

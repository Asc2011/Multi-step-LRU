
import std/strformat

# proc `$`*[K, V]( q :Query[K,V] ) :string =
#   if q.found :
#     fmt"+ {$K.typeof}-Query '{q.needle}' -> slot-{q.slot} of bkt/segment {q.bucketIdx}/{q.segment} "
#   else :
#     fmt"- {$K.typeof}-Query '{q.needle}' -> {q.found}"

from ../src/multiStepLRU import Cache
from ../src/utils import prof

template profile*( body :untyped ) :untyped =
  when defined( profile ) :
    body


# proc `$`*[K,V]( lru :Cache[K,V] ) :string =
#   result = fmt"{lru.vecCount}x{lru.vecLen}-LRU({$K.typeof}:{$V.typeof}) buckets-{lru.cap} slots-{lru.cap.int*lru.vecLen*lru.vecCount}"
#   profile:
#     result &= "\n" & fmt"  used-{lru.usage.load}|len-{lru.len} hits-{lru.hits} misses-{lru.misses} ops-{lru.ops}"

proc ppBkt*[K,V]( lru :Cache[K,V], bkt :int, withVals :bool = false ) =
  echo fmt"bkt-{bkt} keys-", lru.buckets[bkt].ks
  if withVals :
    echo fmt"bkt-{bkt} vals-", lru.buckets[bkt].vs


proc `$`*[T]( arr :array[8, T] ) :string =
  var s :seq[string]
  for x in arr : s.add( fmt"{x:3d}" )
  result = fmt"{s}".replace( "\"", "")
  result = "{" & fmt"{result[2 .. result.len-2]}" & "}"


proc sep*( s :SomeInteger, width :int = 0 ) :string =
  result = ($s).reversed
  #result = s.strip( trailing=true, leading=false ).reversed
  for t in 0 .. (result.len div 3) - 1 :
    result.insert("_", (t*3)+3+t )
  result = if ($s).len mod 3 == 0 :
      result.reversed()[1..result.high].align width
    else :
      result.reversed().align width


# import threading/atomics

import std/[
  strformat,
  strutils
]

template prof*( body :untyped ) :untyped =
  when defined( profile ) :
    body

template profile*( body :untyped ) :untyped =
  when defined( profile ) :
    body

template profileAndDebug*( body :untyped ) :untyped =
  when defined( profile ) or defined( debug ):
    body


template dbg*( body :untyped ) :untyped =
  when defined( debug ) :
    body

template multithreaded*( body :untyped ) :untyped =
  when defined( multi ):
    body

template single*( threadCount :int, body :untyped ) :untyped =
  if threadCount > 1 : discard
  else :
    body

# 0 -> put
# 1 -> unset
# 2 -> get :: no mutation
# 3 -> get :: with upgrade
# 4 -> get :: rotation | shuffle
# 5 -> lookup :: read from keys only
# 6 -> read from values
# 7 -> scalar write to values
#
#var stat* {.global.} :array[ 8, Atomic[int] ]



#
# Pointer math
#
proc `+`*[T]( pt :ptr T, x :SomeInteger ) :ptr T =
  let loc = cast[int]( pt )
  #echo "step ", x, " ",( x.int * T.sizeof )
  cast[ptr T]( loc + ( x.int * T.sizeof ))

proc `-`*[T]( pt :ptr T, x :SomeInteger ) :ptr T =
  let loc = cast[int]( pt )
  #echo "step ", x, " ",( x.int * T.sizeof )
  cast[ptr T]( loc - ( x.int * T.sizeof ))

proc `+=`*[T]( pt :var ptr T, x :SomeInteger ) =
  let loc = cast[int]( pt )
  pt = cast[ptr T]( loc + ( x.int * T.sizeof ))

#
# pretty-print Array
#
proc ppArr*[T]( arr :array[8, T] ) :string =
  var s :seq[string]
  for x in arr : s.add( fmt"{x:3d}" )
  result = fmt"{s}".replace( "\"", "")
  result = "{" & fmt"{result[2 .. result.len-2]}" & "}"


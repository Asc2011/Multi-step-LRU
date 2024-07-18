
import std/strformat
import nimsimd/[ avx2, BMI1 ]

let zeroVec* = mm256_set1_epi64x( 0 )

# not used
func isAligned*( pt :pointer, l :int = 64 ) :bool =
  let locAddr = cast[int]( pt )
  result = locAddr mod l == 0


when defined(gcc) or defined(clang) :
  {.localPassc: "-mavx2".}

# func upgrade(  vec :M256i ) :M256i =
#   dbg: debugEcho "upgrade/promotion on ", vec.as epi64
#   result = vec

proc dump*[ T : SomeInteger ]( vec :M256i, str :string = "M256i" ) =
  var vals :seq[T]
  let
    pt = alloc0( 32 )
    b = cast[ ptr UncheckedArray[T] ]( pt )
  mm256_storeu_si256( pt, vec )

  for i in 0 ..< (32 div T.sizeof) : vals.add b[i]
  echo fmt"{str} :: {vals}.{$vec.typeof}"


func asM256d*( vec :M256i ) :M256d = vec.mm256_castsi256_pd()
func asM256i*( vec :M256d ) :M256i = vec.mm256_castpd_si256()

# TODO: implement rotation-by-pattern
# proc rotate(  vec :M256i, pattern :M256i ) :M256i = vec

func rotate*(  vec :M256i ) :M256i = vec.mm256_permute4x64_epi64 0b10_01_00_11'u32
  #dump[uint64]( result, fmt"rotate step-{steps}" )

func rotateLeft*(  vec :M256i ) :M256i = vec.mm256_permute4x64_epi64 0b11_11_10_01'u32


func mm256_blend_epi64*( vecA, vecB :M256i, mask :static int32 ) :M256i =
  mm256_blend_pd( vecA.asM256d, vecB.asM256d, mask ).asM256i

func swapLoLane*( vec :var M256i ) =
  vec = mm256_permute_pd( vec.asM256d, 0b10_01'i32 ).asM256i

func swapHiLane*( vec :var M256i ) =
  vec = mm256_permute_pd( vec.asM256d, 0b10_10_01_10'i32 ).asM256i

# TODO: inclusion via nimsimd
#
func allocAligned*( bytes, align :int ) :pointer = mm_malloc( bytes, align )


proc has*( vec :M256i, needle :SomeInteger ) :int =

  #dbg: echo fmt"    ::has Vec key-{needle} ?"

  let resultVec = vec.mm256_cmpeq_epi64( mm256_set1_epi64x( needle.int ) )
  var mask :int32

  when needle.sizeof == 8 :
    mask = mm256_movemask_pd( resultVec.asM256d )
  elif needle.sizeof == 4 :
    mask = mm256_movemask_ps(
      mm256_cvtepi32_ps( resultVec )
    )
  else :
    mask = mm256_movemask_epi8(
      mm256_cvtepi32_ps( resultVec )
    )

  # key was found in bucket
  #
  if mask != 0 :
    #dbg: echo fmt"    ::has found key-{needle} in slot-{mask.firstSetBit - 1}"

    #if mask.uint32.mm_tzcnt_32.int != mask.firstSetBit-1 :
    #  echo "", mask.uint32.mm_tzcnt_32.int, "  ", mask.firstSetBit-1
    return mask.uint32.mm_tzcnt_32.int

  #dbg: echo fmt"    ::has key-{needle} not found."
  return -1

# TODO needs a param for loc/addr to identify neighbouring SIMD-vector
# include the SIMD related funcs -> to separate by -d:speed|size etc
#
func upgrade*( vecA, vecB :var M256i ) =
  #
  # Upgrade/Promotion between two adjacent LRU-Segments=SIMD-Vectors
  #
  # before :: VecA( a,b,c,D ) VecB( E,f,g,h ) here e.g SIMD.M256i( 4 x int64 )
  #
  # The flow is from right-/0/start/head to left-/3/end/tail.
  #
  # Swap the vecA.lru/tail with the vecB.mru/head,
  # thus promotes elem-'E' and demotes elem-'D'.
  #
  # after :: VecA( a,b,c,E ) VecB( D,f,g,h )

  # cost 1/1
  #var tmpV = vecB.blend( vecA, 0b11_00 )
  var tmpV = mm256_blend_pd( vecB.asM256d, vecA.asM256d, 0b11_00 ).asM256i

  # cost 3/1
  #tmpV.shuffle( 0b00_10_01_11 )
  tmpV = mm256_permute4x64_epi64( tmpV, 0b00_10_01_11 )

  # cost 2 x 1/1
  #vecA = vecA.blend( tmpV, 0b11_00 )
  #vecB = tmpV.blend( vecB, 0b11_00 )
  vecA = mm256_blend_pd( vecA.asM256d, tmpV.asM256d, 0b11_00 ).asM256i
  vecB = mm256_blend_pd( tmpV.asM256d, vecB.asM256d, 0b11_00 ).asM256i

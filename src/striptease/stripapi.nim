# Shared types for striptease format strippers.
# Each audio format implements stripping against this interface
# so the CLI dispatcher stays stable as new formats are added.
# Also hosts the small JSON/string helpers shared by --inspect
# extractors so every module renders metadata the same way.

import std/[json, strutils, unicode]

type
  ChunkAction* = enum
    caKeep
    caDrop

  ChunkReport* = object
    id*: string
    size*: uint32
    action*: ChunkAction

  StripOptions* = object
    keepMusical*: bool
    overwrite*: bool
    dryRun*: bool
    verbose*: bool
    inspect*: bool
    nfkc*: bool
    aggressiveHomoglyphs*: bool
    normalizeSpaces*: bool
    stripEmojiGlue*: bool
    stripBidi*: bool
    forceText*: bool

  StripResult* = object
    kept*: seq[ChunkReport]
    dropped*: seq[ChunkReport]
    bytesIn*: int
    bytesOut*: int

  StripError* = object of CatchableError
  UnsupportedFormatError* = object of CatchableError

proc defaultOptions*(): StripOptions =
  StripOptions(keepMusical: false, overwrite: false, dryRun: false,
      verbose: false, inspect: false, nfkc: false,
      aggressiveHomoglyphs: false, normalizeSpaces: true,
      stripEmojiGlue: false, stripBidi: false, forceText: false)

proc bytesSaved*(r: StripResult): int =
  r.bytesIn - r.bytesOut

proc actionLabel*(a: ChunkAction): string =
  case a
  of caKeep: "keep"
  of caDrop: "drop"

proc sliceAt*(buf: string, a, b: int): string =
  ## Bounds-checked slice; returns "" when out of range.
  if a < b and a >= 0 and b <= buf.len:
    buf[a ..< b]
  else:
    ""

proc sanitise*(s: string, maxLen = 4000): string =
  ## Keeps tabs/newlines, printable ASCII and high bytes (assumed
  ## UTF-8); replaces other control bytes with '?'. Falls back to
  ## pure ASCII if the result is not valid UTF-8, so output is always
  ## safe to serialise as JSON.
  var r = newStringOfCap(min(s.len, maxLen))
  for ch in s:
    if r.len >= maxLen:
      break
    let c = ord(ch)
    if c == 0x09 or c == 0x0A or c == 0x0D or
        (c >= 0x20 and c <= 0x7E) or c >= 0x80:
      r.add(ch)
    else:
      r.add('?')
  if validateUtf8(r) != -1:
    result = newStringOfCap(r.len)
    for ch in r:
      let c = ord(ch)
      if c == 0x09 or c == 0x0A or c == 0x0D or
          (c >= 0x20 and c <= 0x7E):
        result.add(ch)
      else:
        result.add('?')
  else:
    result = r

proc cleanTag*(s: string): string =
  ## Sanitised string with trailing NULs/spaces removed (C-string
  ## style metadata values).
  sanitise(s.strip(leading = false, trailing = true, chars = {'\0', ' '}))

proc textOrNull*(s: string, maxLen = 300): JsonNode =
  ## Returns the sanitised string if the payload looks like text
  ## (>=70% textual bytes), else JSON null. Binary blobs (EXIF,
  ## thumbnails, ...) report size only via the surrounding object.
  if s.len == 0:
    return newJNull()
  var textual = 0
  for ch in s:
    let c = ord(ch)
    if c == 0x09 or c == 0x0A or c == 0x0D or
        (c >= 0x20 and c <= 0x7E) or c >= 0x80:
      inc textual
  if textual * 10 < s.len * 7:
    return newJNull()
  result = % sanitise(s, maxLen)

proc jUint*(v: uint64): JsonNode =
  if v <= uint64(high(int)):
    result = % int(v)
  else:
    result = % $v

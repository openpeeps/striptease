# WebP metadata stripper.
# WebP is RIFF-based ("RIFF" .. "WEBP" + chunks). Image and animation
# chunks (VP8, VP8L, VP8X, ANIM, ANMF, ALPH) are kept verbatim while
# EXIF, XMP and ICCP metadata chunks are dropped.

import std/strutils
import stripapi

export stripapi

func getLe32(buf: string, pos: int): uint32 =
  result = uint32(ord(buf[pos])) or
    (uint32(ord(buf[pos + 1])) shl 8) or
    (uint32(ord(buf[pos + 2])) shl 16) or
    (uint32(ord(buf[pos + 3])) shl 24)

func putLe32(v: uint32): string =
  result = newString(4)
  result[0] = chr(int(v and 0xFF))
  result[1] = chr(int((v shr 8) and 0xFF))
  result[2] = chr(int((v shr 16) and 0xFF))
  result[3] = chr(int((v shr 24) and 0xFF))

func isDropChunk(id: string): bool =
  id == "EXIF" or id == "XMP " or id == "ICCP"

proc stripWebpData*(data: string): tuple[output: string, res: StripResult] =
  var res: StripResult
  res.bytesIn = data.len
  if data.len < 12:
    raise newException(StripError, "file too small to be a WebP file")
  if data[0 .. 3] != "RIFF":
    raise newException(StripError, "not a WebP file (missing RIFF magic)")
  if data[8 .. 11] != "WEBP":
    raise newException(StripError, "not a WebP file (missing WEBP magic)")
  let riffSize = getLe32(data, 4)
  if uint64(riffSize) + 8u64 != uint64(data.len) and
      uint64(riffSize) + 8u64 + 1u64 != uint64(data.len):
    # Allow odd-size padding but otherwise require exact size.
    if uint64(riffSize) + 8u64 < uint64(data.len):
      if data.len - int(riffSize) - 8 > 1:
        raise newException(StripError,
          "trailing garbage after last WebP chunk")
    else:
      raise newException(StripError, "truncated WebP file (bad RIFF size)")
  var keptIds: seq[(string, uint32, string)] = @[]
  var pos = 12
  while pos + 8 <= data.len:
    let id = data[pos .. pos + 3]
    let size = getLe32(data, pos + 4)
    let payloadStart = pos + 8
    if uint64(payloadStart) + uint64(size) > uint64(data.len):
      raise newException(StripError,
        "truncated WebP chunk '" & id & "' (declared " & $size &
        " bytes, file ends early)")
    let payload =
      if size == 0: ""
      else: data[payloadStart ..< payloadStart + int(size)]
    if isDropChunk(id):
      res.dropped.add(ChunkReport(id: id.strip(), size: size,
        action: caDrop))
    else:
      res.kept.add(ChunkReport(id: id.strip(), size: size, action: caKeep))
      keptIds.add((id, size, payload))
    pos = payloadStart + int(size)
    if (size and 1u32) == 1u32:
      if pos >= data.len:
        raise newException(StripError,
          "truncated WebP file (missing chunk padding)")
      pos += 1
  if pos < data.len:
    let trailing = data.len - pos
    if trailing > 1:
      raise newException(StripError,
        "trailing garbage after last WebP chunk (" & $trailing & " bytes)")
  var hasImage = false
  for (id, _, _) in keptIds:
    if id == "VP8 " or id == "VP8L" or id == "VP8X":
      hasImage = true
  if not hasImage:
    raise newException(StripError, "WebP has no image chunk (VP8/VP8L/VP8X)")
  var body = "WEBP"
  for (id, size, payload) in keptIds:
    body.add(id)
    body.add(putLe32(size))
    body.add(payload)
    if (size and 1u32) == 1u32:
      body.add('\0')
  let output = "RIFF" & putLe32(uint32(body.len)) & body
  res.bytesOut = output.len
  result = (output: output, res: res)

proc analyzeWebpData*(data: string): StripResult =
  let (_, res) = stripWebpData(data)
  result = res

# AVI metadata stripper (RIFF-based).
# Strategy is size-preserving so the idx1 index and movi offsets
# stay valid without re-muxing:
# - LIST INFO (IART, INAM, ISFT, ...) and `id3 `/DISP chunks are
#   neutralised in place: the chunk becomes JUNK of identical total
#   size with a zeroed payload.
# - `movi` media data is never parsed, only skipped.
# File length is unchanged, so bytesSaved is 0; privacy comes from
# the neutralised chunks.

import std/strutils
import stripapi

export stripapi

func getLe32(buf: string, pos: int): uint32 =
  result = uint32(ord(buf[pos])) or
    (uint32(ord(buf[pos + 1])) shl 8) or
    (uint32(ord(buf[pos + 2])) shl 16) or
    (uint32(ord(buf[pos + 3])) shl 24)

proc putLe32At(buf: var string, pos: int, v: uint32) =
  buf[pos] = chr(int(v and 0xFF))
  buf[pos + 1] = chr(int((v shr 8) and 0xFF))
  buf[pos + 2] = chr(int((v shr 16) and 0xFF))
  buf[pos + 3] = chr(int((v shr 24) and 0xFF))

proc neutraliseChunk(output: var string, chunkStart, chunkEnd: int) =
  output[chunkStart] = 'J'
  output[chunkStart + 1] = 'U'
  output[chunkStart + 2] = 'N'
  output[chunkStart + 3] = 'K'
  putLe32At(output, chunkStart + 4, uint32(chunkEnd - chunkStart - 8))
  for i in (chunkStart + 8) ..< chunkEnd:
    output[i] = '\0'

proc processRange(output: var string, startPos, endPos: int,
    res: var StripResult) =
  var pos = startPos
  while pos + 8 <= endPos:
    let id = output[pos .. pos + 3]
    let size = getLe32(output, pos + 4)
    let contentEnd = pos + 8 + int(size)
    if contentEnd > endPos:
      raise newException(StripError,
        "truncated AVI chunk '" & id & "' (declared " & $size &
        " bytes, file ends early)")
    var chunkEnd = contentEnd
    if (size and 1u32) == 1u32:
      if chunkEnd >= endPos and endPos == output.len:
        # Padding byte may be missing at exact EOF for odd RIFF size;
        # tolerate it (WAV writer quirk) but count chunk as ending here.
        discard
      else:
        if chunkEnd >= endPos:
          raise newException(StripError,
            "truncated AVI file (missing chunk padding)")
        chunkEnd += 1
    if id == "LIST":
      if int(size) < 4:
        raise newException(StripError, "invalid AVI LIST chunk size")
      let listType = output[pos + 8 .. pos + 11]
      if listType == "INFO":
        res.dropped.add(ChunkReport(id: "LIST-INFO",
          size: size, action: caDrop))
        neutraliseChunk(output, pos, chunkEnd)
      elif listType == "movi":
        res.kept.add(ChunkReport(id: "LIST-movi", size: size,
          action: caKeep))
        # Media data: skip without parsing (may hold thousands of
        # sub-chunks; keep the report short).
        discard
      else:
        res.kept.add(ChunkReport(id: "LIST-" & listType, size: size,
          action: caKeep))
        processRange(output, pos + 12, contentEnd, res)
    elif id == "id3 " or id == "DISP":
      res.dropped.add(ChunkReport(id: id.strip(), size: size,
        action: caDrop))
      neutraliseChunk(output, pos, chunkEnd)
    else:
      if id != "movi" and id != "idx1" and id != "JUNK":
        # Only record structural chunks; movi sub-chunks are skipped
        # wholesale above so this stays short.
        discard
      res.kept.add(ChunkReport(id: id.strip(), size: size,
        action: caKeep))
    pos = chunkEnd

proc stripAviData*(data: string): tuple[output: string, res: StripResult] =
  var res: StripResult
  res.bytesIn = data.len
  if data.len < 12:
    raise newException(StripError, "file too small to be an AVI file")
  if data[0 .. 3] != "RIFF":
    raise newException(StripError, "not an AVI file (missing RIFF magic)")
  if data[8 .. 11] != "AVI ":
    raise newException(StripError, "not an AVI file (missing AVI magic)")
  var output = data
  processRange(output, 12, output.len, res)
  var sawMovi = false
  for k in res.kept:
    if k.id == "LIST-movi":
      sawMovi = true
  if not sawMovi:
    raise newException(StripError, "invalid AVI file (missing movi list)")
  res.bytesOut = output.len
  result = (output: output, res: res)

proc analyzeAviData*(data: string): StripResult =
  let (_, res) = stripAviData(data)
  result = res

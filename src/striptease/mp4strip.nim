# MP4/MOV metadata stripper (ISO Base Media File Format).
# Strategy is size-preserving so sample offsets (stco/co64) and
# seek tables stay valid without re-muxing:
# - `udta`, `meta` and `uuid` (XMP/location) boxes are neutralised
#   in place: type becomes `free` and the payload is zeroed.
# - Creation/modification timestamps in `mvhd`, `tkhd` and `mdhd`
#   are zeroed in place.
# File length is unchanged, so bytesSaved is 0; privacy comes from
# the neutralised boxes and zeroed timestamps.

import stripapi

export stripapi

func getBe32(buf: string, pos: int): uint32 =
  (uint32(ord(buf[pos])) shl 24) or
    (uint32(ord(buf[pos + 1])) shl 16) or
    (uint32(ord(buf[pos + 2])) shl 8) or
    uint32(ord(buf[pos + 3]))

func getBe64(buf: string, pos: int): uint64 =
  var v: uint64 = 0
  for i in 0 ..< 8:
    v = (v shl 8) or uint64(ord(buf[pos + i]))
  result = v

func isContainer(typ: string): bool =
  case typ
  of "moov", "trak", "edts", "mdia", "minf", "dinf", "stbl",
     "mvex", "moof", "traf", "mfra", "strk", "sinf":
    true
  else:
    false

func isMetadataBox(typ: string): bool =
  typ == "udta" or typ == "meta" or typ == "uuid"

func isTimestampBox(typ: string): bool =
  typ == "mvhd" or typ == "tkhd" or typ == "mdhd"

proc neutralise(output: var string, payloadStart, boxEnd: int,
    typePos: int) =
  output[typePos] = 'f'
  output[typePos + 1] = 'r'
  output[typePos + 2] = 'e'
  output[typePos + 3] = 'e'
  for i in payloadStart ..< boxEnd:
    output[i] = '\0'

proc sanitiseTimestamps(output: var string, typ: string,
    payloadStart, boxEnd: int) =
  if payloadStart + 4 > boxEnd:
    return
  let version = ord(output[payloadStart])
  if version == 1:
    if payloadStart + 4 + 16 <= boxEnd:
      for i in (payloadStart + 4) ..< (payloadStart + 4 + 16):
        output[i] = '\0'
  else:
    if payloadStart + 4 + 8 <= boxEnd:
      for i in (payloadStart + 4) ..< (payloadStart + 4 + 8):
        output[i] = '\0'

proc walkBoxes(output: var string, startPos, endPos: int,
    res: var StripResult) =
  var pos = startPos
  while pos + 8 <= endPos:
    let size32 = getBe32(output, pos)
    let typ = output[pos + 4 .. pos + 7]
    var headerLen = 8
    var boxEnd: int
    var payloadStart: int
    if size32 == 1:
      if pos + 16 > endPos:
        raise newException(StripError,
          "truncated MP4 box '" & typ & "' (missing largesize)")
      let largesize = getBe64(output, pos + 8)
      if largesize < 16:
        raise newException(StripError,
          "invalid MP4 box size for '" & typ & "'")
      if uint64(pos) + largesize > uint64(endPos):
        raise newException(StripError,
          "truncated MP4 box '" & typ & "' (declared " & $largesize &
          " bytes, file ends early)")
      headerLen = 16
      boxEnd = pos + int(largesize)
      payloadStart = pos + headerLen
    elif size32 == 0:
      boxEnd = endPos
      payloadStart = pos + headerLen
    else:
      if size32 < 8:
        raise newException(StripError,
          "invalid MP4 box size for '" & typ & "'")
      if uint64(pos) + uint64(size32) > uint64(endPos):
        raise newException(StripError,
          "truncated MP4 box '" & typ & "' (declared " & $size32 &
          " bytes, file ends early)")
      boxEnd = pos + int(size32)
      payloadStart = pos + headerLen
    let totalLen = boxEnd - pos
    if isMetadataBox(typ):
      res.dropped.add(ChunkReport(id: typ, size: uint32(totalLen),
        action: caDrop))
      neutralise(output, payloadStart, boxEnd, pos + 4)
    elif isTimestampBox(typ):
      res.kept.add(ChunkReport(id: typ, size: uint32(totalLen),
        action: caKeep))
      sanitiseTimestamps(output, typ, payloadStart, boxEnd)
    elif isContainer(typ):
      res.kept.add(ChunkReport(id: typ, size: uint32(totalLen),
        action: caKeep))
      if payloadStart < boxEnd:
        walkBoxes(output, payloadStart, boxEnd, res)
    else:
      # Leaf box (ftyp, mdat, stbl entries, ...). Record top-level
      # and moov-direct boxes; skip deep leaves to keep reports short.
      discard
    if boxEnd <= pos:
      raise newException(StripError, "invalid MP4 box (zero progress)")
    pos = boxEnd

proc stripMp4Data*(data: string): tuple[output: string, res: StripResult] =
  var res: StripResult
  res.bytesIn = data.len
  if data.len < 16:
    raise newException(StripError, "file too small to be an MP4/MOV file")
  if data[4 .. 7] != "ftyp":
    raise newException(StripError,
      "not an MP4/MOV file (missing ftyp box)")
  var output = data
  walkBoxes(output, 0, output.len, res)
  var sawMoov = false
  for k in res.kept:
    if k.id == "moov":
      sawMoov = true
  if not sawMoov:
    raise newException(StripError,
      "invalid MP4/MOV file (missing moov box)")
  res.bytesOut = output.len
  result = (output: output, res: res)

proc analyzeMp4Data*(data: string): StripResult =
  let (_, res) = stripMp4Data(data)
  result = res

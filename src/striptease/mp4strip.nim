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

func isoContainer*(typ: string): bool =
  ## Container boxes shared by MP4/MOV, CR3 and HEIC.
  case typ
  of "moov", "trak", "edts", "mdia", "minf", "dinf", "stbl",
     "mvex", "moof", "traf", "mfra", "strk", "sinf":
    true
  else:
    false

type IsoBox* = object
  offset*: int
  payloadStart*: int
  boxEnd*: int
  typ*: string
  total*: int

proc readIsoBoxes*(buf: string, start, finish: int): seq[IsoBox] =
  ## Strict ISO BMFF box walker. Raises StripError on truncation or
  ## invalid sizes. Handles 32-bit sizes, largesize and size-0
  ## (box to end of parent).
  var pos = start
  while pos + 8 <= finish:
    let size32 = getBe32(buf, pos)
    let typ = buf[pos + 4 .. pos + 7]
    var headerLen = 8
    var boxEnd = 0
    if size32 == 1:
      if pos + 16 > finish:
        raise newException(StripError,
          "truncated box '" & typ & "' (missing largesize)")
      let largesize = getBe64(buf, pos + 8)
      if largesize < 16:
        raise newException(StripError,
          "invalid box size for '" & typ & "'")
      if uint64(pos) + largesize > uint64(finish):
        raise newException(StripError,
          "truncated box '" & typ & "' (declared " & $largesize &
          " bytes, parent ends early)")
      headerLen = 16
      boxEnd = pos + int(largesize)
    elif size32 == 0:
      boxEnd = finish
    else:
      if size32 < 8:
        raise newException(StripError,
          "invalid box size for '" & typ & "'")
      if uint64(pos) + uint64(size32) > uint64(finish):
        raise newException(StripError,
          "truncated box '" & typ & "' (declared " & $size32 &
          " bytes, parent ends early)")
      boxEnd = pos + int(size32)
    result.add(IsoBox(offset: pos, payloadStart: pos + headerLen,
      boxEnd: boxEnd, typ: typ, total: boxEnd - pos))
    if boxEnd <= pos:
      raise newException(StripError, "invalid box (zero progress)")
    pos = boxEnd

proc neutraliseIsoBox*(buf: var string, b: IsoBox) =
  ## Turns a box into `free` with zeroed payload, preserving size.
  buf[b.offset + 4] = 'f'
  buf[b.offset + 5] = 'r'
  buf[b.offset + 6] = 'e'
  buf[b.offset + 7] = 'e'
  for i in b.payloadStart ..< b.boxEnd:
    buf[i] = '\0'

proc zeroIsoTimestamps*(buf: var string, b: IsoBox) =
  ## Zeroes creation/modification times of mvhd/tkhd/mdhd in place.
  if b.payloadStart + 4 > b.boxEnd:
    return
  let version = ord(buf[b.payloadStart])
  if version == 1:
    if b.payloadStart + 4 + 16 <= b.boxEnd:
      for i in (b.payloadStart + 4) ..< (b.payloadStart + 4 + 16):
        buf[i] = '\0'
  else:
    if b.payloadStart + 4 + 8 <= b.boxEnd:
      for i in (b.payloadStart + 4) ..< (b.payloadStart + 4 + 8):
        buf[i] = '\0'

func isMetadataBox(typ: string): bool =
  typ == "udta" or typ == "meta" or typ == "uuid"

func isTimestampBox(typ: string): bool =
  typ == "mvhd" or typ == "tkhd" or typ == "mdhd"

proc walkBoxes(output: var string, startPos, endPos: int,
    res: var StripResult) =
  for b in readIsoBoxes(output, startPos, endPos):
    let typ = b.typ
    let totalLen = b.total
    if isMetadataBox(typ):
      res.dropped.add(ChunkReport(id: typ, size: uint32(totalLen),
        action: caDrop))
      neutraliseIsoBox(output, b)
    elif isTimestampBox(typ):
      res.kept.add(ChunkReport(id: typ, size: uint32(totalLen),
        action: caKeep))
      zeroIsoTimestamps(output, b)
    elif isContainer(typ):
      res.kept.add(ChunkReport(id: typ, size: uint32(totalLen),
        action: caKeep))
      if b.payloadStart < b.boxEnd:
        walkBoxes(output, b.payloadStart, b.boxEnd, res)

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

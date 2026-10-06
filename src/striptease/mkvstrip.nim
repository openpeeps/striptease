# MKV/WebM metadata stripper (EBML).
# Strategy is size-preserving so Cue/SeekHead absolute offsets stay
# valid without re-muxing:
# - `Tags` and `Attachments` (cover art, comments) are replaced in
#   place with EBML `Void` of identical total size.
# - `Info/Title`, `Info/DateUTC`, `Info/MuxingApp` and
#   `Info/WritingApp` are replaced with `Void` of identical size.
# - A stale `Info/CRC-32` is voided too when Info is modified.
# File length is unchanged, so bytesSaved is 0; privacy comes from
# the voided elements.

import stripapi

export stripapi

const
  idEbml: uint64 = 0x1A45DFA3u64
  idSegment: uint64 = 0x18538067u64
  idSeekHead: uint64 = 0x114D9B74u64
  idInfo: uint64 = 0x1549A966u64
  idTracks: uint64 = 0x1654AE6Bu64
  idChapters: uint64 = 0x1043A770u64
  idTags: uint64 = 0x1254C367u64
  idAttachments: uint64 = 0x1941A469u64
  idCues: uint64 = 0x1C53BB6Bu64
  idCluster: uint64 = 0x1F43B675u64
  idVoid: uint64 = 0xECu64
  idCrc32: uint64 = 0xBFu64
  idTitle: uint64 = 0x7BA9u64
  idDateUtc: uint64 = 0x4461u64
  idMuxingApp: uint64 = 0x4D80u64
  idWritingApp: uint64 = 0x5741u64
  idTimestampScale: uint64 = 0x2AD7B1u64
  idDuration: uint64 = 0x4489u64
  idSegmentUid: uint64 = 0x73A4u64

func ebmlLen(first: int): int =
  var mask = 0x80
  for l in 1 .. 8:
    if (first and mask) != 0:
      return l
    mask = mask shr 1
  raise newException(StripError, "invalid EBML length descriptor 0x00")

func elementName(id: uint64): string =
  case id
  of idEbml: "EBML"
  of idSegment: "Segment"
  of idSeekHead: "SeekHead"
  of idInfo: "Info"
  of idTracks: "Tracks"
  of idChapters: "Chapters"
  of idTags: "Tags"
  of idAttachments: "Attachments"
  of idCues: "Cues"
  of idCluster: "Cluster"
  of idVoid: "Void"
  of idCrc32: "CRC-32"
  of idTitle: "Title"
  of idDateUtc: "DateUTC"
  of idMuxingApp: "MuxingApp"
  of idWritingApp: "WritingApp"
  of idTimestampScale: "TimestampScale"
  of idDuration: "Duration"
  of idSegmentUid: "SegmentUID"
  else: "E" & $id

proc readId(buf: string, pos, limit: int): tuple[id: uint64, idLen: int] =
  if pos >= limit:
    raise newException(StripError, "truncated EBML id at offset " & $pos)
  let l = ebmlLen(ord(buf[pos]))
  if pos + l > limit:
    raise newException(StripError, "truncated EBML id at offset " & $pos)
  var v: uint64 = 0
  for i in 0 ..< l:
    v = (v shl 8) or uint64(ord(buf[pos + i]))
  result = (id: v, idLen: l)

proc readSize(buf: string, pos, limit: int): tuple[size: int64,
    sizeLen: int] =
  if pos >= limit:
    raise newException(StripError, "truncated EBML size at offset " & $pos)
  let l = ebmlLen(ord(buf[pos]))
  if pos + l > limit:
    raise newException(StripError, "truncated EBML size at offset " & $pos)
  var v: uint64 = 0
  for i in 0 ..< l:
    v = (v shl 8) or uint64(ord(buf[pos + i]))
  let marker: uint64 = 1u64 shl (7 * l)
  let dataBits = (v and (marker - 1u64))
  if dataBits == marker - 1u64:
    result = (size: -1i64, sizeLen: l)
  else:
    if dataBits > uint64(high(int64)):
      raise newException(StripError, "EBML size too large at offset " & $pos)
    result = (size: int64(dataBits), sizeLen: l)

proc writeVoidAt(buf: var string, elemStart, elemEnd: int) =
  let total = elemEnd - elemStart
  if total < 2:
    raise newException(StripError, "cannot void tiny EBML element")
  var chosen = -1
  var payload = 0
  for l in 1 .. 8:
    let p = total - 1 - l
    if p < 0:
      continue
    if uint64(p) <= (1u64 shl (7 * l)) - 2u64:
      chosen = l
      payload = p
      break
  if chosen < 0:
    raise newException(StripError, "cannot void huge EBML element")
  buf[elemStart] = '\xEC'
  let marker: uint64 = 1u64 shl (7 * chosen)
  let encoded = marker or uint64(payload)
  for i in 0 ..< chosen:
    let shift = 8 * (chosen - 1 - i)
    buf[elemStart + 1 + i] = chr(int((encoded shr shift) and 0xFFu64))
  for i in (elemStart + 1 + chosen) ..< elemEnd:
    buf[i] = '\0'

proc voidElement(buf: var string, elemStart, elemEnd: int,
    res: var StripResult, name: string) =
  res.dropped.add(ChunkReport(id: name, size: uint32(elemEnd - elemStart),
    action: caDrop))
  writeVoidAt(buf, elemStart, elemEnd)

proc parseHeader(buf: string, pos, limit: int): tuple[id: uint64,
    idLen, sizeLen: int, size: int64, payloadStart, elemEnd: int,
    unknown: bool] =
  let (id, idLen) = readId(buf, pos, limit)
  let (size, sizeLen) = readSize(buf, pos + idLen, limit)
  let payloadStart = pos + idLen + sizeLen
  if size < 0:
    result = (id: id, idLen: idLen, sizeLen: sizeLen, size: size,
      payloadStart: payloadStart, elemEnd: limit, unknown: true)
  else:
    if uint64(payloadStart) + uint64(size) > uint64(limit):
      raise newException(StripError,
        "truncated EBML element '" & elementName(id) &
        "' (declared " & $size & " bytes, parent ends early)")
    result = (id: id, idLen: idLen, sizeLen: sizeLen, size: size,
      payloadStart: payloadStart,
      elemEnd: payloadStart + int(size), unknown: false)

proc sanitiseInfo(buf: var string, infoPayload, infoEnd: int,
    res: var StripResult) =
  var crcPos = -1
  var crcEnd = -1
  var modified = false
  var pos = infoPayload
  # First pass: locate children.
  var children: seq[(uint64, int, int)] = @[]
  while pos + 2 <= infoEnd:
    let h = parseHeader(buf, pos, infoEnd)
    children.add((h.id, pos, h.elemEnd))
    pos = h.elemEnd
  if pos != infoEnd:
    raise newException(StripError, "truncated EBML Info element")
  for (id, cStart, cEnd) in children:
    if id == idTitle or id == idDateUtc or id == idMuxingApp or
        id == idWritingApp:
      voidElement(buf, cStart, cEnd, res, "Info/" & elementName(id))
      modified = true
    elif id == idCrc32:
      crcPos = cStart
      crcEnd = cEnd
    else:
      res.kept.add(ChunkReport(id: "Info/" & elementName(id),
        size: uint32(cEnd - cStart), action: caKeep))
  if modified and crcPos >= 0:
    voidElement(buf, crcPos, crcEnd, res, "Info/CRC-32")

proc stripMkvData*(data: string): tuple[output: string, res: StripResult] =
  var res: StripResult
  res.bytesIn = data.len
  if data.len < 8:
    raise newException(StripError, "file too small to be an MKV/WebM file")
  var output = data
  # Top level elements.
  var pos = 0
  var sawEbml = false
  var sawSegment = false
  var segPayload = -1
  var segEnd = -1
  while pos + 2 <= output.len:
    let h = parseHeader(output, pos, output.len)
    if h.id == idEbml:
      sawEbml = true
      res.kept.add(ChunkReport(id: "EBML",
        size: uint32(h.elemEnd - pos), action: caKeep))
    elif h.id == idSegment:
      sawSegment = true
      res.kept.add(ChunkReport(id: "Segment",
        size: uint32(h.elemEnd - pos), action: caKeep))
      segPayload = h.payloadStart
      segEnd = h.elemEnd
      # Only handle the first segment; trailing garbage errors below.
      pos = h.elemEnd
      break
    elif h.id == idVoid or h.id == idCrc32:
      res.kept.add(ChunkReport(id: elementName(h.id),
        size: uint32(h.elemEnd - pos), action: caKeep))
    else:
      raise newException(StripError,
        "invalid MKV/WebM file (unexpected top-level '" &
        elementName(h.id) & "')")
    pos = h.elemEnd
  if not sawEbml:
    raise newException(StripError,
      "not an MKV/WebM file (missing EBML header)")
  if not sawSegment:
    raise newException(StripError,
      "invalid MKV/WebM file (missing Segment)")
  if pos != segEnd and segEnd != output.len:
    # Segment with unknown size runs to EOF; anything else exact.
    discard
  # Walk segment children.
  var cpos = segPayload
  while cpos + 2 <= segEnd:
    let h = parseHeader(output, cpos, segEnd)
    if h.id == idTags or h.id == idAttachments:
      voidElement(output, cpos, h.elemEnd, res, elementName(h.id))
    elif h.id == idInfo:
      res.kept.add(ChunkReport(id: "Info",
        size: uint32(h.elemEnd - cpos), action: caKeep))
      sanitiseInfo(output, h.payloadStart, h.elemEnd, res)
    else:
      res.kept.add(ChunkReport(id: elementName(h.id),
        size: uint32(h.elemEnd - cpos), action: caKeep))
    cpos = h.elemEnd
  if cpos != segEnd:
    raise newException(StripError, "truncated MKV/WebM Segment")
  if segEnd != output.len:
    raise newException(StripError,
      "trailing garbage after MKV/WebM Segment (" &
      $(output.len - segEnd) & " bytes)")
  res.bytesOut = output.len
  result = (output: output, res: res)

proc analyzeMkvData*(data: string): StripResult =
  let (_, res) = stripMkvData(data)
  result = res

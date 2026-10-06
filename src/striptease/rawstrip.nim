# TIFF-based RAW metadata stripper.
# Covers CR2, NEF, NRW, ARW, SRF, DNG (including Apple ProRAW),
# RW2, ORF, PEF, SRW and plain TIFF/TIFF: all share the TIFF/EXIF
# container, so one parser handles the family.
#
# Strategy is size-preserving so absolute file offsets (strip/tile
# offsets, SubIFD pointers, makernote layout) stay valid:
# - Identifying text tags (Artist, Copyright, ImageDescription,
#   DateTime, XP_*, ...) are zeroed in every IFD (IFD0, IFD1,
#   SubIFDs, ExifIFD).
# - XMP (700), IPTC (33723) and Photoshop (34377) blobs are zeroed.
# - The GPS IFD subtree is zeroed wholesale.
# - The MakerNote blob is PRESERVED as-is. It can hold serial
#   numbers, owner names and shutter counts, but zeroing it makes
#   Apple decoders (Preview, Photos, sips) refuse the file, so file
#   validity wins. This limitation is documented in the README.
#   Everything else identifying (Artist, GPS, XMP, dates, comments)
#   is still removed.
# - APPn/COM segments inside 513/514 JPEG thumbnails are zeroed.
# Technical decode tags (Make, Model, dimensions, CFA layout,
# strip offsets, Exif exposure settings, orientation) are kept.
# File length is unchanged, so bytesSaved is 0.

import std/json

import stripapi

export stripapi

func tiffTypeSize(typ: int): int =
  case typ
  of 1, 2, 6, 7: 1
  of 3, 8: 2
  of 4, 9, 13: 4
  of 5, 10, 11, 12, 16, 17, 18: 8
  else: 0

func tu16(buf: string, pos: int, le: bool): int =
  if le:
    ord(buf[pos]) or (ord(buf[pos + 1]) shl 8)
  else:
    (ord(buf[pos]) shl 8) or ord(buf[pos + 1])

func tu32(buf: string, pos: int, le: bool): uint32 =
  if le:
    uint32(ord(buf[pos])) or
      (uint32(ord(buf[pos + 1])) shl 8) or
      (uint32(ord(buf[pos + 2])) shl 16) or
      (uint32(ord(buf[pos + 3])) shl 24)
  else:
    (uint32(ord(buf[pos])) shl 24) or
      (uint32(ord(buf[pos + 1])) shl 16) or
      (uint32(ord(buf[pos + 2])) shl 8) or
      uint32(ord(buf[pos + 3]))

func isTextTag(tag: int): bool =
  case tag
  of 270, 305, 306, 315, 700, 33432, 33723, 34377,
     40091, 40092, 40093, 40094, 40095,
     36867, 36868, 37510, 37520, 37521, 37522, 42016:
    true
  else:
    false

func tagName(tag: int): string =
  case tag
  of 270: "ImageDescription"
  of 271: "Make"
  of 272: "Model"
  of 305: "Software"
  of 306: "DateTime"
  of 315: "Artist"
  of 700: "XMP"
  of 33432: "Copyright"
  of 33723: "IPTC"
  of 34377: "Photoshop"
  of 37500: "MakerNote"
  of 40091: "XPTitle"
  of 40092: "XPComment"
  of 40093: "XPAuthor"
  of 40094: "XPKeywords"
  of 40095: "XPSubject"
  of 36867: "DateTimeOriginal"
  of 36868: "DateTimeDigitized"
  of 37510: "UserComment"
  of 37520: "SubSecTime"
  of 37521: "SubSecTimeOriginal"
  of 37522: "SubSecTimeDigitized"
  of 42016: "ImageUniqueID"
  else: "Tag" & $tag

const
  tagExifIfd = 34665
  tagGpsIfd = 34853
  tagSubIfds = 330
  tagInteropIfd = 40965
  tagJpegOff = 513
  tagJpegLen = 514

type TiffHeader = object
  le: bool
  firstIfd: int

proc readTiffHeader(buf: string, tiffStart, limit: int): TiffHeader =
  if tiffStart + 8 > limit:
    raise newException(StripError, "file too small for a TIFF header")
  let bo = buf[tiffStart .. tiffStart + 1]
  var le = false
  if bo == "II":
    le = true
  elif bo == "MM":
    le = false
  else:
    raise newException(StripError, "not a TIFF-based RAW file (bad byte order)")
  if tu16(buf, tiffStart + 2, le) != 42:
    raise newException(StripError,
      "not a TIFF-based RAW file (bad magic, BigTIFF unsupported)")
  let off = tu32(buf, tiffStart + 4, le)
  if uint64(tiffStart) + uint64(off) + 2u64 > uint64(limit):
    raise newException(StripError, "truncated TIFF file (bad first IFD offset)")
  result = TiffHeader(le: le, firstIfd: tiffStart + int(off))

proc entryDataLen(cnt: uint32, tsize: int): uint64 =
  uint64(cnt) * uint64(tsize)

proc zeroBytes(buf: var string, pos, ln: int) =
  for i in pos ..< pos + ln:
    buf[i] = '\0'

proc zeroEntryValue(buf: var string, tiffStart, entryPos, limit: int,
    typ: int, cnt: uint32, le: bool): int =
  ## Zeroes an entry's value bytes (inline or pointed-to).
  ## Returns bytes zeroed, or -1 when the entry is out of bounds.
  let tsize = tiffTypeSize(typ)
  if tsize == 0:
    return -1
  let vlen = entryDataLen(cnt, tsize)
  if vlen == 0:
    return 0
  if vlen <= 4:
    if entryPos + 12 > limit or int(vlen) > 4:
      return -1
    zeroBytes(buf, entryPos + 8, int(vlen))
    return int(vlen)
  if entryPos + 12 > limit:
    return -1
  let off = tu32(buf, entryPos + 8, le)
  if uint64(tiffStart) + uint64(off) + vlen > uint64(limit):
    return -1
  zeroBytes(buf, tiffStart + int(off), int(vlen))
  return int(vlen)

proc readU32List(buf: string, tiffStart, entryPos, limit: int, typ: int,
    cnt: uint32, le: bool): seq[uint64] =
  ## Reads SHORT/LONG/IFD offset lists (inline or pointed-to).
  let sz =
    case typ
    of 3: 2
    of 4, 13: 4
    else: 0
  if sz == 0 or cnt == 0 or cnt > 4096:
    return @[]
  let total = uint64(cnt) * uint64(sz)
  var base = entryPos + 8
  if total > 4:
    if entryPos + 12 > limit:
      return @[]
    let off = tu32(buf, entryPos + 8, le)
    if uint64(tiffStart) + uint64(off) + total > uint64(limit):
      return @[]
    base = tiffStart + int(off)
  else:
    if entryPos + 12 > limit:
      return @[]
  for i in 0 ..< int(cnt):
    if sz == 2:
      result.add(uint64(tu16(buf, base + i * 2, le)))
    else:
      result.add(uint64(tu32(buf, base + i * 4, le)))

proc jpegMetadataRanges*(buf: string, start, finish: int): seq[(int, int)] =
  ## Parses a JPEG blob and returns APPn/COM payload ranges.
  ## Empty result means "not a JPEG" (or no metadata); callers only
  ## write after a successful parse, so raw data is never touched.
  if finish - start < 4:
    return @[]
  if ord(buf[start]) != 0xFF or ord(buf[start + 1]) != 0xD8:
    return @[]
  var pos = start + 2
  while pos + 1 < finish:
    if ord(buf[pos]) != 0xFF:
      return @[]
    var j = pos
    while j < finish and ord(buf[j]) == 0xFF:
      inc j
    if j >= finish:
      return @[]
    let code = ord(buf[j])
    if code == 0x00:
      return @[]
    if code == 0xD9:
      return result
    if code == 0x01 or (code >= 0xD0 and code <= 0xD8):
      pos = j + 1
      continue
    if j + 2 >= finish:
      return @[]
    let segLen = (ord(buf[j + 1]) shl 8) or ord(buf[j + 2])
    if segLen < 2 or j + 1 + segLen > finish:
      return @[]
    if (code >= 0xE0 and code <= 0xEF) or code == 0xFE:
      if segLen > 2:
        result.add((j + 3, segLen - 2))
    pos = j + 1 + segLen
    if code == 0xDA:
      break
  # After SOS only scan data plus EOI may follow.
  if finish - start >= 2 and ord(buf[finish - 2]) == 0xFF and
      ord(buf[finish - 1]) == 0xD9:
    return result
  return @[]

type StripCtx = object
  ifdIndex: int
  depth: int
  visited: seq[int]
  thumbs: seq[(int, int)]
  gpsBytes: int

proc walkStripIfd(buf: var string, tiffStart, ifdAbs, limit: int, le: bool,
    res: var StripResult, ifdName: string, gpsMode: bool,
    ctx: var StripCtx) =
  if ifdAbs in ctx.visited or ctx.depth > 16:
    return
  ctx.visited.add(ifdAbs)
  inc ctx.depth
  if ifdAbs + 2 > limit:
    dec ctx.depth
    return
  let count = tu16(buf, ifdAbs, le)
  if count > 512 or ifdAbs + 2 + count * 12 + 4 > limit:
    dec ctx.depth
    return
  res.kept.add(ChunkReport(id: ifdName, size: uint32(2 + count * 12 + 4),
    action: caKeep))
  var jpegOffs: seq[uint64] = @[]
  var jpegLens: seq[uint64] = @[]
  for i in 0 ..< count:
    let epos = ifdAbs + 2 + i * 12
    let tag = tu16(buf, epos, le)
    let typ = tu16(buf, epos + 2, le)
    let cnt = tu32(buf, epos + 4, le)
    if gpsMode:
      let n = zeroEntryValue(buf, tiffStart, epos, limit, typ, cnt, le)
      if n > 0:
        ctx.gpsBytes += n
      continue
    case tag
    of tagExifIfd:
      let offs = readU32List(buf, tiffStart, epos, limit, typ, cnt, le)
      if offs.len > 0:
        let abs = tiffStart + int(offs[0])
        if abs + 2 <= limit:
          walkStripIfd(buf, tiffStart, abs, limit, le, res, "ExifIFD",
            false, ctx)
    of tagGpsIfd:
      let offs = readU32List(buf, tiffStart, epos, limit, typ, cnt, le)
      if offs.len > 0:
        let abs = tiffStart + int(offs[0])
        ctx.gpsBytes = 0
        walkStripIfd(buf, tiffStart, abs, limit, le, res, "GPS", true, ctx)
        res.dropped.add(ChunkReport(id: "GPS", size: uint32(ctx.gpsBytes),
          action: caDrop))
    of tagSubIfds:
      for off in readU32List(buf, tiffStart, epos, limit, typ, cnt, le):
        let abs = tiffStart + int(off)
        if abs + 2 <= limit:
          walkStripIfd(buf, tiffStart, abs, limit, le, res, "SubIFD",
            false, ctx)
    of tagInteropIfd:
      discard
    of tagJpegOff:
      for off in readU32List(buf, tiffStart, epos, limit, typ, cnt, le):
        jpegOffs.add(off)
    of tagJpegLen:
      for ln in readU32List(buf, tiffStart, epos, limit, typ, cnt, le):
        jpegLens.add(ln)
    else:
      if isTextTag(tag):
        let n = zeroEntryValue(buf, tiffStart, epos, limit, typ, cnt, le)
        if n >= 0:
          res.dropped.add(ChunkReport(id: tagName(tag), size: uint32(n),
            action: caDrop))
  for i in 0 ..< min(jpegOffs.len, jpegLens.len):
    let js = tiffStart + int(jpegOffs[i])
    let je = js + int(jpegLens[i])
    if je <= limit:
      ctx.thumbs.add((js, je))
  if not gpsMode:
    let nextPos = ifdAbs + 2 + count * 12
    if nextPos + 4 <= limit:
      let nextOff = tu32(buf, nextPos, le)
      if nextOff != 0:
        let abs = tiffStart + int(nextOff)
        if abs + 2 <= limit:
          inc ctx.ifdIndex
          walkStripIfd(buf, tiffStart, abs, limit, le, res,
            "IFD" & $ctx.ifdIndex, false, ctx)
  dec ctx.depth

proc sanitiseTiff*(buf: var string, tiffStart, limit: int,
    res: var StripResult) =
  ## Size-preserving TIFF sanitiser. Works on whole files
  ## (tiffStart=0) and on embedded TIFF blobs (CR3 uuid boxes, HEIC
  ## Exif items) via absolute offsets. Raises StripError on a bad
  ## header; stops (tolerant) at later malformed structures.
  let hdr = readTiffHeader(buf, tiffStart, limit)
  var ctx = StripCtx(ifdIndex: 0, depth: 0, visited: @[], thumbs: @[],
    gpsBytes: 0)
  walkStripIfd(buf, tiffStart, hdr.firstIfd, limit, hdr.le, res, "IFD0",
    false, ctx)
  var thumbBytes = 0
  for (js, je) in ctx.thumbs:
    for (rs, rl) in jpegMetadataRanges(buf, js, je):
      zeroBytes(buf, rs, rl)
      thumbBytes += rl
  if thumbBytes > 0:
    res.dropped.add(ChunkReport(id: "THMB", size: uint32(thumbBytes),
      action: caDrop))

proc stripRawData*(data: string): tuple[output: string, res: StripResult] =
  var res: StripResult
  res.bytesIn = data.len
  var output = data
  sanitiseTiff(output, 0, output.len, res)
  res.bytesOut = output.len
  result = (output: output, res: res)

proc analyzeRawData*(data: string): StripResult =
  let (_, res) = stripRawData(data)
  result = res

# --------------------------------------------------------------- inspect ---

type TiffValue = object
  tag, typ: int
  cnt: uint32
  dataPos, dataLen: int

proc entryRange(buf: string, tiffStart, epos, limit: int, le: bool): tuple[
    ok: bool, typ: int, cnt: uint32, dataPos, dataLen: int] =
  if epos + 12 > limit:
    return (ok: false, typ: 0, cnt: 0, dataPos: 0, dataLen: 0)
  let typ = tu16(buf, epos + 2, le)
  let cnt = tu32(buf, epos + 4, le)
  let tsize = tiffTypeSize(typ)
  if tsize == 0:
    return (ok: false, typ: typ, cnt: cnt, dataPos: 0, dataLen: 0)
  let vlen = entryDataLen(cnt, tsize)
  if vlen > uint64(limit):
    return (ok: false, typ: typ, cnt: cnt, dataPos: 0, dataLen: 0)
  if vlen <= 4:
    return (ok: true, typ: typ, cnt: cnt, dataPos: epos + 8,
      dataLen: int(vlen))
  let off = tu32(buf, epos + 8, le)
  if uint64(tiffStart) + uint64(off) + vlen > uint64(limit):
    return (ok: false, typ: typ, cnt: cnt, dataPos: 0, dataLen: 0)
  result = (ok: true, typ: typ, cnt: cnt, dataPos: tiffStart + int(off),
    dataLen: int(vlen))

proc rationalAt(buf: string, pos, limit: int, le: bool): tuple[ok: bool,
    v: float] =
  if pos + 8 > limit:
    return (ok: false, v: 0.0)
  let num = tu32(buf, pos, le)
  let den = tu32(buf, pos + 4, le)
  if den == 0:
    return (ok: false, v: 0.0)
  result = (ok: true, v: float(num) / float(den))

proc inspectGps(buf: string, tiffStart, ifdAbs, limit: int,
    le: bool): JsonNode =
  if ifdAbs + 2 > limit:
    return newJNull()
  let count = tu16(buf, ifdAbs, le)
  if count > 64 or ifdAbs + 2 + count * 12 > limit:
    return newJNull()
  var latRef = ""
  var lonRef = ""
  var lat = [0.0, 0.0, 0.0]
  var lon = [0.0, 0.0, 0.0]
  var hasLat = false
  var hasLon = false
  var alt = 0.0
  var hasAlt = false
  var below = false
  for i in 0 ..< count:
    let epos = ifdAbs + 2 + i * 12
    let tag = tu16(buf, epos, le)
    let r = entryRange(buf, tiffStart, epos, limit, le)
    if not r.ok:
      continue
    case tag
    of 1:
      latRef = cleanTag(sliceAt(buf, r.dataPos, r.dataPos + r.dataLen))
    of 2:
      if r.dataLen >= 24:
        var ok = true
        for k in 0 ..< 3:
          let q = rationalAt(buf, r.dataPos + k * 8, limit, le)
          if not q.ok:
            ok = false
          lat[k] = q.v
        hasLat = ok
    of 3:
      lonRef = cleanTag(sliceAt(buf, r.dataPos, r.dataPos + r.dataLen))
    of 4:
      if r.dataLen >= 24:
        var ok = true
        for k in 0 ..< 3:
          let q = rationalAt(buf, r.dataPos + k * 8, limit, le)
          if not q.ok:
            ok = false
          lon[k] = q.v
        hasLon = ok
    of 5:
      below = r.dataLen > 0 and ord(buf[r.dataPos]) == 1
    of 6:
      let q = rationalAt(buf, r.dataPos, limit, le)
      if q.ok:
        alt = q.v
        hasAlt = true
    else:
      discard
  if not hasLat and not hasLon and not hasAlt:
    return newJNull()
  result = newJObject()
  if hasLat:
    var v = lat[0] + lat[1] / 60.0 + lat[2] / 3600.0
    if latRef == "S":
      v = -v
    result["latitude"] = % v
  if hasLon:
    var v = lon[0] + lon[1] / 60.0 + lon[2] / 3600.0
    if lonRef == "W":
      v = -v
    result["longitude"] = % v
  if hasAlt:
    result["altitude"] = % (if below: -alt else: alt)

type InspectCtx = object
  depth: int
  visited: seq[int]
  index: int

proc walkInspectIfd(buf: string, tiffStart, ifdAbs, limit: int, le: bool,
    ifdName: string, ctx: var InspectCtx): JsonNode =
  result = newJObject()
  result["id"] = % ifdName
  var tags = newJObject()
  result["tags"] = tags
  result["gps"] = newJNull()
  result["makerNote"] = newJNull()
  result["xmp"] = newJNull()
  if ifdAbs in ctx.visited or ctx.depth > 16:
    return result
  ctx.visited.add(ifdAbs)
  inc ctx.depth
  var subIfds: seq[JsonNode] = @[]
  var nextName = ""
  if ifdAbs + 2 <= limit:
    let count = tu16(buf, ifdAbs, le)
    if count <= 512 and ifdAbs + 2 + count * 12 + 4 <= limit:
      for i in 0 ..< count:
        let epos = ifdAbs + 2 + i * 12
        let tag = tu16(buf, epos, le)
        let r = entryRange(buf, tiffStart, epos, limit, le)
        if not r.ok:
          continue
        if tag == tagGpsIfd:
          let offs = readU32List(buf, tiffStart, epos, limit,
            tu16(buf, epos + 2, le), r.cnt, le)
          if offs.len > 0:
            let g = inspectGps(buf, tiffStart, tiffStart + int(offs[0]),
              limit, le)
            if g.kind != JNull:
              result["gps"] = g
        elif tag == tagExifIfd:
          let offs = readU32List(buf, tiffStart, epos, limit,
            tu16(buf, epos + 2, le), r.cnt, le)
          if offs.len > 0:
            subIfds.add(walkInspectIfd(buf, tiffStart,
              tiffStart + int(offs[0]), limit, le, "ExifIFD", ctx))
        elif tag == tagSubIfds:
          let typ = tu16(buf, epos + 2, le)
          for off in readU32List(buf, tiffStart, epos, limit, typ, r.cnt,
              le):
            subIfds.add(walkInspectIfd(buf, tiffStart, tiffStart + int(off),
              limit, le, "SubIFD", ctx))
        elif tag == 37500:
          result["makerNote"] = % r.dataLen
        elif tag == 700:
          result["xmp"] = % r.dataLen
        elif r.typ == 2:
          tags[tagName(tag)] = % cleanTag(sliceAt(buf, r.dataPos,
            r.dataPos + r.dataLen))
      let nextPos = ifdAbs + 2 + count * 12
      if nextPos + 4 <= limit:
        let nextOff = tu32(buf, nextPos, le)
        if nextOff != 0:
          let abs = tiffStart + int(nextOff)
          if abs + 2 <= limit:
            inc ctx.index
            nextName = "IFD" & $ctx.index
            subIfds.add(walkInspectIfd(buf, tiffStart, abs, limit, le,
              nextName, ctx))
  dec ctx.depth
  if subIfds.len > 0:
    var arr = newJArray()
    for s in subIfds:
      arr.add(s)
    result["subIfds"] = arr
  return result

proc inspectTiff*(buf: string, tiffStart, limit: int): JsonNode =
  ## Read-only TIFF metadata view. Works on whole files and on
  ## embedded TIFF blobs (CR3 uuid boxes, HEIC Exif items).
  let hdr = readTiffHeader(buf, tiffStart, limit)
  var ctx = InspectCtx(depth: 0, visited: @[], index: 0)
  var arr = newJArray()
  arr.add(walkInspectIfd(buf, tiffStart, hdr.firstIfd, limit, hdr.le,
    "IFD0", ctx))
  result = %* {"byteOrder": (if hdr.le: "II" else: "MM"), "ifds": arr}

proc inspectRawData*(data: string): JsonNode =
  inspectTiff(data, 0, data.len)

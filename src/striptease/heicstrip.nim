# HEIC/HEIF metadata stripper (ISO BMFF based).
# Unlike MP4, the `meta` box holds essential image references
# (iloc extents, pitm, iinf), so it must NOT be neutralised wholesale.
# Instead item-level surgery is used, all size-preserving:
# - `udta` and top-level/moov `uuid` boxes become `free` (as in MP4).
# - Timestamps in `mvhd`/`tkhd`/`mdhd` are zeroed in place.
# - `meta` is parsed (iinf item types + iloc extents):
#   Exif items get the TIFF sanitiser on their embedded TIFF
#   (keeps orientation/dimensions, drops GPS/Artist/MakerNote);
#   XMP (mime) item payloads are zeroed. Image items (hvc1, grid,
#   thmb, ...) are untouched, so decoding is unaffected.
# - `meta`-level `uuid` boxes are content-sniffed like CR3.
# Live Photos: the still/video pairing identifier lives in XMP/uuid
# metadata, so a stripped still and video remain valid standalone
# files but are no longer linked as a Live Photo.

import std/[json, strutils]

import stripapi
import mp4strip
import rawstrip
import cr3strip

export stripapi

const heicBrands = ["heic", "heix", "hevc", "hevx", "heim", "heis",
  "hevm", "hevs", "mif1", "msf1", "msf2"]

func hbe16(buf: string, pos: int): uint64 =
  (uint64(ord(buf[pos])) shl 8) or uint64(ord(buf[pos + 1]))

func hbe32(buf: string, pos: int): uint64 =
  (uint64(ord(buf[pos])) shl 24) or
    (uint64(ord(buf[pos + 1])) shl 16) or
    (uint64(ord(buf[pos + 2])) shl 8) or
    uint64(ord(buf[pos + 3]))

type Cursor = object
  pos: int
  ok: bool

proc take(c: var Cursor, n, limit: int): int =
  if not c.ok or n < 0 or c.pos + n > limit:
    c.ok = false
    return -1
  result = c.pos
  c.pos += n

proc readN(buf: string, c: var Cursor, n, limit: int): uint64 =
  let p = take(c, n, limit)
  if not c.ok:
    return 0
  var v: uint64 = 0
  for i in 0 ..< n:
    v = (v shl 8) or uint64(ord(buf[p + i]))
  result = v

proc readNul(buf: string, pos, limit: int): tuple[s: string, next: int] =
  var p = pos
  while p < limit and ord(buf[p]) != 0:
    inc p
  result = (sliceAt(buf, pos, p), min(p + 1, limit))

type HeicItem = object
  id: uint64
  typ: string
  name: string
  ctype: string

proc parseInfe(buf: string, pstart, pend: int): tuple[ok: bool,
    item: HeicItem] =
  result = (ok: false, item: HeicItem())
  if pstart + 12 > pend:
    return result
  let ver = ord(buf[pstart])
  var tpos = 0
  if ver == 2:
    if pstart + 12 > pend:
      return result
    result.item.id = hbe16(buf, pstart + 4)
    tpos = pstart + 8
  elif ver == 3:
    if pstart + 14 > pend:
      return result
    result.item.id = hbe32(buf, pstart + 4)
    tpos = pstart + 10
  else:
    return result # v0/v1 carry no item_type; cannot classify.
  if tpos + 4 > pend:
    return result
  result.item.typ = buf[tpos .. tpos + 3]
  let (name, p1) = readNul(buf, tpos + 4, pend)
  result.item.name = cleanTag(name)
  if result.item.typ == "mime":
    let (ct, _) = readNul(buf, p1, pend)
    result.item.ctype = cleanTag(ct)
  result.ok = true
  return result

proc parseIinf(buf: string, pstart, pend: int): seq[HeicItem] =
  if pstart + 6 > pend:
    return @[]
  let ver = ord(buf[pstart])
  var count: uint64
  var pos: int
  if ver == 0:
    count = hbe16(buf, pstart + 4)
    pos = pstart + 6
  else:
    if pstart + 8 > pend:
      return @[]
    count = hbe32(buf, pstart + 4)
    pos = pstart + 8
  var n = 0
  while pos + 8 <= pend and uint64(n) < count and n < 10000:
    let size32 = hbe32(buf, pos)
    let typ = buf[pos + 4 .. pos + 7]
    var headLen = 8
    var boxEnd = 0
    if size32 == 1:
      if pos + 16 > pend:
        break
      let large = hbe32(buf, pos + 8) # boxes here are small; hi 32 bits ignored
      if large < 16 or uint64(pos) + large > uint64(pend):
        break
      headLen = 16
      boxEnd = pos + int(large)
    elif size32 == 0:
      boxEnd = pend
    else:
      if size32 < 8 or uint64(pos) + size32 > uint64(pend):
        break
      boxEnd = pos + int(size32)
    if typ == "infe":
      let (ok, item) = parseInfe(buf, pos + headLen, boxEnd)
      if ok:
        result.add(item)
    if boxEnd <= pos:
      break
    pos = boxEnd
    inc n

type IlocExtent = object
  pos: int
  len: int

type IlocEntry = object
  itemID: uint64
  extents: seq[IlocExtent]

proc parseIloc(buf: string, pstart, pend, idatStart,
    fileLen: int): seq[IlocEntry] =
  ## Parses iloc and resolves construction methods 0 (file offset)
  ## and 1 (idat offset) to absolute positions. Entries that cannot
  ## be resolved get an empty extent list.
  if pstart + 8 > pend:
    return @[]
  let ver = ord(buf[pstart])
  if ver > 2:
    return @[]
  let osz = (ord(buf[pstart + 4]) shr 4) and 15
  let lsz = ord(buf[pstart + 4]) and 15
  let bsz = (ord(buf[pstart + 5]) shr 4) and 15
  let isz = ord(buf[pstart + 5]) and 15
  if ver == 0 and isz != 0:
    return @[]
  for s in [osz, lsz, bsz, isz]:
    if s > 8:
      return @[]
  var c = Cursor(pos: pstart + 6, ok: true)
  var count: uint64
  if ver < 2:
    count = readN(buf, c, 2, pend)
  else:
    c.pos = pstart + 6
    count = readN(buf, c, 4, pend)
  if not c.ok or count > 100000:
    return @[]
  for _ in 0 ..< int(min(count, 100000u64)):
    var id: uint64
    if ver < 2:
      id = readN(buf, c, 2, pend)
    else:
      id = readN(buf, c, 4, pend)
    var construction = 0
    if ver >= 1:
      construction = int(readN(buf, c, 2, pend))
    discard readN(buf, c, 2, pend) # data_reference_index
    let base = readN(buf, c, bsz, pend)
    let extentCount = readN(buf, c, 2, pend)
    if not c.ok or extentCount > 100000:
      return @[]
    var entry = IlocEntry(itemID: id, extents: @[])
    var failed = false
    for _ in 0 ..< int(extentCount):
      if isz > 0:
        discard readN(buf, c, isz, pend)
      let off = readN(buf, c, osz, pend)
      let ln = readN(buf, c, lsz, pend)
      if not c.ok:
        failed = true
        break
      var abs: uint64
      if construction == 0:
        abs = base + off
      elif construction == 1 and idatStart >= 0:
        abs = uint64(idatStart) + base + off
      else:
        failed = true
        break
      if abs + ln > uint64(fileLen):
        failed = true
        break
      entry.extents.add(IlocExtent(pos: int(abs), len: int(ln)))
    if failed:
      entry.extents = @[]
    result.add(entry)
    if not c.ok:
      return result

func itemKind(it: HeicItem): string =
  if it.typ == "Exif":
    "exif"
  elif it.typ == "mime" and ("rdf" in it.ctype or "xap" in it.ctype or
      "xml" in it.ctype):
    "xmp"
  else:
    ""

proc zeroRange(buf: var string, pos, ln: int) =
  for i in pos ..< pos + ln:
    buf[i] = '\0'

proc handleMeta(output: var string, meta: IsoBox, res: var StripResult) =
  res.kept.add(ChunkReport(id: "meta", size: uint32(meta.total),
    action: caKeep))
  if meta.payloadStart + 4 > meta.boxEnd:
    return
  let cstart = meta.payloadStart + 4
  var kids: seq[IsoBox]
  try:
    kids = readIsoBoxes(output, cstart, meta.boxEnd)
  except StripError:
    return
  var iinfS = -1
  var iinfE = -1
  var ilocS = -1
  var ilocE = -1
  var idatStart = -1
  for b in kids:
    if b.typ == "iinf":
      iinfS = b.payloadStart
      iinfE = b.boxEnd
    elif b.typ == "iloc":
      ilocS = b.payloadStart
      ilocE = b.boxEnd
    elif b.typ == "idat":
      idatStart = b.payloadStart
    elif b.typ == "uuid":
      sanitiseUuid(output, b, res)
  if iinfS < 0 or ilocS < 0:
    return
  let items = parseIinf(output, iinfS, iinfE)
  let table = parseIloc(output, ilocS, ilocE, idatStart, output.len)
  for item in items:
    var extents: seq[IlocExtent] = @[]
    for e in table:
      if e.itemID == item.id:
        extents = e.extents
        break
    var total = 0
    for e in extents:
      total += e.len
    let label =
      if item.typ != "": item.typ
      else: "id" & $item.id
    case itemKind(item)
    of "exif":
      if extents.len == 0:
        res.kept.add(ChunkReport(id: "ITEM-Exif", size: 0, action: caKeep))
        continue
      let es = extents[0]
      var sanitised = false
      if es.len >= 8:
        # The 4-byte offset is relative to the byte after itself
        # (Apple writes 6 to skip its "Exif\0\0" prefix).
        let trel = int(hbe32(output, es.pos))
        let tiffStart = es.pos + 4 + trel
        if tiffStart + 8 <= es.pos + es.len and trel >= 0 and
            tiffStart >= es.pos + 4:
          let before = res.dropped.len
          try:
            sanitiseTiff(output, tiffStart, es.pos + es.len, res)
            sanitised = true
          except StripError:
            res.dropped.setLen(before)
      if not sanitised:
        zeroRange(output, es.pos, es.len)
        res.dropped.add(ChunkReport(id: "Exif", size: uint32(es.len),
          action: caDrop))
      var extra = 0
      for i in 1 ..< extents.len:
        zeroRange(output, extents[i].pos, extents[i].len)
        extra += extents[i].len
      if extra > 0:
        res.dropped.add(ChunkReport(id: "Exif", size: uint32(extra),
          action: caDrop))
    of "xmp":
      if extents.len == 0:
        res.kept.add(ChunkReport(id: "ITEM-mime", size: 0, action: caKeep))
        continue
      for e in extents:
        zeroRange(output, e.pos, e.len)
      res.dropped.add(ChunkReport(id: "XMP", size: uint32(total),
        action: caDrop))
    else:
      res.kept.add(ChunkReport(id: "ITEM-" & label, size: uint32(total),
        action: caKeep))

proc walkHeic(output: var string, startPos, endPos: int, inMeta: bool,
    res: var StripResult) =
  for b in readIsoBoxes(output, startPos, endPos):
    if b.typ == "udta":
      res.dropped.add(ChunkReport(id: "udta", size: uint32(b.total),
        action: caDrop))
      neutraliseIsoBox(output, b)
    elif b.typ == "mvhd" or b.typ == "tkhd" or b.typ == "mdhd":
      res.kept.add(ChunkReport(id: b.typ, size: uint32(b.total),
        action: caKeep))
      zeroIsoTimestamps(output, b)
    elif b.typ == "uuid":
      if inMeta:
        sanitiseUuid(output, b, res)
      else:
        res.dropped.add(ChunkReport(id: "uuid", size: uint32(b.total),
          action: caDrop))
        neutraliseIsoBox(output, b)
    elif b.typ == "meta":
      handleMeta(output, b, res)
    elif isoContainer(b.typ):
      res.kept.add(ChunkReport(id: b.typ, size: uint32(b.total),
        action: caKeep))
      if b.payloadStart < b.boxEnd:
        walkHeic(output, b.payloadStart, b.boxEnd, inMeta, res)

proc checkHeic(data: string) =
  if data.len < 12 or data[4 .. 7] != "ftyp":
    raise newException(StripError, "not a HEIC file (missing ftyp box)")
  let major = data[8 .. 11]
  if major notin heicBrands:
    raise newException(StripError,
      "not a HEIC file (brand '" & major & "' unsupported)")

proc stripHeicData*(data: string): tuple[output: string, res: StripResult] =
  var res: StripResult
  res.bytesIn = data.len
  checkHeic(data)
  var output = data
  walkHeic(output, 0, output.len, false, res)
  var sawMeta = false
  for k in res.kept:
    if k.id == "meta":
      sawMeta = true
  if not sawMeta:
    raise newException(StripError, "invalid HEIC file (missing meta box)")
  res.bytesOut = output.len
  result = (output: output, res: res)

proc analyzeHeicData*(data: string): StripResult =
  let (_, res) = stripHeicData(data)
  result = res

proc inspectHeicData*(data: string): JsonNode =
  checkHeic(data)
  var items = newJArray()
  var exifTiff: JsonNode = newJNull()
  var timestamps = newJArray()
  proc walk(start, finish: int, inMeta: bool) =
    for b in readIsoBoxes(data, start, finish):
      if b.typ == "mvhd" or b.typ == "tkhd" or b.typ == "mdhd":
        let p = b.payloadStart
        if p + 4 > b.boxEnd:
          continue
        let ver = ord(data[p])
        if ver == 1 and p + 20 <= b.boxEnd:
          var u: uint64 = 0
          for i in 0 ..< 8:
            u = (u shl 8) or uint64(ord(data[p + 4 + i]))
          timestamps.add(%* {"box": b.typ, "version": ver,
            "creation": jUint(u)})
        elif ver != 1 and p + 12 <= b.boxEnd:
          var c: uint64 = 0
          for i in 0 ..< 4:
            c = (c shl 8) or uint64(ord(data[p + 4 + i]))
          timestamps.add(%* {"box": b.typ, "version": ver,
            "creation": jUint(c)})
      elif b.typ == "meta":
        if b.payloadStart + 4 <= b.boxEnd:
          let cstart = b.payloadStart + 4
          var iinfS = -1
          var iinfE = -1
          var ilocS = -1
          var ilocE = -1
          var idatStart = -1
          try:
            for k in readIsoBoxes(data, cstart, b.boxEnd):
              if k.typ == "iinf":
                iinfS = k.payloadStart
                iinfE = k.boxEnd
              elif k.typ == "iloc":
                ilocS = k.payloadStart
                ilocE = k.boxEnd
              elif k.typ == "idat":
                idatStart = k.payloadStart
          except StripError:
            continue
          if iinfS < 0 or ilocS < 0:
            continue
          let found = parseIinf(data, iinfS, iinfE)
          let table = parseIloc(data, ilocS, ilocE, idatStart, data.len)
          for item in found:
            var total = 0
            var firstPos = -1
            var firstLen = 0
            for e in table:
              if e.itemID == item.id:
                for x in e.extents:
                  if firstPos < 0:
                    firstPos = x.pos
                    firstLen = x.len
                  total += x.len
                break
            items.add(%* {"id": jUint(item.id),
              "type": (if item.typ == "": "unknown" else: item.typ),
              "name": item.name, "contentType": item.ctype, "size": total})
            if exifTiff.kind == JNull and itemKind(item) == "exif" and
                firstPos >= 0 and firstLen >= 8:
              let trel = int(hbe32(data, firstPos))
              let tiffStart = firstPos + 4 + trel
              if tiffStart + 8 <= firstPos + firstLen and trel >= 0 and
                  tiffStart >= firstPos + 4:
                try:
                  exifTiff = inspectTiff(data, tiffStart, firstPos + firstLen)
                except StripError:
                  discard
      elif isoContainer(b.typ):
        walk(b.payloadStart, b.boxEnd, inMeta)
  walk(0, data.len, false)
  result = %* {"items": items, "exif": exifTiff, "timestamps": timestamps}

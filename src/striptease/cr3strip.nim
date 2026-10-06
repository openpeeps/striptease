# Canon CR3 metadata stripper (ISO BMFF based, major brand "crx ").
# Strategy is size-preserving so sample tables stay valid:
# - `udta` boxes are neutralised to `free` (as in MP4).
# - Creation/modification timestamps in `mvhd`, `tkhd` and `mdhd`
#   are zeroed in place.
# - `uuid` boxes are content-sniffed: embedded TIFF/EXIF blobs get
#   the TIFF sanitiser (Artist, GPS, MakerNote, ...), XMP payloads
#   are zeroed, JPEG previews get APPn/COM zeroing. Unrecognised
#   uuid boxes (decoder config, ...) are kept verbatim.
# - `prvw` previews starting with a JPEG SOI get APPn/COM zeroing.
# File length is unchanged, so bytesSaved is 0.

import std/[json, strutils]

import stripapi
import mp4strip
import rawstrip

export stripapi

func isTiffAt(buf: string, pos: int): bool =
  if pos + 4 > buf.len:
    return false
  let bo = buf[pos .. pos + 1]
  if bo != "II" and bo != "MM":
    return false
  if bo == "II":
    ord(buf[pos + 2]) == 0x2A and ord(buf[pos + 3]) == 0x00
  else:
    ord(buf[pos + 2]) == 0x00 and ord(buf[pos + 3]) == 0x2A

func uuidKind(buf: string, pstart, boxEnd: int): string =
  ## Sniffs a uuid payload: "tiff", "xmp", "jpeg" or "".
  let ln = boxEnd - pstart
  if ln >= 4 and isTiffAt(buf, pstart):
    return "tiff"
  if ln >= 2 and ord(buf[pstart]) == 0xFF and ord(buf[pstart + 1]) == 0xD8:
    return "jpeg"
  let headLen = min(ln, 4096)
  let head = buf[pstart ..< pstart + headLen]
  if "http://ns.adobe.com/xap/1.0/" in head:
    return "xmp"
  let trimmed = head.strip()
  if trimmed.startsWith("<?xpacket") or trimmed.startsWith("<x:"):
    return "xmp"
  return ""

proc zeroRange(buf: var string, pstart, boxEnd: int) =
  for i in pstart ..< boxEnd:
    buf[i] = '\0'

proc sanitiseUuid*(output: var string, b: IsoBox, res: var StripResult) =
  case uuidKind(output, b.payloadStart, b.boxEnd)
  of "tiff":
    let before = res.dropped.len
    try:
      sanitiseTiff(output, b.payloadStart, b.boxEnd, res)
    except StripError:
      res.dropped.setLen(before)
      res.kept.add(ChunkReport(id: "uuid", size: uint32(b.total),
        action: caKeep))
  of "xmp":
    res.dropped.add(ChunkReport(id: "uuid-XMP", size: uint32(b.total),
      action: caDrop))
    zeroRange(output, b.payloadStart, b.boxEnd)
  of "jpeg":
    var thumbBytes = 0
    for (rs, rl) in jpegMetadataRanges(output, b.payloadStart, b.boxEnd):
      zeroRange(output, rs, rs + rl)
      thumbBytes += rl
    if thumbBytes > 0:
      res.dropped.add(ChunkReport(id: "uuid-JPEG",
        size: uint32(thumbBytes), action: caDrop))
    else:
      res.kept.add(ChunkReport(id: "uuid", size: uint32(b.total),
        action: caKeep))
  else:
    res.kept.add(ChunkReport(id: "uuid", size: uint32(b.total),
      action: caKeep))

proc walkCr3(output: var string, startPos, endPos: int,
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
      sanitiseUuid(output, b, res)
    elif b.typ == "prvw":
      if b.boxEnd - b.payloadStart >= 2 and
          ord(output[b.payloadStart]) == 0xFF and
          ord(output[b.payloadStart + 1]) == 0xD8:
        var thumbBytes = 0
        for (rs, rl) in jpegMetadataRanges(output, b.payloadStart, b.boxEnd):
          zeroRange(output, rs, rs + rl)
          thumbBytes += rl
        if thumbBytes > 0:
          res.dropped.add(ChunkReport(id: "PRVW", size: uint32(thumbBytes),
            action: caDrop))
        else:
          res.kept.add(ChunkReport(id: "prvw", size: uint32(b.total),
            action: caKeep))
      else:
        res.kept.add(ChunkReport(id: "prvw", size: uint32(b.total),
          action: caKeep))
    elif isoContainer(b.typ):
      res.kept.add(ChunkReport(id: b.typ, size: uint32(b.total),
        action: caKeep))
      if b.payloadStart < b.boxEnd:
        walkCr3(output, b.payloadStart, b.boxEnd, res)

proc stripCr3Data*(data: string): tuple[output: string, res: StripResult] =
  var res: StripResult
  res.bytesIn = data.len
  if data.len < 12 or data[4 .. 7] != "ftyp" or data[8 .. 11] != "crx ":
    raise newException(StripError,
      "not a CR3 file (missing ftyp/crx brand)")
  var output = data
  walkCr3(output, 0, output.len, res)
  var sawMoov = false
  for k in res.kept:
    if k.id == "moov":
      sawMoov = true
  if not sawMoov:
    raise newException(StripError, "invalid CR3 file (missing moov box)")
  res.bytesOut = output.len
  result = (output: output, res: res)

proc analyzeCr3Data*(data: string): StripResult =
  let (_, res) = stripCr3Data(data)
  result = res

proc inspectCr3Data*(data: string): JsonNode =
  if data.len < 12 or data[4 .. 7] != "ftyp" or data[8 .. 11] != "crx ":
    raise newException(StripError,
      "not a CR3 file (missing ftyp/crx brand)")
  var timestamps = newJArray()
  var boxes = newJArray()
  proc walk(start, finish: int) =
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
          var v: uint64 = 0
          for i in 0 ..< 8:
            v = (v shl 8) or uint64(ord(data[p + 12 + i]))
          timestamps.add(%* {"box": b.typ, "version": ver,
            "creation": jUint(u), "modification": jUint(v)})
        elif ver != 1 and p + 12 <= b.boxEnd:
          var c: uint32 = 0
          for i in 0 ..< 4:
            c = (c shl 8) or uint32(ord(data[p + 4 + i]))
          var m: uint32 = 0
          for i in 0 ..< 4:
            m = (m shl 8) or uint32(ord(data[p + 8 + i]))
          timestamps.add(%* {"box": b.typ, "version": ver,
            "creation": jUint(uint64(c)), "modification": jUint(uint64(m))})
      elif b.typ == "uuid":
        let kind = uuidKind(data, b.payloadStart, b.boxEnd)
        var node = %* {"type": "uuid", "kind":
          (if kind == "": "unknown" else: kind), "size": b.total}
        if kind == "tiff":
          try:
            node["tiff"] = inspectTiff(data, b.payloadStart, b.boxEnd)
          except StripError:
            node["tiff"] = newJNull()
        boxes.add(node)
      elif b.typ == "udta":
        boxes.add(%* {"type": "udta", "size": b.total})
      elif isoContainer(b.typ):
        walk(b.payloadStart, b.boxEnd)
  walk(0, data.len)
  result = %* {"timestamps": timestamps, "boxes": boxes}

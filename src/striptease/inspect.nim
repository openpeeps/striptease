# Metadata inspector.
# Best-effort extraction of embedded metadata (tags, comments,
# timestamps, ...) for --inspect. Walkers stop at the first malformed
# structure instead of raising, so partially damaged files still report
# what was found. Only magic mismatches raise StripError.

import std/[json, strutils, times]

import stripapi
import wavstrip
import pngstrip
import rawstrip
import cr3strip
import heicstrip

func le32u(buf: string, pos: int): uint32 =
  result = uint32(ord(buf[pos])) or
    (uint32(ord(buf[pos + 1])) shl 8) or
    (uint32(ord(buf[pos + 2])) shl 16) or
    (uint32(ord(buf[pos + 3])) shl 24)

func be32u(buf: string, pos: int): uint32 =
  result = (uint32(ord(buf[pos])) shl 24) or
    (uint32(ord(buf[pos + 1])) shl 16) or
    (uint32(ord(buf[pos + 2])) shl 8) or
    uint32(ord(buf[pos + 3]))

func be64u(buf: string, pos: int): uint64 =
  var v: uint64 = 0
  for i in 0 ..< 8:
    v = (v shl 8) or uint64(ord(buf[pos + i]))
  result = v

# ---------------------------------------------------------------- RIFF ---

type RiffChunk = object
  offset: int
  id: string
  size: uint32
  payload: string
  listType: string

proc readRiffChunks(buf: string, start, finish: int): seq[RiffChunk] =
  ## Tolerant walker: stops at the first truncated chunk.
  var pos = start
  while pos + 8 <= finish:
    let id = buf[pos .. pos + 3]
    let size = le32u(buf, pos + 4)
    let contentEnd = pos + 8 + int(size)
    if contentEnd > finish:
      break
    var chunkEnd = contentEnd
    if (size and 1u32) == 1u32 and chunkEnd < finish:
      chunkEnd += 1
    let payload = sliceAt(buf, pos + 8, contentEnd)
    var lt = ""
    if id == "LIST" and payload.len >= 4:
      lt = payload[0 .. 3]
    result.add(RiffChunk(offset: pos, id: id, size: size, payload: payload,
      listType: lt))
    if chunkEnd <= pos:
      break
    pos = chunkEnd

proc inspectWavData*(data: string, keepMusical: bool): JsonNode =
  if data.len < 12 or data[0 .. 3] != "RIFF" or data[8 .. 11] != "WAVE":
    raise newException(StripError, "not a WAV file (missing RIFF/WAVE magic)")
  var info = newJObject()
  var chunks = newJArray()
  for c in readRiffChunks(data, 12, data.len):
    if c.id == "LIST" and c.listType == "INFO":
      for sub in readRiffChunks(data, c.offset + 12, c.offset + 8 +
          int(c.size)):
        info[sub.id.strip()] = % cleanTag(sub.payload)
    elif not isKeepChunk(c.id, keepMusical):
      let cid =
        if c.id == "LIST" and c.listType != "": "LIST-" & c.listType
        else: c.id.strip()
      chunks.add(%* {"id": cid, "size": int(c.size)})
  result = %* {"info": info, "chunks": chunks}

proc inspectAviData*(data: string): JsonNode =
  if data.len < 12 or data[0 .. 3] != "RIFF" or data[8 .. 11] != "AVI ":
    raise newException(StripError, "not an AVI file (missing RIFF/AVI magic)")
  var info = newJObject()
  var chunks = newJArray()
  proc walk(start, finish: int) =
    for c in readRiffChunks(data, start, finish):
      if c.id == "LIST":
        if c.listType == "INFO":
          for sub in readRiffChunks(data, c.offset + 12, c.offset + 8 +
              int(c.size)):
            info[sub.id.strip()] = % cleanTag(sub.payload)
        elif c.listType == "movi":
          discard
        else:
          walk(c.offset + 12, c.offset + 8 + int(c.size))
      elif c.id == "id3 " or c.id == "DISP":
        chunks.add(%* {"id": c.id.strip(), "size": int(c.size)})
  walk(12, data.len)
  result = %* {"info": info, "chunks": chunks}

# ---------------------------------------------------------------- JPEG ---

proc jpegKind(code: int, p: string): string =
  if code == 0xFE:
    return "comment"
  if p.startsWith("Exif\x00\x00"):
    return "exif"
  if "http://ns.adobe.com/xap/1.0/" in p or p.startsWith("XMP"):
    return "xmp"
  if p.startsWith("ICC_PROFILE"):
    return "icc"
  if p.startsWith("Photoshop 3.0") or p.startsWith("8BIM"):
    return "photoshop"
  if p.startsWith("JFIF\x00"):
    return "jfif"
  if p.startsWith("Adobe"):
    return "adobe"
  return "unknown"

proc inspectJpegData*(data: string): JsonNode =
  if data.len < 2 or ord(data[0]) != 0xFF or ord(data[1]) != 0xD8:
    raise newException(StripError, "not a JPEG file (missing SOI magic)")
  var segs = newJArray()
  var pos = 2
  while pos < data.len:
    if ord(data[pos]) != 0xFF:
      break
    var j = pos
    while j < data.len and ord(data[j]) == 0xFF:
      inc j
    if j >= data.len:
      break
    let code = ord(data[j])
    if code == 0x00 or code == 0xD9:
      break
    if code == 0x01 or (code >= 0xD0 and code <= 0xD8):
      pos = j + 1
      continue
    if j + 2 >= data.len:
      break
    let segLen = (ord(data[j + 1]) shl 8) or ord(data[j + 2])
    if segLen < 2 or j + 1 + segLen > data.len:
      break
    let payload = sliceAt(data, j + 3, j + 1 + segLen)
    if (code >= 0xE0 and code <= 0xEF) or code == 0xFE:
      let name =
        if code == 0xFE: "COM"
        else: "APP" & $(code - 0xE0)
      segs.add(%* {"marker": name, "size": payload.len,
        "kind": jpegKind(code, payload), "preview": textOrNull(payload)})
    pos = j + 1 + segLen
    if code == 0xDA:
      break
  result = %* {"segments": segs}

# ----------------------------------------------------------------- PNG ---

proc inspectPngData*(data: string): JsonNode =
  if data.len < 8 or data[0 .. 7] != "\x89PNG\x0D\x0A\x1A\x0A":
    raise newException(StripError, "not a PNG file (missing PNG signature)")
  var text = newJArray()
  var compressedText = newJArray()
  var translatedText = newJArray()
  var profiles = newJArray()
  var exif = newJArray()
  var chunks = newJArray()
  var timeVal: JsonNode = newJNull()
  var pos = 8
  while pos + 8 <= data.len:
    let length = int(be32u(data, pos))
    let id = data[pos + 4 .. pos + 7]
    if pos + 12 + length > data.len:
      break
    let payload = sliceAt(data, pos + 8, pos + 8 + length)
    case id
    of "tEXt":
      let idx = payload.find('\0')
      if idx >= 0:
        text.add(%* {"keyword": sanitise(payload[0 ..< idx]),
          "text": sanitise(sliceAt(payload, idx + 1, payload.len))})
      else:
        chunks.add(%* {"type": id, "size": length})
    of "zTXt":
      let idx = payload.find('\0')
      if idx >= 0 and idx + 1 < payload.len:
        compressedText.add(%* {"keyword": sanitise(payload[0 ..< idx]),
          "method": ord(payload[idx + 1]),
          "size": payload.len - idx - 2})
      else:
        chunks.add(%* {"type": id, "size": length})
    of "iTXt":
      let idx = payload.find('\0')
      if idx >= 0 and idx + 2 < payload.len:
        let compFlag = ord(payload[idx + 1])
        let rest = sliceAt(payload, idx + 3, payload.len)
        let langEnd = rest.find('\0')
        if langEnd >= 0:
          let afterLang = sliceAt(rest, langEnd + 1, rest.len)
          let trEnd = afterLang.find('\0')
          if trEnd >= 0:
            translatedText.add(%* {
              "keyword": sanitise(payload[0 ..< idx]),
              "compressed": compFlag != 0,
              "lang": sanitise(rest[0 ..< langEnd]),
              "text": sanitise(sliceAt(afterLang, trEnd + 1,
                afterLang.len))})
          else:
            chunks.add(%* {"type": id, "size": length})
        else:
          chunks.add(%* {"type": id, "size": length})
      else:
        chunks.add(%* {"type": id, "size": length})
    of "iCCP":
      let idx = payload.find('\0')
      if idx >= 0 and idx + 1 < payload.len:
        profiles.add(%* {"profile": sanitise(payload[0 ..< idx]),
          "method": ord(payload[idx + 1]),
          "size": payload.len - idx - 2})
      else:
        chunks.add(%* {"type": id, "size": length})
    of "eXIf":
      exif.add(%* {"size": length})
    of "tIME":
      if payload.len == 7:
        let year = (ord(payload[0]) shl 8) or ord(payload[1])
        timeVal = % ($year & "-" & align($ord(payload[2]), 2, '0') &
          "-" & align($ord(payload[3]), 2, '0') & " " &
          align($ord(payload[4]), 2, '0') & ":" &
          align($ord(payload[5]), 2, '0') & ":" &
          align($ord(payload[6]), 2, '0'))
      else:
        chunks.add(%* {"type": id, "size": length})
    else:
      if not isKeepChunk(id):
        chunks.add(%* {"type": id, "size": length})
    pos = pos + 12 + length
  result = %* {"text": text, "compressedText": compressedText,
    "translatedText": translatedText, "profiles": profiles, "exif": exif,
    "time": timeVal, "chunks": chunks}

# ----------------------------------------------------------------- GIF ---

proc gifSubBlocks(buf: string, pos, limit: int): tuple[endPos: int,
    parts: seq[string]] =
  var p = pos
  var parts: seq[string] = @[]
  while true:
    if p >= limit:
      break
    let n = ord(buf[p])
    inc p
    if n == 0:
      break
    if p + n > limit:
      break
    parts.add(sliceAt(buf, p, p + n))
    p += n
  result = (endPos: p, parts: parts)

proc inspectGifData*(data: string): JsonNode =
  if data.len < 13:
    raise newException(StripError, "file too small to be a GIF file")
  let magic = data[0 .. 5]
  if magic != "GIF87a" and magic != "GIF89a":
    raise newException(StripError, "not a GIF file (missing GIF magic)")
  var comments = newJArray()
  var texts = newJArray()
  var apps = newJArray()
  let packed = ord(data[10])
  var pos = 13
  if (packed and 0x80) != 0:
    pos += 3 * (1 shl ((packed and 0x07) + 1))
    if pos > data.len:
      raise newException(StripError, "truncated GIF global color table")
  while pos < data.len:
    let sep = ord(data[pos])
    if sep == 0x21:
      if pos + 2 > data.len:
        break
      let extLabel = ord(data[pos + 1])
      let (endPos, parts) = gifSubBlocks(data, pos + 2, data.len)
      case extLabel
      of 0xFE:
        comments.add(% sanitise(parts.join("")))
      of 0x01:
        var txt = parts.join("")
        if txt.len > 12:
          txt = txt[12 .. ^1]
        texts.add(% sanitise(txt))
      of 0xFF:
        let appId =
          if parts.len > 0 and parts[0].len == 11: parts[0]
          else: "unknown"
        apps.add(%* {"id": sanitise(appId), "size": endPos - pos})
      else:
        discard
      if endPos <= pos:
        break
      pos = endPos
    elif sep == 0x2C:
      if pos + 10 > data.len:
        break
      let ipacked = ord(data[pos + 9])
      var total = 10
      if (ipacked and 0x80) != 0:
        total += 3 * (1 shl ((ipacked and 0x07) + 1))
      if pos + total + 1 > data.len:
        break
      let (endPos, _) = gifSubBlocks(data, pos + total + 1, data.len)
      if endPos <= pos:
        break
      pos = endPos
    elif sep == 0x3B:
      break
    else:
      break
  result = %* {"comments": comments, "texts": texts, "apps": apps}

# ---------------------------------------------------------------- WebP ---

proc inspectWebpData*(data: string): JsonNode =
  if data.len < 12 or data[0 .. 3] != "RIFF" or data[8 .. 11] != "WEBP":
    raise newException(StripError, "not a WebP file (missing RIFF/WEBP magic)")
  var found = newJArray()
  var pos = 12
  while pos + 8 <= data.len:
    let id = data[pos .. pos + 3]
    let size = int(le32u(data, pos + 4))
    if pos + 8 + size > data.len:
      break
    if id == "EXIF" or id == "XMP " or id == "ICCP":
      found.add(%* {"type": id.strip(), "size": size,
        "preview": textOrNull(sliceAt(data, pos + 8, pos + 8 + size))})
    pos = pos + 8 + size
    if (size and 1) == 1 and pos < data.len:
      pos += 1
  result = %* {"chunks": found}

# ----------------------------------------------------------------- MP4 ---

type Mp4Box = object
  offset, payloadStart, boxEnd: int
  typ: string
  total: int
  toEnd: bool

proc readMp4Boxes(buf: string, start, finish: int): seq[Mp4Box] =
  ## Tolerant walker: stops at the first malformed box.
  var pos = start
  while pos + 8 <= finish:
    let s32 = be32u(buf, pos)
    let typ = buf[pos + 4 .. pos + 7]
    var headLen = 8
    var bend = 0
    if s32 == 1:
      if pos + 16 > finish:
        break
      let large = be64u(buf, pos + 8)
      if large < 16 or uint64(pos) + large > uint64(finish):
        break
      headLen = 16
      bend = pos + int(large)
      result.add(Mp4Box(offset: pos, payloadStart: pos + headLen,
        boxEnd: bend, typ: typ, total: bend - pos, toEnd: false))
    elif s32 == 0:
      bend = finish
      result.add(Mp4Box(offset: pos, payloadStart: pos + headLen,
        boxEnd: bend, typ: typ, total: bend - pos, toEnd: true))
    else:
      if s32 < 8 or uint64(pos) + uint64(s32) > uint64(finish):
        break
      bend = pos + int(s32)
      result.add(Mp4Box(offset: pos, payloadStart: pos + headLen,
        boxEnd: bend, typ: typ, total: bend - pos, toEnd: false))
    if bend <= pos:
      break
    pos = bend

proc mp4Container(typ: string): bool =
  case typ
  of "moov", "trak", "edts", "mdia", "minf", "dinf", "stbl",
     "mvex", "moof", "traf", "mfra", "ilst":
    true
  else:
    false

proc boxLabel(t: string): string =
  ## Box types are 4 raw bytes; render non-ASCII bytes (e.g. the
  ## 0xA9 in Apple's proprietary tags) as '?' so JSON stays valid.
  result = newStringOfCap(4)
  for ch in t:
    let c = ord(ch)
    if c >= 0x20 and c <= 0x7E:
      result.add(ch)
    else:
      result.add('?')

proc childrenLookValid(kids: seq[Mp4Box], start, boxEnd: int): bool =
  if kids.len == 0 or kids[0].offset != start:
    return false
  if kids[^1].boxEnd != boxEnd:
    return false
  for k in kids:
    if k.toEnd:
      return false
  return true

proc mp4Node(buf: string, b: Mp4Box): JsonNode =
  var start = b.payloadStart
  if b.typ == "meta":
    start += 4
  if start + 8 <= b.boxEnd:
    let kids = readMp4Boxes(buf, start, b.boxEnd)
    if childrenLookValid(kids, start, b.boxEnd):
      var arr = newJArray()
      for k in kids:
        arr.add(mp4Node(buf, k))
      return %* {"type": boxLabel(b.typ), "size": b.total, "children": arr}
  var pstart = b.payloadStart
  if b.typ == "data":
    pstart = min(b.payloadStart + 8, b.boxEnd)
  result = %* {"type": boxLabel(b.typ), "size": b.total,
    "text": textOrNull(sliceAt(buf, pstart, b.boxEnd))}

proc inspectMp4Data*(data: string): JsonNode =
  if data.len < 8 or data[4 .. 7] != "ftyp":
    raise newException(StripError, "not an MP4/MOV file (missing ftyp box)")
  var timestamps = newJArray()
  var boxes = newJArray()
  proc walk(start, finish: int) =
    for b in readMp4Boxes(data, start, finish):
      if b.typ == "mvhd" or b.typ == "tkhd" or b.typ == "mdhd":
        let p = b.payloadStart
        if p + 4 > b.boxEnd:
          continue
        let ver = ord(data[p])
        if ver == 1 and p + 20 <= b.boxEnd:
          timestamps.add(%* {"box": b.typ, "version": ver,
            "creation": jUint(be64u(data, p + 4)),
            "modification": jUint(be64u(data, p + 12))})
        elif ver != 1 and p + 12 <= b.boxEnd:
          timestamps.add(%* {"box": b.typ, "version": ver,
            "creation": jUint(uint64(be32u(data, p + 4))),
            "modification": jUint(uint64(be32u(data, p + 8)))})
      elif b.typ == "udta" or b.typ == "meta" or b.typ == "uuid":
        boxes.add(mp4Node(data, b))
      elif mp4Container(b.typ):
        walk(b.payloadStart, b.boxEnd)
  walk(0, data.len)
  result = %* {"timestamps": timestamps, "boxes": boxes}

# ----------------------------------------------------------------- MKV ---

const
  mkvInfo: uint64 = 0x1549A966u64
  mkvTags: uint64 = 0x1254C367u64
  mkvAttachments: uint64 = 0x1941A469u64
  mkvTitle: uint64 = 0x7BA9u64
  mkvDateUtc: uint64 = 0x4461u64
  mkvMuxingApp: uint64 = 0x4D80u64
  mkvWritingApp: uint64 = 0x5741u64
  mkvTag: uint64 = 0x7373u64
  mkvSimpleTag: uint64 = 0x67C8u64
  mkvTagName: uint64 = 0x45A3u64
  mkvTagString: uint64 = 0x4487u64
  mkvTagBinary: uint64 = 0x4485u64
  mkvAttachedFile: uint64 = 0x61A7u64
  mkvFileName: uint64 = 0x466Eu64
  mkvFileMime: uint64 = 0x4660u64
  mkvFileData: uint64 = 0x465Cu64
  mkvFileDesc: uint64 = 0x467Eu64

type EbmlHeader = object
  id: uint64
  payloadStart, elemEnd: int

proc ebmlLen(first: int): int =
  var mask = 0x80
  for l in 1 .. 8:
    if (first and mask) != 0:
      return l
    mask = mask shr 1
  raise newException(StripError, "invalid EBML length descriptor")

proc readEbml(buf: string, pos, limit: int): EbmlHeader =
  if pos >= limit:
    raise newException(StripError, "truncated EBML header at offset " & $pos)
  let ilen = ebmlLen(ord(buf[pos]))
  if pos + ilen > limit:
    raise newException(StripError, "truncated EBML id at offset " & $pos)
  var idv: uint64 = 0
  for i in 0 ..< ilen:
    idv = (idv shl 8) or uint64(ord(buf[pos + i]))
  if pos + ilen >= limit:
    raise newException(StripError, "truncated EBML size at offset " & $pos)
  let slen = ebmlLen(ord(buf[pos + ilen]))
  if pos + ilen + slen > limit:
    raise newException(StripError, "truncated EBML size at offset " & $pos)
  var sv: uint64 = 0
  for i in 0 ..< slen:
    sv = (sv shl 8) or uint64(ord(buf[pos + ilen + i]))
  let marker: uint64 = 1u64 shl (7 * slen)
  let payloadStart = pos + ilen + slen
  if (sv and (marker - 1u64)) == marker - 1u64:
    result = EbmlHeader(id: idv, payloadStart: payloadStart, elemEnd: limit)
  else:
    let size = int(sv and (marker - 1u64))
    if payloadStart + size > limit:
      raise newException(StripError, "truncated EBML element at offset " &
        $pos)
    result = EbmlHeader(id: idv, payloadStart: payloadStart,
      elemEnd: payloadStart + size)

proc ebmlUint(buf: string, pos, ln: int): uint64 =
  var u: uint64 = 0
  for i in 0 ..< ln:
    u = (u shl 8) or uint64(ord(buf[pos + i]))
  result = u

proc ebmlInt(buf: string, pos, ln: int): int64 =
  var u = ebmlUint(buf, pos, ln)
  if ln < 8 and (ord(buf[pos]) and 0x80) != 0:
    u = u or (not ((1u64 shl (8 * ln)) - 1u64))
  result = int64(u)

proc dateUtcIso(ns: int64): string =
  try:
    let secs = ns div 1_000_000_000i64 + 978307200i64
    result = format(fromUnix(secs).utc, "yyyy-MM-dd'T'HH:mm:ss'Z'")
  except CatchableError:
    result = ""

proc parseSimpleTag(buf: string, start, finish: int, prefix: string,
    pairs: var seq[(string, string)]) =
  var name = ""
  var value = ""
  var binNote = ""
  var pos = start
  while pos + 2 <= finish:
    var h: EbmlHeader
    try:
      h = readEbml(buf, pos, finish)
    except StripError:
      break
    if h.id == mkvTagName:
      name = cleanTag(sliceAt(buf, h.payloadStart, h.elemEnd))
    elif h.id == mkvTagString:
      value = cleanTag(sliceAt(buf, h.payloadStart, h.elemEnd))
    elif h.id == mkvTagBinary:
      binNote = "(binary " & $(h.elemEnd - h.payloadStart) & " bytes)"
    elif h.id == mkvSimpleTag:
      let childName =
        if name == "": "?"
        else: name
      let childPrefix =
        if prefix == "": childName
        else: prefix & "/" & childName
      parseSimpleTag(buf, h.payloadStart, h.elemEnd, childPrefix, pairs)
    pos = h.elemEnd
    if pos >= finish:
      break
  if name != "":
    let path =
      if prefix == "": name
      else: prefix & "/" & name
    let v =
      if value != "": value
      elif binNote != "": binNote
      else: ""
    pairs.add((path, v))

proc collectSimpleTags(buf: string, start, finish: int, prefix: string,
    pairs: var seq[(string, string)]) =
  var pos = start
  while pos + 2 <= finish:
    var h: EbmlHeader
    try:
      h = readEbml(buf, pos, finish)
    except StripError:
      break
    if h.id == mkvSimpleTag:
      parseSimpleTag(buf, h.payloadStart, h.elemEnd, prefix, pairs)
    pos = h.elemEnd
    if pos >= finish:
      break

proc inspectMkvData*(data: string): JsonNode =
  if data.len < 8:
    raise newException(StripError, "file too small to be an MKV/WebM file")
  var first: EbmlHeader
  try:
    first = readEbml(data, 0, data.len)
  except StripError:
    raise newException(StripError, "not an MKV/WebM file (bad EBML header)")
  if first.id != 0x1A45DFA3u64:
    raise newException(StripError, "not an MKV/WebM file (missing EBML header)")
  var segStart = -1
  var segEnd = -1
  var pos = first.elemEnd
  while pos + 2 <= data.len:
    var h: EbmlHeader
    try:
      h = readEbml(data, pos, data.len)
    except StripError:
      break
    if h.id == 0x18538067u64:
      segStart = h.payloadStart
      segEnd = h.elemEnd
      break
    pos = h.elemEnd
  if segStart < 0:
    raise newException(StripError, "invalid MKV/WebM file (missing Segment)")
  var info = newJObject()
  var tags = newJArray()
  var attachments = newJArray()
  pos = segStart
  while pos + 2 <= segEnd:
    var h: EbmlHeader
    try:
      h = readEbml(data, pos, segEnd)
    except StripError:
      break
    if h.id == mkvInfo:
      var ipos = h.payloadStart
      while ipos + 2 <= h.elemEnd:
        var c: EbmlHeader
        try:
          c = readEbml(data, ipos, h.elemEnd)
        except StripError:
          break
        if c.id == mkvTitle:
          info["title"] = % cleanTag(sliceAt(data, c.payloadStart,
            c.elemEnd))
        elif c.id == mkvMuxingApp:
          info["muxingApp"] = % cleanTag(sliceAt(data, c.payloadStart,
            c.elemEnd))
        elif c.id == mkvWritingApp:
          info["writingApp"] = % cleanTag(sliceAt(data, c.payloadStart,
            c.elemEnd))
        elif c.id == mkvDateUtc and c.elemEnd - c.payloadStart == 8:
          let ns = ebmlInt(data, c.payloadStart, 8)
          var node = newJObject()
          if ns >= 0:
            node["ns"] = jUint(uint64(ns))
          else:
            node["ns"] = % int(ns)
          let iso = dateUtcIso(ns)
          if iso != "":
            node["iso"] = % iso
          info["dateUtc"] = node
        ipos = c.elemEnd
        if ipos >= h.elemEnd:
          break
    elif h.id == mkvTags:
      var tpos = h.payloadStart
      while tpos + 2 <= h.elemEnd:
        var t: EbmlHeader
        try:
          t = readEbml(data, tpos, h.elemEnd)
        except StripError:
          break
        if t.id == mkvTag:
          var pairs: seq[(string, string)] = @[]
          collectSimpleTags(data, t.payloadStart, t.elemEnd, "", pairs)
          for (path, val) in pairs:
            tags.add(%* {"tag": path, "value": val})
        tpos = t.elemEnd
        if tpos >= h.elemEnd:
          break
    elif h.id == mkvAttachments:
      var apos = h.payloadStart
      while apos + 2 <= h.elemEnd:
        var a: EbmlHeader
        try:
          a = readEbml(data, apos, h.elemEnd)
        except StripError:
          break
        if a.id == mkvAttachedFile:
          var fname: JsonNode = newJNull()
          var mime: JsonNode = newJNull()
          var desc: JsonNode = newJNull()
          var dataSize = 0
          var fpos = a.payloadStart
          while fpos + 2 <= a.elemEnd:
            var f: EbmlHeader
            try:
              f = readEbml(data, fpos, a.elemEnd)
            except StripError:
              break
            if f.id == mkvFileName:
              fname = % cleanTag(sliceAt(data, f.payloadStart, f.elemEnd))
            elif f.id == mkvFileMime:
              mime = % cleanTag(sliceAt(data, f.payloadStart, f.elemEnd))
            elif f.id == mkvFileDesc:
              desc = % cleanTag(sliceAt(data, f.payloadStart, f.elemEnd))
            elif f.id == mkvFileData:
              dataSize = f.elemEnd - f.payloadStart
            fpos = f.elemEnd
            if fpos >= a.elemEnd:
              break
          attachments.add(%* {"file": fname, "mime": mime,
            "size": dataSize, "description": desc})
        apos = a.elemEnd
        if apos >= h.elemEnd:
          break
    pos = h.elemEnd
    if pos >= segEnd:
      break
  result = %* {"info": info, "tags": tags, "attachments": attachments}

# ------------------------------------------------------------ dispatcher ---

proc inspectData*(kind: string, data: string,
    keepMusical = false): JsonNode =
  ## Extracts embedded metadata for --inspect. Raises StripError on
  ## magic mismatch, UnsupportedFormatError on unknown kind.
  case kind
  of "wav":
    result = inspectWavData(data, keepMusical)
  of "jpeg":
    result = inspectJpegData(data)
  of "png":
    result = inspectPngData(data)
  of "gif":
    result = inspectGifData(data)
  of "webp":
    result = inspectWebpData(data)
  of "mp4":
    result = inspectMp4Data(data)
  of "avi":
    result = inspectAviData(data)
  of "mkv":
    result = inspectMkvData(data)
  of "raw":
    result = inspectRawData(data)
  of "cr3":
    result = inspectCr3Data(data)
  of "heic":
    result = inspectHeicData(data)
  else:
    raise newException(UnsupportedFormatError,
      "unsupported format: " & kind)

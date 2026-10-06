# GIF metadata stripper.
# Rebuilds the file keeping headers, logical screen descriptor,
# graphic control extensions, image descriptors and the trailer.
# Comment extensions, plain text extensions and application
# extensions (except NETSCAPE2.0 looping) are dropped.

import stripapi

export stripapi

proc readSubBlocks(data: string, pos: int): int =
  ## Returns the offset just past the 0x00 sub-block terminator
  ## starting at `pos` (which points at the first sub-block size byte).
  var p = pos
  while true:
    if p >= data.len:
      raise newException(StripError,
        "truncated GIF extension at offset " & $pos)
    let n = ord(data[p])
    inc p
    if n == 0:
      break
    if p + n > data.len:
      raise newException(StripError,
        "truncated GIF sub-block at offset " & $p)
    p += n
  result = p

proc stripGifData*(data: string): tuple[output: string, res: StripResult] =
  var res: StripResult
  res.bytesIn = data.len
  if data.len < 13:
    raise newException(StripError, "file too small to be a GIF file")
  let magic = data[0 .. 5]
  if magic != "GIF87a" and magic != "GIF89a":
    raise newException(StripError, "not a GIF file (missing GIF magic)")
  var output = newStringOfCap(data.len)
  output.add(data[0 .. 5])
  # Logical screen descriptor.
  let packed = ord(data[10])
  output.add(data[6 .. 12])
  res.kept.add(ChunkReport(id: "HDR", size: 13, action: caKeep))
  var pos = 13
  if (packed and 0x80) != 0:
    let gctSize = 3 * (1 shl ((packed and 0x07) + 1))
    if pos + gctSize > data.len:
      raise newException(StripError, "truncated GIF global color table")
    output.add(data[pos ..< pos + gctSize])
    pos += gctSize
  var sawTrailer = false
  while pos < data.len:
    let sep = ord(data[pos])
    case sep
    of 0x21: # Extension.
      if pos + 2 > data.len:
        raise newException(StripError, "truncated GIF extension label")
      let extLabel = ord(data[pos + 1])
      let endPos = readSubBlocks(data, pos + 2)
      let total = endPos - pos
      case extLabel
      of 0xF9: # Graphic control extension: needed for rendering.
        res.kept.add(ChunkReport(id: "GCE", size: uint32(total),
          action: caKeep))
        output.add(data[pos ..< endPos])
      of 0xFE: # Comment extension.
        res.dropped.add(ChunkReport(id: "COMMENT", size: uint32(total),
          action: caDrop))
      of 0x01: # Plain text extension.
        res.dropped.add(ChunkReport(id: "TEXT", size: uint32(total),
          action: caDrop))
      of 0xFF: # Application extension.
        var appId = ""
        if pos + 2 + 11 + 1 <= data.len and ord(data[pos + 2]) == 11:
          appId = data[pos + 3 .. pos + 13]
        if appId == "NETSCAPE2.0":
          res.kept.add(ChunkReport(id: "NETSCAPE", size: uint32(total),
            action: caKeep))
          output.add(data[pos ..< endPos])
        else:
          let short =
            if appId.len >= 8: appId[0 .. 7]
            else: "APP"
          res.dropped.add(ChunkReport(id: "APP-" & short,
            size: uint32(total), action: caDrop))
      else:
        raise newException(StripError,
          "unknown GIF extension label 0x" & $extLabel)
      pos = endPos
    of 0x2C: # Image descriptor.
      if pos + 10 > data.len:
        raise newException(StripError, "truncated GIF image descriptor")
      let ipacked = ord(data[pos + 9])
      var total = 10
      if (ipacked and 0x80) != 0:
        total += 3 * (1 shl ((ipacked and 0x07) + 1))
      if pos + total + 1 > data.len:
        raise newException(StripError, "truncated GIF image data")
      let imgEnd = readSubBlocks(data, pos + total + 1)
      let blockLen = imgEnd - pos
      res.kept.add(ChunkReport(id: "IMG", size: uint32(blockLen),
        action: caKeep))
      output.add(data[pos ..< imgEnd])
      pos = imgEnd
    of 0x3B: # Trailer.
      output.add(data[pos])
      res.kept.add(ChunkReport(id: "TRL", size: 1, action: caKeep))
      pos += 1
      sawTrailer = true
      break
    else:
      raise newException(StripError,
        "invalid GIF block separator 0x" & $sep & " at offset " & $pos)
  if not sawTrailer:
    raise newException(StripError, "truncated GIF file (missing trailer)")
  if pos != data.len:
    raise newException(StripError,
      "trailing garbage after GIF trailer (" &
      $(data.len - pos) & " bytes)")
  res.bytesOut = output.len
  result = (output: output, res: res)

proc analyzeGifData*(data: string): StripResult =
  let (_, res) = stripGifData(data)
  result = res

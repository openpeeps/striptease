# PNG metadata stripper.
# Rebuilds the file keeping only rendering-critical and structural
# chunks. Textual metadata (tEXt, zTXt, iTXt), embedded EXIF (eXIf),
# ICC profiles (iCCP) and timestamps (tIME) are dropped.
#
# Keep list: IHDR, PLTE, IDAT, IEND (structural), tRNS (transparency),
# sRGB, gAMA, cHRM, sBIT (color), bKGD, hIST, pHYs, sPLT (rendering),
# acTL, fcTL, fdAT (APNG animation).

import stripapi

export stripapi

const pngSig = "\x89PNG\x0D\x0A\x1A\x0A"

const pngSignature* = pngSig

func isKeepChunk*(id: string): bool =
  case id
  of "IHDR", "PLTE", "IDAT", "IEND", "tRNS",
     "sRGB", "gAMA", "cHRM", "sBIT", "bKGD",
     "hIST", "pHYs", "sPLT",
     "acTL", "fcTL", "fdAT":
    true
  else:
    false

var crcTable: array[256, uint32]
var crcReady = false

proc initCrc() =
  if crcReady:
    return
  for i in 0 ..< 256:
    var c = uint32(i)
    for _ in 0 ..< 8:
      if (c and 1) != 0:
        c = 0xEDB88320u32 xor (c shr 1)
      else:
        c = c shr 1
    crcTable[i] = c
  crcReady = true

proc crc32(chunkType: string, payload: string): uint32 =
  initCrc()
  var c = 0xFFFFFFFFu32
  for ch in chunkType:
    c = crcTable[(c xor uint32(ord(ch))) and 0xFF] xor (c shr 8)
  for ch in payload:
    c = crcTable[(c xor uint32(ord(ch))) and 0xFF] xor (c shr 8)
  result = c xor 0xFFFFFFFFu32

func getBe32(buf: string, pos: int): uint32 =
  (uint32(ord(buf[pos])) shl 24) or
    (uint32(ord(buf[pos + 1])) shl 16) or
    (uint32(ord(buf[pos + 2])) shl 8) or
    uint32(ord(buf[pos + 3]))

proc putBe32(v: uint32): string =
  result = newString(4)
  result[0] = chr(int((v shr 24) and 0xFF))
  result[1] = chr(int((v shr 16) and 0xFF))
  result[2] = chr(int((v shr 8) and 0xFF))
  result[3] = chr(int(v and 0xFF))

proc stripPngData*(data: string): tuple[output: string, res: StripResult] =
  var res: StripResult
  res.bytesIn = data.len
  if data.len < 8 or data[0 .. 7] != pngSig:
    raise newException(StripError, "not a PNG file (missing PNG signature)")
  var output = newStringOfCap(data.len)
  output.add(pngSig)
  var pos = 8
  var sawIhdr = false
  var sawIend = false
  var sawIdat = false
  while pos + 8 <= data.len:
    let length = getBe32(data, pos)
    if int(length) < 0 or uint64(pos) + 12u64 + uint64(length) > uint64(data.len):
      raise newException(StripError,
        "truncated PNG chunk at offset " & $pos & " (declared " &
        $length & " bytes, file ends early)")
    let id = data[pos + 4 .. pos + 7]
    let payloadStart = pos + 8
    let payloadEnd = payloadStart + int(length)
    let payload =
      if length == 0: ""
      else: data[payloadStart ..< payloadEnd]
    let storedCrc = getBe32(data, payloadEnd)
    if crc32(id, payload) != storedCrc:
      raise newException(StripError,
        "corrupt PNG chunk '" & id & "' (CRC mismatch)")
    if sawIend:
      raise newException(StripError,
        "trailing garbage after PNG IEND (" &
        $(data.len - pos) & " bytes)")
    if not sawIhdr and id != "IHDR":
      raise newException(StripError,
        "invalid PNG file (first chunk is not IHDR)")
    if id == "IHDR":
      if sawIhdr:
        raise newException(StripError, "invalid PNG file (duplicate IHDR)")
      if length != 13:
        raise newException(StripError, "invalid PNG IHDR chunk length")
      sawIhdr = true
    if id == "IDAT":
      sawIdat = true
    if id == "IEND":
      sawIend = true
      if length != 0:
        raise newException(StripError, "invalid PNG IEND chunk length")
    if isKeepChunk(id):
      res.kept.add(ChunkReport(id: id, size: length, action: caKeep))
      output.add(putBe32(length))
      output.add(id)
      output.add(payload)
      output.add(putBe32(crc32(id, payload)))
    else:
      res.dropped.add(ChunkReport(id: id, size: length, action: caDrop))
    pos = payloadEnd + 4
  if pos != data.len:
    raise newException(StripError,
      "truncated PNG file (ends mid-chunk at offset " & $pos & ")")
  if not sawIhdr:
    raise newException(StripError, "invalid PNG file (missing IHDR)")
  if not sawIdat:
    raise newException(StripError, "invalid PNG file (missing IDAT)")
  if not sawIend:
    raise newException(StripError, "truncated PNG file (missing IEND)")
  res.bytesOut = output.len
  result = (output: output, res: res)

proc analyzePngData*(data: string): StripResult =
  let (_, res) = stripPngData(data)
  result = res

proc encodeChunk*(id, payload: string): string =
  ## Builds a PNG chunk (length + type + payload + CRC) for tests
  ## and tooling.
  assert id.len == 4
  result = putBe32(uint32(payload.len)) & id & payload &
    putBe32(crc32(id, payload))

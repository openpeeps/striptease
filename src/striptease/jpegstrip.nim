# JPEG metadata stripper.
# Parses JPEG markers and rebuilds the file keeping only image data
# segments. All APP0-APP15 segments (EXIF, XMP, ICC, Photoshop,
# thumbnails) and COM comments are dropped. Everything after the
# first SOS (entropy-coded scan data) is copied verbatim.

import std/strutils
import stripapi

export stripapi

func be16(buf: string, pos: int): int =
  (ord(buf[pos]) shl 8) or ord(buf[pos + 1])

func markerName(code: int): string =
  case code
  of 0xE0 .. 0xEF:
    "APP" & $(code - 0xE0)
  of 0xFE:
    "COM"
  of 0xDB:
    "DQT"
  of 0xC0:
    "SOF0"
  of 0xC1:
    "SOF1"
  of 0xC2:
    "SOF2"
  of 0xC4:
    "DHT"
  of 0xDD:
    "DRI"
  of 0xDA:
    "SOS"
  of 0xD0 .. 0xD7:
    "RST" & $(code - 0xD0)
  of 0x01:
    "TEM"
  else:
    "M" & toHex(code, 2)

func isMetadataMarker(code: int): bool =
  (code >= 0xE0 and code <= 0xEF) or code == 0xFE

func isStandalone(code: int): bool =
  code == 0x01 or (code >= 0xD0 and code <= 0xD9)

proc stripJpegData*(data: string): tuple[output: string, res: StripResult] =
  var res: StripResult
  res.bytesIn = data.len
  if data.len < 4:
    raise newException(StripError, "file too small to be a JPEG file")
  if ord(data[0]) != 0xFF or ord(data[1]) != 0xD8:
    raise newException(StripError, "not a JPEG file (missing SOI magic)")
  var output = newStringOfCap(data.len)
  output.add('\xFF')
  output.add('\xD8')
  res.kept.add(ChunkReport(id: "SOI", size: 0, action: caKeep))
  var pos = 2
  var sawEoi = false
  while pos < data.len:
    if ord(data[pos]) != 0xFF:
      raise newException(StripError,
        "invalid JPEG marker at offset " & $pos)
    var j = pos
    while j < data.len and ord(data[j]) == 0xFF:
      inc j
    if j >= data.len:
      raise newException(StripError, "truncated JPEG marker at end of file")
    let code = ord(data[j])
    if code == 0x00:
      raise newException(StripError,
        "invalid JPEG marker at offset " & $pos &
        " (stuffed FF00 outside scan)")
    if isStandalone(code):
      if code == 0xD9:
        output.add('\xFF')
        output.add(chr(code))
        res.kept.add(ChunkReport(id: "EOI", size: 0, action: caKeep))
        pos = j + 1
        sawEoi = true
        break
      output.add('\xFF')
      output.add(chr(code))
      res.kept.add(ChunkReport(id: markerName(code), size: 0,
        action: caKeep))
      pos = j + 1
      continue
    if j + 2 >= data.len:
      raise newException(StripError,
        "truncated JPEG segment '" & markerName(code) & "' (missing length)")
    let segLen = be16(data, j + 1)
    if segLen < 2:
      raise newException(StripError,
        "invalid JPEG segment length for '" & markerName(code) & "'")
    let segEnd = j + 1 + segLen
    if segEnd > data.len:
      raise newException(StripError,
        "truncated JPEG segment '" & markerName(code) & "' (declared " &
        $segLen & " bytes, file ends early)")
    let payloadLen = segLen - 2
    let name = markerName(code)
    if isMetadataMarker(code):
      res.dropped.add(ChunkReport(id: name, size: uint32(payloadLen),
        action: caDrop))
    else:
      res.kept.add(ChunkReport(id: name, size: uint32(payloadLen),
        action: caKeep))
      output.add('\xFF')
      output.add(chr(code))
      output.add(data[j + 1])
      output.add(data[j + 2])
      for k in (j + 3) ..< (j + 1 + segLen):
        output.add(data[k])
    pos = segEnd
    if code == 0xDA:
      # SOS header consumed; entropy-coded scan data plus all
      # following markers are copied verbatim.
      if pos >= data.len:
        raise newException(StripError,
          "truncated JPEG file (missing scan data after SOS)")
      for k in pos ..< data.len:
        output.add(data[k])
      if data.len < 2 or ord(data[^2]) != 0xFF or ord(data[^1]) != 0xD9:
        raise newException(StripError, "JPEG missing EOI marker")
      sawEoi = true
      pos = data.len
      break
  if not sawEoi:
    raise newException(StripError, "JPEG missing EOI marker")
  if pos != data.len:
    raise newException(StripError,
      "trailing garbage after JPEG EOI (" & $(data.len - pos) & " bytes)")
  res.bytesOut = output.len
  result = (output: output, res: res)

proc analyzeJpegData*(data: string): StripResult =
  let (_, res) = stripJpegData(data)
  result = res

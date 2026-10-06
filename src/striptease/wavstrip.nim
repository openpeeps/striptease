# WAV metadata stripper.
# Parses classic RIFF/WAVE files and rebuilds them keeping
# only essential audio chunks. Everything else (LIST INFO,
# ID3 artwork, bext, iXML and friends) is dropped.

import stripapi

func getLe32(buf: string, pos: int): uint32 =
  result = uint32(ord(buf[pos])) or
    (uint32(ord(buf[pos + 1])) shl 8) or
    (uint32(ord(buf[pos + 2])) shl 16) or
    (uint32(ord(buf[pos + 3])) shl 24)

func putLe32(v: uint32): string =
  result = newString(4)
  result[0] = chr(int(v and 0xFF))
  result[1] = chr(int((v shr 8) and 0xFF))
  result[2] = chr(int((v shr 16) and 0xFF))
  result[3] = chr(int((v shr 24) and 0xFF))

func isKeepChunk*(id: string, keepMusical: bool): bool =
  if id == "fmt " or id == "fact" or id == "data":
    return true
  if keepMusical:
    if id == "cue " or id == "smpl" or id == "inst" or id == "acid":
      return true
  return false

type
  KeptChunk = object
    id: string
    size: uint32
    payload: string

proc parseWav(data: string, keepMusical: bool,
    res: var StripResult): seq[KeptChunk] =
  if data.len < 12:
    raise newException(StripError, "file too small to be a WAV file")
  let magic = data[0 .. 3]
  if magic == "RF64":
    raise newException(StripError,
      "RF64 files are not supported in v1 (classic RIFF only)")
  if magic != "RIFF":
    raise newException(StripError, "not a RIFF file (missing RIFF magic)")
  if data[8 .. 11] != "WAVE":
    raise newException(StripError, "not a WAVE file (missing WAVE magic)")
  var pos = 12
  while pos + 8 <= data.len:
    let id = data[pos .. pos + 3]
    let size = getLe32(data, pos + 4)
    let payloadStart = pos + 8
    if uint64(payloadStart) + uint64(size) > uint64(data.len):
      raise newException(StripError,
        "truncated chunk '" & id & "' (declared " & $size &
        " bytes, file ends early)")
    let payload =
      if size == 0: ""
      else: data[payloadStart ..< payloadStart + int(size)]
    if isKeepChunk(id, keepMusical):
      res.kept.add(ChunkReport(id: id, size: size, action: caKeep))
      result.add(KeptChunk(id: id, size: size, payload: payload))
    else:
      res.dropped.add(ChunkReport(id: id, size: size, action: caDrop))
    pos = payloadStart + int(size)
    if (size and 1u32) == 1u32:
      if pos < data.len:
        pos += 1
  if pos < data.len:
    let trailing = data.len - pos
    if trailing > 1:
      raise newException(StripError,
        "trailing garbage after last chunk (" & $trailing & " bytes)")

proc buildWav(kept: seq[KeptChunk]): string =
  var body = "WAVE"
  for c in kept:
    body.add(c.id)
    body.add(putLe32(c.size))
    body.add(c.payload)
    if (c.size and 1u32) == 1u32:
      body.add('\0')
  result = "RIFF" & putLe32(uint32(body.len)) & body

proc stripWavData*(data: string, keepMusical: bool): tuple[output: string,
    res: StripResult] =
  var res: StripResult
  res.bytesIn = data.len
  let kept = parseWav(data, keepMusical, res)
  var hasFmt = false
  var hasData = false
  for c in kept:
    if c.id == "fmt ":
      hasFmt = true
    if c.id == "data":
      hasData = true
  if not hasFmt:
    raise newException(StripError, "WAV has no fmt chunk")
  if not hasData:
    raise newException(StripError, "WAV has no data chunk")
  let output = buildWav(kept)
  res.bytesOut = output.len
  result = (output: output, res: res)

proc analyzeWavData*(data: string, keepMusical: bool): StripResult =
  let (_, res) = stripWavData(data, keepMusical)
  result = res

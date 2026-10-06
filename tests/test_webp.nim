import std/strutils
import unittest

import striptease/stripapi
import striptease/webpstrip

proc le32(v: uint32): string =
  result = newString(4)
  result[0] = chr(int(v and 0xFF))
  result[1] = chr(int((v shr 8) and 0xFF))
  result[2] = chr(int((v shr 16) and 0xFF))
  result[3] = chr(int((v shr 24) and 0xFF))

proc chunk(id, payload: string): string =
  assert id.len == 4
  result = id & le32(uint32(payload.len)) & payload
  if (payload.len mod 2) == 1:
    result.add('\0')

proc webpFile(chunks: seq[(string, string)]): string =
  var body = "WEBP"
  for (id, payload) in chunks:
    body.add(chunk(id, payload))
  result = "RIFF" & le32(uint32(body.len)) & body

suite "webp stripping":
  test "lossy file passes through":
    let data = webpFile(@[("VP8 ", "framedata")])
    let (output, res) = stripWebpData(data)
    check res.dropped.len == 0
    check output == data

  test "exif plus xmp plus iccp are dropped":
    let data = webpFile(@[("VP8X", "canvas1234"),
      ("ICCP", "profile"), ("EXIF", "exifdata"),
      ("XMP ", "xmpdata!"), ("VP8 ", "framedata")])
    let (output, res) = stripWebpData(data)
    check res.dropped.len == 3
    check "exifdata" notin output
    check output.len < data.len
    let (output2, res2) = stripWebpData(output)
    check res2.dropped.len == 0
    check output2 == output

  test "odd size payload padding stays valid":
    let data = webpFile(@[("VP8L", "abc"), ("XMP ", "12345"),
      ("ALPH", "a")])
    let (output, res) = stripWebpData(data)
    check res.dropped.len == 1
    check output.len mod 2 == 0
    let (_, res2) = stripWebpData(output)
    check res2.kept.len == 2

  test "missing image chunk raises":
    let data = webpFile(@[("EXIF", "exifdata")])
    expect StripError:
      discard stripWebpData(data)

  test "truncated chunk raises":
    var data = webpFile(@[("VP8 ", "framedata")])
    data = data[0 ..< data.len - 2]
    expect StripError:
      discard stripWebpData(data)

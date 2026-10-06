import unittest

import striptease/stripapi
import striptease/wavstrip

proc le32(v: uint32): string =
  result = newString(4)
  result[0] = chr(int(v and 0xFF))
  result[1] = chr(int((v shr 8) and 0xFF))
  result[2] = chr(int((v shr 16) and 0xFF))
  result[3] = chr(int((v shr 24) and 0xFF))

proc chunk(id: string, payload: string): string =
  assert id.len == 4
  result = id & le32(uint32(payload.len)) & payload
  if (payload.len mod 2) == 1:
    result.add('\0')

proc wavFile(chunks: seq[(string, string)]): string =
  var body = "WAVE"
  for (id, payload) in chunks:
    body.add(chunk(id, payload))
  result = "RIFF" & le32(uint32(body.len)) & body

suite "wav stripping":
  test "fmt plus data passes through":
    let data = wavFile(@[("fmt ", "1234567890123456"), ("data", "abcd")])
    let (output, res) = stripWavData(data, false)
    check res.kept.len == 2
    check res.dropped.len == 0
    check res.bytesSaved() == 0
    check output == data

  test "LIST INFO is dropped":
    let data = wavFile(@[("fmt ", "1234567890123456"),
      ("LIST", "INFOINAMsong"), ("data", "abcd")])
    let (output, res) = stripWavData(data, false)
    check res.kept.len == 2
    check res.dropped.len == 1
    check res.dropped[0].id == "LIST"
    check res.bytesSaved() > 0
    let (_, res2) = stripWavData(output, false)
    check res2.dropped.len == 0

  test "id3 artwork plus bext plus iXML are dropped":
    let data = wavFile(@[("fmt ", "1234567890123456"),
      ("id3 ", "artworkbytes"), ("bext", "desc"), ("iXML", "comment"),
      ("data", "abcd")])
    let (output, res) = stripWavData(data, false)
    check res.dropped.len == 3
    check output.len < data.len
    let (output2, _) = stripWavData(output, false)
    check output2 == output

  test "odd size payload padding stays valid":
    let data = wavFile(@[("fmt ", "1234567890123456"),
      ("LIST", "abc"), ("data", "x")])
    let (output, res) = stripWavData(data, false)
    check res.dropped.len == 1
    check output.len mod 2 == 0
    let (_, res2) = stripWavData(output, false)
    check res2.kept.len == 2

  test "smpl dropped by default, kept with flag":
    let data = wavFile(@[("fmt ", "1234567890123456"),
      ("smpl", "looppoints"), ("data", "abcd")])
    let (outStrict, resStrict) = stripWavData(data, false)
    check resStrict.dropped.len == 1
    let (outMusical, resMusical) = stripWavData(data, true)
    check resMusical.dropped.len == 0
    check resMusical.kept.len == 3
    check outMusical.len > outStrict.len

  test "missing fmt raises":
    let data = wavFile(@[("data", "abcd")])
    expect StripError:
      discard stripWavData(data, false)

  test "truncated chunk raises":
    var data = wavFile(@[("fmt ", "1234567890123456"), ("data", "abcd")])
    data = data[0 ..< data.len - 2]
    expect StripError:
      discard stripWavData(data, false)

  test "RF64 rejected":
    var data = wavFile(@[("fmt ", "1234567890123456"), ("data", "abcd")])
    data[0 .. 3] = "RF64"
    expect StripError:
      discard stripWavData(data, false)

import std/strutils
import unittest

import striptease/stripapi
import striptease/gifstrip

proc commentExt(text: string): string =
  result = "\x21\xFE"
  var i = 0
  while i < text.len:
    let n = min(255, text.len - i)
    result.add(chr(n))
    result.add(text[i ..< i + n])
    i += n
  result.add('\0')

proc appExt(appId, payload: string): string =
  assert appId.len == 11
  result = "\x21\xFF\x0B" & appId
  result.add(chr(payload.len))
  result.add(payload)
  result.add('\0')

proc gce(): string =
  "\x21\xF9\x04\x00\x00\x00\x00\x00"

proc imageBlock(): string =
  # 10-byte descriptor (no local color table) + LZW min code +
  # one sub-block + terminator.
  "\x2C\x00\x00\x00\x00\x01\x00\x01\x00\x00" & "\x02\x01\x00\x00"

proc gifFile(blocks: seq[string]): string =
  result = "GIF89a" & "\x01\x00\x01\x00\x00\x00\x00"
  for b in blocks:
    result.add(b)
  result.add("\x3B")

suite "gif stripping":
  test "clean file passes through":
    let data = gifFile(@[gce(), imageBlock()])
    let (output, res) = stripGifData(data)
    check res.dropped.len == 0
    check output == data

  test "comment plus text plus xmp app are dropped":
    let data = gifFile(@[commentExt("hello"), gce(),
      appExt("XMP DataXMP", "xmpbytes"), imageBlock()])
    let (output, res) = stripGifData(data)
    check res.dropped.len == 2
    check "hello" notin output
    check "xmpbytes" notin output
    let (output2, res2) = stripGifData(output)
    check res2.dropped.len == 0
    check output2 == output

  test "netscape looping is kept":
    let data = gifFile(@[appExt("NETSCAPE2.0", "\x01\x00\x00"),
      gce(), imageBlock()])
    let (output, res) = stripGifData(data)
    check res.dropped.len == 0
    check "NETSCAPE2.0" in output
    check output == data

  test "missing trailer raises":
    var data = gifFile(@[gce(), imageBlock()])
    data = data[0 ..< data.len - 1]
    expect StripError:
      discard stripGifData(data)

  test "bad magic raises":
    expect StripError:
      discard stripGifData("NOTAGIF89a...")

import std/strutils
import unittest

import striptease/stripapi
import striptease/jpegstrip

proc seg(code: int, payload: string): string =
  assert code != 0xD8 and code != 0xD9
  let n = payload.len + 2
  result = "\xFF" & chr(code) & chr((n shr 8) and 0xFF) &
    chr(n and 0xFF) & payload

proc jpegFile(segs: seq[(int, string)], scan: string): string =
  result = "\xFF\xD8"
  for (code, payload) in segs:
    result.add(seg(code, payload))
  result.add(seg(0xDA, "scanhd")) # SOS header
  result.add(scan)
  result.add("\xFF\xD9")

suite "jpeg stripping":
  test "clean file passes through":
    let data = jpegFile(@[(0xDB, "qtable"), (0xC0, "frame"),
      (0xC4, "huff")], "\x01\x02\x03")
    let (output, res) = stripJpegData(data)
    check res.dropped.len == 0
    check res.bytesSaved() == 0
    check output == data

  test "APP1 plus COM are dropped":
    let data = jpegFile(@[(0xE0, "JFIFffi"), (0xE1, "Exifdata"),
      (0xFE, "comment"), (0xDB, "qtable"), (0xC0, "frame")],
      "\x01\x02\x03")
    let (output, res) = stripJpegData(data)
    check res.dropped.len == 3
    check "Exifdata" notin output
    check "comment" notin output
    check output.len < data.len
    let (output2, res2) = stripJpegData(output)
    check res2.dropped.len == 0
    check output2 == output

  test "byte-stuffed scan survives":
    let scan = "\xFF\x00\x11\xFF\x00\x22"
    let data = jpegFile(@[(0xE1, "exif"), (0xC0, "frame")], scan)
    let (output, res) = stripJpegData(data)
    check res.dropped.len == 1
    check res.dropped[0].id == "APP1"
    check output.endsWith("\xFF\xD9")
    let (_, res2) = stripJpegData(output)
    check res2.dropped.len == 0

  test "missing SOI raises":
    expect StripError:
      discard stripJpegData("\xFF\xD9" & "junk")

  test "missing EOI raises":
    var data = jpegFile(@[(0xC0, "frame")], "\x01\x02")
    data = data[0 ..< data.len - 2]
    expect StripError:
      discard stripJpegData(data)

  test "truncated APP raises":
    var data = jpegFile(@[(0xE1, "exifdata"), (0xC0, "frame")],
      "\x01\x02")
    data = data[0 ..< data.len - 3]
    expect StripError:
      discard stripJpegData(data)

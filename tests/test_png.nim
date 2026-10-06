import unittest

import striptease/stripapi
import striptease/pngstrip

proc pngFile(chunks: seq[(string, string)]): string =
  result = pngSignature
  for (id, payload) in chunks:
    result.add(encodeChunk(id, payload))

suite "png stripping":
  test "minimal file passes through":
    let data = pngFile(@[("IHDR", "1234567890123"),
      ("IDAT", "imagedata"), ("IEND", "")])
    let (output, res) = stripPngData(data)
    check res.dropped.len == 0
    check output == data

  test "text plus exif plus iccp plus time are dropped":
    let data = pngFile(@[("IHDR", "1234567890123"),
      ("tEXt", "Title\x00hi"), ("iTXt", "kw\x00\x00\x00\x00\x00txt"),
      ("eXIf", "exifbytes"), ("iCCP", "profile"),
      ("tIME", "1234567"), ("IDAT", "imagedata"), ("IEND", "")])
    let (output, res) = stripPngData(data)
    check res.dropped.len == 5
    check output.len < data.len
    let (output2, res2) = stripPngData(output)
    check res2.dropped.len == 0
    check output2 == output

  test "color and transparency chunks are kept":
    let data = pngFile(@[("IHDR", "1234567890123"),
      ("sRGB", "\x00"), ("gAMA", "1234"), ("tRNS", "\x00"),
      ("IDAT", "imagedata"), ("IEND", "")])
    let (_, res) = stripPngData(data)
    check res.dropped.len == 0
    check res.kept.len == 6

  test "corrupt CRC raises":
    var data = pngFile(@[("IHDR", "1234567890123"),
      ("IDAT", "imagedata"), ("IEND", "")])
    data[^1] = chr(ord(data[^1]) xor 0xFF)
    expect StripError:
      discard stripPngData(data)

  test "missing IDAT raises":
    let data = pngFile(@[("IHDR", "1234567890123"), ("IEND", "")])
    expect StripError:
      discard stripPngData(data)

  test "missing IEND raises":
    let data = pngFile(@[("IHDR", "1234567890123"),
      ("IDAT", "imagedata")])
    expect StripError:
      discard stripPngData(data)

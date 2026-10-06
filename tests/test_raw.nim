import std/strutils
import std/json
import unittest

import striptease/stripapi
import striptease/rawstrip

# Little-endian TIFF fixture builder. Layout (all offsets absolute):
# header(8) IFD0@8[9 entries] exif@174 gps@260 makernote@374 xmp@394
# subifd@412 thumbJPEG@471. Total 505 bytes.

proc u16le(v: int): string =
  result = newString(2)
  result[0] = chr(v and 0xFF)
  result[1] = chr((v shr 8) and 0xFF)

proc u32le(v: uint32): string =
  result = newString(4)
  result[0] = chr(int(v and 0xFF))
  result[1] = chr(int((v shr 8) and 0xFF))
  result[2] = chr(int((v shr 16) and 0xFF))
  result[3] = chr(int((v shr 24) and 0xFF))

proc entry(tag, typ: int, cnt: uint32, off: uint32): string =
  u16le(tag) & u16le(typ) & u32le(cnt) & u32le(off)

proc inlineStr(s: string): uint32 =
  assert s.len <= 4
  var v = 0u32
  for i, ch in s:
    v = v or (uint32(ord(ch)) shl (8 * i))
  result = v

proc thumbJpeg(): string =
  # SOI, APP1 with EXIF payload, SOF0, SOS header, 2 scan bytes, EOI.
  "\xFF\xD8" & "\xFF\xE1" & "\x00\x0D" & "Exifsecret!" &
    "\xFF\xC0" & "\x00\x05" & "frm" &
    "\xFF\xDA" & "\x00\x04" & "hd" & "\x01\x02" & "\xFF\xD9"

proc rawFile(): string =
  let thumb = thumbJpeg()
  assert thumb.len == 34
  let exifOff = 174
  let gpsOff = 260
  let mkOff = 374
  let xmpOff = 394
  let subOff = 412
  let thumbOff = 471
  var ifd0 = u16le(9)
  ifd0.add(entry(271, 2, 6, 122)) # Make "Canon\0"
  ifd0.add(entry(315, 2, 14, 128)) # Artist
  ifd0.add(entry(33432, 2, 12, 142)) # Copyright
  ifd0.add(entry(306, 2, 20, 154)) # DateTime
  ifd0.add(entry(34665, 4, 1, uint32(exifOff)))
  ifd0.add(entry(34853, 4, 1, uint32(gpsOff)))
  ifd0.add(entry(37500, 7, 20, uint32(mkOff)))
  ifd0.add(entry(700, 7, 18, uint32(xmpOff)))
  ifd0.add(entry(330, 4, 1, uint32(subOff)))
  ifd0.add(u32le(0)) # next IFD
  assert ifd0.len == 114
  var exif = u16le(3)
  exif.add(entry(36867, 2, 20, 216)) # DateTimeOriginal
  exif.add(entry(37510, 7, 16, 236)) # UserComment
  exif.add(entry(33437, 5, 1, 252)) # ExposureTime 1/100
  exif.add(u32le(0))
  var gps = u16le(5)
  gps.add(entry(0, 1, 4, inlineStr("\x02\x03\x00\x00"))) # version
  gps.add(entry(1, 2, 2, inlineStr("N\x00\x00\x00")))
  gps.add(entry(2, 5, 3, 326)) # 48/1 30/1 0/1
  gps.add(entry(3, 2, 2, inlineStr("E\x00\x00\x00")))
  gps.add(entry(4, 5, 3, 350)) # 11/1 5/1 0/1
  gps.add(u32le(0))
  var sub = u16le(3)
  sub.add(entry(315, 2, 17, 454)) # SubIFD Artist
  sub.add(entry(513, 4, 1, uint32(thumbOff)))
  sub.add(entry(514, 4, 1, uint32(thumb.len)))
  sub.add(u32le(0))
  result = "II" & u16le(42) & u32le(8) & ifd0
  assert result.len == 122
  result.add("Canon\x00")
  result.add("secret-artist\x00")
  result.add("secret-copy\x00")
  result.add("2024:01:01 00:00:00\x00")
  assert result.len == exifOff
  result.add(exif)
  result.add("2024:05:05 12:00:00\x00")
  result.add("secret-comment!!")
  result.add(u32le(1) & u32le(100))
  assert result.len == gpsOff
  result.add(gps)
  result.add(u32le(48) & u32le(1) & u32le(30) & u32le(1) & u32le(0) &
    u32le(1))
  result.add(u32le(11) & u32le(1) & u32le(5) & u32le(1) & u32le(0) &
    u32le(1))
  assert result.len == mkOff
  result.add("0123456789ABCDEFGHIJ")
  assert result.len == xmpOff
  result.add("secret-xmp-payload")
  assert result.len == subOff
  result.add(sub)
  result.add("secret-subartist\x00")
  assert result.len == thumbOff
  result.add(thumb)
  assert result.len == 505

proc hasDropped(res: StripResult, id: string): bool =
  for d in res.dropped:
    if d.id == id:
      return true
  return false

suite "raw stripping":
  test "text plus gps plus xmp are zeroed, makernote preserved":
    let data = rawFile()
    let (output, res) = stripRawData(data)
    check output.len == data.len
    check "secret-artist" notin output
    check "secret-copy" notin output
    check "2024:01:01" notin output
    check "2024:05:05" notin output
    check "secret-comment!!" notin output
    check "secret-subartist" notin output
    check "secret-xmp-payload" notin output
    check "Exifsecret!" notin output
    # MakerNote is preserved: Apple decoders refuse files without it.
    check "0123456789ABCDEFGHIJ" in output
    check not hasDropped(res, "MakerNote")
    check hasDropped(res, "Artist")
    check hasDropped(res, "Copyright")
    check hasDropped(res, "DateTime")
    check hasDropped(res, "DateTimeOriginal")
    check hasDropped(res, "UserComment")
    check hasDropped(res, "GPS")
    check hasDropped(res, "XMP")
    check hasDropped(res, "THMB")

  test "technical tags survive":
    let data = rawFile()
    let (output, _) = stripRawData(data)
    check "Canon" in output
    check output[326 ..< 334] == "\0\0\0\0\0\0\0\0" # GPS latitude zeroed
    # ExposureTime rationals intact.
    check output[252 ..< 260] == u32le(1) & u32le(100)
    # Thumbnail still a JPEG.
    check output[471 .. 472] == "\xFF\xD8"
    check output[^2 .. ^1] == "\xFF\xD9"

  test "output is stable":
    let data = rawFile()
    let (output, _) = stripRawData(data)
    let (output2, _) = stripRawData(output)
    check output2 == output
    let meta = inspectRawData(output)
    check meta["ifds"][0]["tags"]["Artist"].getStr() == ""

  test "inspect decodes values and gps":
    let data = rawFile()
    let meta = inspectRawData(data)
    check meta["byteOrder"].getStr() == "II"
    check meta["ifds"][0]["tags"]["Artist"].getStr() == "secret-artist"
    check meta["ifds"][0]["tags"]["Make"].getStr() == "Canon"
    check meta["ifds"][0]["makerNote"].getInt() == 20
    check meta["ifds"][0]["xmp"].getInt() == 18
    let gps = meta["ifds"][0]["gps"]
    check abs(gps["latitude"].getFloat() - 48.5) < 0.0001
    check abs(gps["longitude"].getFloat() - (11.0 + 5.0 / 60.0)) < 0.0001

  test "big-endian file works":
    var data = "MM\x00\x2A\x00\x00\x00\x08"
    proc u16be(v: int): string =
      result = newString(2)
      result[0] = chr((v shr 8) and 0xFF)
      result[1] = chr(v and 0xFF)
    proc u32be(v: uint32): string =
      result = newString(4)
      result[0] = chr(int((v shr 24) and 0xFF))
      result[1] = chr(int((v shr 16) and 0xFF))
      result[2] = chr(int((v shr 8) and 0xFF))
      result[3] = chr(int(v and 0xFF))
    var ifd = u16be(2)
    ifd.add(u16be(271) & u16be(2) & u32be(6) & u32be(38))
    ifd.add(u16be(315) & u16be(2) & u32be(14) & u32be(44))
    ifd.add(u32be(0))
    data.add(ifd)
    data.add("Canon\x00")
    data.add("secret-artist\x00")
    let (output, res) = stripRawData(data)
    check output.len == data.len
    check "secret-artist" notin output
    check "Canon" in output
    check hasDropped(res, "Artist")
    check inspectRawData(data)["byteOrder"].getStr() == "MM"

  test "CR2-flavored header parses":
    var data = "II" & u16le(42) & u32le(16) & "CR\x02\x00\x00\x00\x00\x00"
    assert data.len == 16
    var ifd = u16le(3)
    ifd.add(entry(271, 2, 6, 58))
    ifd.add(entry(315, 2, 14, 64))
    ifd.add(entry(305, 2, 12, 78))
    ifd.add(u32le(0))
    data.add(ifd)
    data.add("Canon\x00")
    data.add("secret-artist\x00")
    data.add("LavcTest\x00\x00\x00\x00")
    let (output, res) = stripRawData(data)
    check "secret-artist" notin output
    check "LavcTest" notin output
    check "Canon" in output
    check hasDropped(res, "Artist")
    check hasDropped(res, "Software")

  test "bad magic raises":
    expect StripError:
      discard stripRawData("NOTATIFF....")
    expect StripError:
      discard inspectRawData("NOTATIFF....")

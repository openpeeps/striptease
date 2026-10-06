import std/strutils
import std/json
import unittest

import striptease/stripapi
import striptease/cr3strip

proc be16(v: int): string =
  result = newString(2)
  result[0] = chr((v shr 8) and 0xFF)
  result[1] = chr(v and 0xFF)

proc be32(v: uint32): string =
  result = newString(4)
  result[0] = chr(int((v shr 24) and 0xFF))
  result[1] = chr(int((v shr 16) and 0xFF))
  result[2] = chr(int((v shr 8) and 0xFF))
  result[3] = chr(int(v and 0xFF))

proc box(typ, payload: string): string =
  assert typ.len == 4
  result = be32(uint32(8 + payload.len)) & typ & payload

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

proc miniTiff(): string =
  # II, IFD0@8: Make "Canon\0", Artist "secret-canon-artist\0".
  var ifd = u16le(2)
  ifd.add(u16le(271) & u16le(2) & u32le(6) & u32le(38))
  ifd.add(u16le(315) & u16le(2) & u32le(20) & u32le(44))
  ifd.add(u32le(0))
  result = "II" & u16le(42) & u32le(8) & ifd
  assert result.len == 38
  result.add("Canon\x00")
  result.add("secret-canon-artist\x00")
  assert result.len == 64

proc cr3File(): string =
  let mvhd = box("mvhd", "\x00\x00\x00\x00" & "\x11\x22\x33\x44" &
    "\x55\x66\x77\x88" & "padpadpp")
  let tkhd = box("tkhd", "\x00\x00\x00\x00" & "\x11\x22\x33\x44" &
    "\x55\x66\x77\x88" & "padpadpp")
  let mdhd = box("mdhd", "\x00\x00\x00\x00" & "\x11\x22\x33\x44" &
    "\x55\x66\x77\x88" & "padpadpp")
  let moov = box("moov",
    mvhd &
    box("udta", "secret-artist-info") &
    box("uuid", miniTiff()) &
    box("uuid", "<x:xmpmeta>secret-xmp</x:xmpmeta>") &
    box("trak", tkhd & box("mdia", mdhd)))
  result = box("ftyp", "crx \x00\x00\x00\x00crx ") & moov &
    box("mdat", "raw-bytes-here")

proc hasDropped(res: StripResult, id: string): bool =
  for d in res.dropped:
    if d.id == id:
      return true
  return false

suite "cr3 stripping":
  test "udta plus uuid exif plus uuid xmp are handled":
    let data = cr3File()
    let (output, res) = stripCr3Data(data)
    check output.len == data.len
    check "secret-artist-info" notin output
    check "secret-canon-artist" notin output
    check "secret-xmp" notin output
    check "Canon" in output
    check hasDropped(res, "udta")
    check hasDropped(res, "Artist")
    check hasDropped(res, "uuid-XMP")
    # Timestamps zeroed.
    let mvhdPos = output.find("mvhd")
    check output[mvhdPos + 8 .. mvhdPos + 15] ==
      "\x00\x00\x00\x00\x00\x00\x00\x00"

  test "output is stable":
    let data = cr3File()
    let (output, _) = stripCr3Data(data)
    let (output2, _) = stripCr3Data(output)
    check output2 == output

  test "inspect sees uuid kinds and tiff tags":
    let data = cr3File()
    let meta = inspectCr3Data(data)
    var kinds: seq[string] = @[]
    for b in meta["boxes"]:
      if b["type"].getStr() == "uuid":
        kinds.add(b["kind"].getStr())
    check "tiff" in kinds
    check "xmp" in kinds
    var artist = ""
    for b in meta["boxes"]:
      if b["type"].getStr() == "uuid" and
          b["kind"].getStr() == "tiff":
        artist = b["tiff"]["ifds"][0]["tags"]["Artist"].getStr()
    check artist == "secret-canon-artist"

  test "missing moov raises":
    expect StripError:
      discard stripCr3Data(box("ftyp", "crx \x00\x00\x00\x00crx ") &
        box("mdat", "xx"))

  test "wrong brand raises":
    expect StripError:
      discard stripCr3Data(box("ftyp", "isom\x00\x00\x00\x00") &
        box("moov", "xx") & box("mdat", "xx"))

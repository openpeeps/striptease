import std/strutils
import std/json
import unittest

import striptease/stripapi
import striptease/heicstrip

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

proc infe(id: int, typ, name, ctype: string): string =
  var p = "\x02\x00\x00\x00" & be16(id) & be16(0) & typ & name & '\0'
  if typ == "mime":
    p.add(ctype & '\0')
  result = box("infe", p)

proc ilocEntry(id: int, off, ln: uint32): string =
  be16(id) & be16(0) & be32(0) & be16(1) & be32(off) & be32(ln)

proc exifExtent(): string =
  # 4-byte TIFF header offset + minimal TIFF with Artist.
  var ifd = u16le(2)
  ifd.add(u16le(271) & u16le(2) & u32le(6) & u32le(38))
  ifd.add(u16le(315) & u16le(2) & u32le(18) & u32le(44))
  ifd.add(u32le(0))
  var tiff = "II" & u16le(42) & u32le(8) & ifd
  assert tiff.len == 38
  tiff.add("Canon\x00")
  tiff.add("secret-heic-artis\x00")
  assert tiff.len == 62
  # Offset is relative to the byte after itself (0 = TIFF follows).
  result = be32(0) & tiff
  assert result.len == 66

proc heicFile(ilocIds: seq[int] = @[1, 2, 3]): string =
  let exifExt = exifExtent()
  let xmpExt = "<x:xmpmeta>secret-heic-xmp</x:xmpmeta>"
  let hvcExt = "hvc1-coded-bytes-1234"
  let pitm = box("pitm", "\x00\x00\x00\x00" & be16(3))
  let iinfBox = box("iinf", "\x00\x00\x00\x00" & be16(3) &
    infe(1, "Exif", "Exif", "") &
    infe(2, "mime", "XMP", "application/rdf+xml") &
    infe(3, "hvc1", "Image", ""))
  var ilocPay = "\x00\x00\x00\x00\x44\x40" & be16(ilocIds.len)
  let ilocBoxLen = 8 + ilocPay.len + 18 * ilocIds.len
  let metaPayLen = 4 + pitm.len + iinfBox.len + ilocBoxLen
  let ftypLen = 8 + len("heic\x00\x00\x00\x00heic")
  let mdatPay = ftypLen + 8 + metaPayLen + 8
  let off1 = mdatPay
  let off2 = mdatPay + exifExt.len
  let off3 = off2 + xmpExt.len
  for id in ilocIds:
    if id == 1:
      ilocPay.add(ilocEntry(1, uint32(off1), uint32(exifExt.len)))
    elif id == 2:
      ilocPay.add(ilocEntry(2, uint32(off2), uint32(xmpExt.len)))
    else:
      ilocPay.add(ilocEntry(3, uint32(off3), uint32(hvcExt.len)))
  let meta = box("meta", "\x00\x00\x00\x00" & pitm & iinfBox &
    box("iloc", ilocPay))
  let ftypBox = box("ftyp", "heic\x00\x00\x00\x00heic")
  result = ftypBox & meta &
    box("mdat", exifExt & xmpExt & hvcExt)

proc hasDropped(res: StripResult, id: string): bool =
  for d in res.dropped:
    if d.id == id:
      return true
  return false

proc hasKept(res: StripResult, id: string): bool =
  for k in res.kept:
    if k.id == id:
      return true
  return false

suite "heic stripping":
  test "exif item sanitised, xmp zeroed, image kept":
    let data = heicFile()
    let (output, res) = stripHeicData(data)
    check output.len == data.len
    check "secret-heic-art" notin output
    check "secret-heic-xmp" notin output
    check "hvc1-coded-bytes-1234" in output
    check "Canon" in output
    check hasDropped(res, "Artist")
    check hasDropped(res, "XMP")
    check hasKept(res, "ITEM-hvc1")
    check hasKept(res, "meta")

  test "unmapped exif item is kept and reported":
    let data = heicFile(@[2, 3])
    let (output, res) = stripHeicData(data)
    check output.len == data.len
    check "secret-heic-art" in output # untouched, honestly reported
    check "secret-heic-xmp" notin output
    check hasKept(res, "ITEM-Exif")
    check hasDropped(res, "XMP")

  test "output is stable":
    let data = heicFile()
    let (output, _) = stripHeicData(data)
    let (output2, _) = stripHeicData(output)
    check output2 == output

  test "inspect lists items and exif":
    let data = heicFile()
    let meta = inspectHeicData(data)
    check meta["items"].len == 3
    check meta["items"][0]["type"].getStr() == "Exif"
    check meta["items"][1]["contentType"].getStr() == "application/rdf+xml"
    check meta["exif"]["ifds"][0]["tags"]["Artist"].getStr() ==
      "secret-heic-artis"

  test "missing meta raises":
    expect StripError:
      discard stripHeicData(box("ftyp", "heic\x00\x00\x00\x00heic") &
        box("mdat", "xx"))

  test "wrong brand raises":
    expect StripError:
      discard stripHeicData(box("ftyp", "isom\x00\x00\x00\x00isom") &
        box("meta", "xx") & box("mdat", "xx"))

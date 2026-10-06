import std/json
import unittest

import striptease/stripapi
import striptease/inspect
import striptease/pngstrip

proc le32(v: uint32): string =
  result = newString(4)
  result[0] = chr(int(v and 0xFF))
  result[1] = chr(int((v shr 8) and 0xFF))
  result[2] = chr(int((v shr 16) and 0xFF))
  result[3] = chr(int((v shr 24) and 0xFF))

proc be32(v: uint32): string =
  result = newString(4)
  result[0] = chr(int((v shr 24) and 0xFF))
  result[1] = chr(int((v shr 16) and 0xFF))
  result[2] = chr(int((v shr 8) and 0xFF))
  result[3] = chr(int(v and 0xFF))

proc chunk(id, payload: string): string =
  assert id.len == 4
  result = id & le32(uint32(payload.len)) & payload
  if (payload.len mod 2) == 1:
    result.add('\0')

proc box(typ, payload: string): string =
  assert typ.len == 4
  result = be32(uint32(8 + payload.len)) & typ & payload

proc idBytes(id: uint64): string =
  if id <= 0xFFu64:
    result = newString(1)
    result[0] = chr(int(id))
  elif id <= 0x7FFFu64:
    result = newString(2)
    result[0] = chr(int((id shr 8) and 0xFFu64))
    result[1] = chr(int(id and 0xFFu64))
  else:
    result = newString(4)
    for i in 0 ..< 4:
      result[i] = chr(int((id shr (8 * (3 - i))) and 0xFFu64))

proc sizeBytes(n: int): string =
  assert n >= 0 and n <= 126
  result = newString(1)
  result[0] = chr(0x80 or n)

proc elem(id: uint64, payload: string): string =
  result = idBytes(id) & sizeBytes(payload.len) & payload

suite "inspect":
  test "wav LIST INFO is decoded":
    let data = "RIFF" & le32(99) & "WAVE" &
      chunk("fmt ", "1234567890123456") &
      chunk("LIST", "INFO" & chunk("INAM", "song") & chunk("IART", "me")) &
      chunk("data", "abcd")
    let meta = inspectData("wav", data)
    check meta["info"]["INAM"].getStr() == "song"
    check meta["info"]["IART"].getStr() == "me"

  test "jpeg APP plus COM are listed with kinds":
    let data = "\xFF\xD8" &
      "\xFF\xE1" & "\x00\x0C" & "Exif\x00\x00bin\x01" &
      "\xFF\xFE" & "\x00\x09" & "hello\x00" &
      "\xFF\xC0" & "\x00\x05" & "frm" &
      "\xFF\xDA" & "\x00\x04" & "hd" & "\x01\x02" & "\xFF\xD9"
    let meta = inspectData("jpeg", data)
    check meta["segments"].len == 2
    check meta["segments"][0]["marker"].getStr() == "APP1"
    check meta["segments"][0]["kind"].getStr() == "exif"
    check meta["segments"][1]["marker"].getStr() == "COM"
    check meta["segments"][1]["kind"].getStr() == "comment"

  test "png tEXt is decoded":
    var data = pngSignature
    data.add(encodeChunk("IHDR", "1234567890123"))
    data.add(encodeChunk("tEXt", "Title\x00hello"))
    data.add(encodeChunk("IDAT", "imagedata"))
    data.add(encodeChunk("IEND", ""))
    let meta = inspectData("png", data)
    check meta["text"].len == 1
    check meta["text"][0]["keyword"].getStr() == "Title"
    check meta["text"][0]["text"].getStr() == "hello"

  test "gif comments are listed":
    let data = "GIF89a" & "\x01\x00\x01\x00\x00\x00\x00" &
      "\x21\xFE\x05hello\x00" & "\x3B"
    let meta = inspectData("gif", data)
    check meta["comments"].len == 1
    check meta["comments"][0].getStr() == "hello"

  test "webp XMP is listed":
    var body = "WEBP"
    body.add(chunk("VP8 ", "framedata"))
    body.add(chunk("XMP ", "<xmp>hi</xmp>"))
    let data = "RIFF" & le32(uint32(body.len)) & body
    let meta = inspectData("webp", data)
    check meta["chunks"].len == 1
    check meta["chunks"][0]["type"].getStr() == "XMP"

  test "mp4 udta plus timestamps are decoded":
    let mvhd = box("mvhd", "\x00\x00\x00\x00" & "\x11\x22\x33\x44" &
      "\x55\x66\x77\x88" & "pad!")
    let hdlr = box("hdlr", "\x00\x00\x00\x00\x00\x00\x00\x00soun" &
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00")
    let data = box("ftyp", "isom\x00\x00\x00\x00") &
      box("moov", mvhd & box("udta", box("meta",
        "\x00\x00\x00\x00" & hdlr & box("titl", "mytitle")))) &
      box("mdat", "media-bytes")
    let meta = inspectData("mp4", data)
    check meta["timestamps"].len == 1
    check meta["timestamps"][0]["creation"].getInt() == 0x11223344
    check meta["boxes"].len == 1
    check meta["boxes"][0]["type"].getStr() == "udta"
    let kids = meta["boxes"][0]["children"][0]["children"]
    check kids[0]["type"].getStr() == "hdlr"
    check not kids[0].hasKey("children")
    check kids[1]["text"].getStr() == "mytitle"

  test "avi LIST INFO is decoded":
    var body = "AVI "
    body.add("LIST" & le32(24) & "INFO" & chunk("INAM", "secret-title"))
    body.add("LIST" & le32(22) & "movi" & chunk("00dc", "framedata"))
    let data = "RIFF" & le32(uint32(body.len)) & body
    let meta = inspectData("avi", data)
    check meta["info"]["INAM"].getStr() == "secret-title"

  test "mkv info plus tags plus attachments are decoded":
    let simpleTag = elem(0x67C8u64, elem(0x45A3u64, "TITLE") &
      elem(0x4487u64, "mytitle"))
    let attached = elem(0x61A7u64, elem(0x466Eu64, "cover.jpg") &
      elem(0x4660u64, "image/jpeg") & elem(0x465Cu64, "imgdata"))
    var ns: int64 = 725760000000000000i64
    var dateRaw = newString(8)
    for i in 0 ..< 8:
      dateRaw[i] = chr(int((ns shr (8 * (7 - i))) and 0xFF))
    let info = elem(0x1549A966u64, elem(0x7BA9u64, "mytitle") &
      elem(0x4461u64, dateRaw) & elem(0x4D80u64, "muxapp"))
    let data = elem(0x1A45DFA3u64, "head") & idBytes(0x18538067u64) &
      "\xFF" & info & elem(0x1254C367u64, elem(0x7373u64, simpleTag)) &
      elem(0x1941A469u64, attached)
    let meta = inspectData("mkv", data)
    check meta["info"]["title"].getStr() == "mytitle"
    check meta["info"]["muxingApp"].getStr() == "muxapp"
    check meta["info"]["dateUtc"]["iso"].getStr() == "2024-01-01T00:00:00Z"
    check meta["tags"].len == 1
    check meta["tags"][0]["tag"].getStr() == "TITLE"
    check meta["tags"][0]["value"].getStr() == "mytitle"
    check meta["attachments"].len == 1
    check meta["attachments"][0]["file"].getStr() == "cover.jpg"
    check meta["attachments"][0]["mime"].getStr() == "image/jpeg"
    check meta["attachments"][0]["size"].getInt() == 7

  test "clean files report empty metadata":
    var body = "WEBP" & chunk("VP8 ", "framedata")
    let data = "RIFF" & le32(uint32(body.len)) & body
    let meta = inspectData("webp", data)
    check meta["chunks"].len == 0

  test "bad magic raises":
    expect StripError:
      discard inspectData("jpeg", "junk-data")
    expect StripError:
      discard inspectData("png", "junk-data")

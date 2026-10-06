import std/strutils
import unittest

import striptease/stripapi
import striptease/mp4strip

proc be32(v: uint32): string =
  result = newString(4)
  result[0] = chr(int((v shr 24) and 0xFF))
  result[1] = chr(int((v shr 16) and 0xFF))
  result[2] = chr(int((v shr 8) and 0xFF))
  result[3] = chr(int(v and 0xFF))

proc box(typ, payload: string): string =
  assert typ.len == 4
  result = be32(uint32(8 + payload.len)) & typ & payload

proc mp4File(moovPayload: string): string =
  let ftyp = box("ftyp", "isom\x00\x00\x00\x00")
  let mdat = box("mdat", "media-bytes")
  result = ftyp & box("moov", moovPayload) & mdat

proc mvhdBox(): string =
  # version 0 + flags + creation/mod times (non-zero) + padding.
  box("mvhd", "\x00\x00\x00\x00" & "\x11\x22\x33\x44" &
    "\x55\x66\x77\x88" & "timescale-data....")

suite "mp4 stripping":
  test "clean file keeps size":
    let data = mp4File(mvhdBox() & box("trak", box("mdhd",
      "\x00\x00\x00\x00\x11\x22\x33\x44\x55\x66\x77\x88....")))
    let (output, res) = stripMp4Data(data)
    check res.dropped.len == 0
    check output.len == data.len

  test "udta plus meta plus uuid are neutralised":
    let data = mp4File(mvhdBox() & box("udta", "artist-secret") &
      box("meta", "\x00\x00\x00\x00ilst-secret") &
      box("uuid", "XMP-16-byte-id.." & "xmp-secret-payload"))
    let (output, res) = stripMp4Data(data)
    check res.dropped.len == 3
    check "artist-secret" notin output
    check "xmp-secret" notin output
    check output.len == data.len
    # Idempotent: second pass finds metadata boxes already gone.
    let (_, res2) = stripMp4Data(output)
    check res2.dropped.len == 0

  test "timestamps are zeroed":
    let data = mp4File(mvhdBox())
    let (output, _) = stripMp4Data(data)
    # mvhd payload: version/flags (4) then creation (4) + mod (4).
    let mvhdPos = output.find("mvhd")
    check mvhdPos >= 0
    check output[mvhdPos + 8 .. mvhdPos + 15] ==
      "\x00\x00\x00\x00\x00\x00\x00\x00"

  test "missing ftyp raises":
    expect StripError:
      discard stripMp4Data(box("moov", mvhdBox()))

  test "missing moov raises":
    expect StripError:
      discard stripMp4Data(box("ftyp", "isom....") & box("mdat", "xx"))

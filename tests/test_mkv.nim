import std/strutils
import unittest

import striptease/stripapi
import striptease/mkvstrip

proc idBytes(id: uint64): string =
  if id <= 0xFFu64:
    result = newString(1)
    result[0] = chr(int(id))
  elif id <= 0x7FFFu64:
    result = newString(2)
    result[0] = chr(int((id shr 8) and 0xFFu64))
    result[1] = chr(int(id and 0xFFu64))
  elif id <= 0x3FFFFFu64:
    result = newString(3)
    for i in 0 ..< 3:
      result[i] = chr(int((id shr (8 * (2 - i))) and 0xFFu64))
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

proc mkvFile(segChildren: string): string =
  let ebml = elem(0x1A45DFA3u64, "head")
  # Segment with unknown size (0xFF) running to EOF.
  result = ebml & idBytes(0x18538067u64) & "\xFF" & segChildren

proc infoElem(children: string): string =
  elem(0x1549A966u64, children)

suite "mkv stripping":
  test "clean file keeps size":
    let info = infoElem(elem(0x2AD7B1u64, "\x00\x00\x00\x01") &
      elem(0x4489u64, "duration"))
    let data = mkvFile(info & elem(0x1654AE6Bu64, "tracks") &
      elem(0x1F43B675u64, "cluster"))
    let (output, res) = stripMkvData(data)
    check res.dropped.len == 0
    check output == data

  test "tags plus attachments are voided":
    let data = mkvFile(
      infoElem(elem(0x2AD7B1u64, "\x00\x00\x00\x01")) &
      elem(0x1254C367u64, "tag-secret") &
      elem(0x1941A469u64, "cover-secret") &
      elem(0x1F43B675u64, "cluster"))
    let (output, res) = stripMkvData(data)
    check res.dropped.len == 2
    check "tag-secret" notin output
    check "cover-secret" notin output
    check output.len == data.len
    check ord(output[data.find("tag-secret") - 5]) == 0xEC
    let (_, res2) = stripMkvData(output)
    check res2.dropped.len == 0

  test "info title plus date plus apps are voided":
    let info = infoElem(elem(0x2AD7B1u64, "\x00\x00\x00\x01") &
      elem(0x7BA9u64, "my-title") & elem(0x4461u64, "date1234") &
      elem(0x4D80u64, "muxapp") & elem(0x5741u64, "writeapp") &
      elem(0x4489u64, "duration"))
    let data = mkvFile(info & elem(0x1F43B675u64, "cluster"))
    let (output, res) = stripMkvData(data)
    check res.dropped.len == 4
    check "my-title" notin output
    check "date1234" notin output
    check "duration" in output
    check output.len == data.len
    let (_, res2) = stripMkvData(output)
    check res2.dropped.len == 0

  test "missing EBML raises":
    expect StripError:
      discard stripMkvData(elem(0x18538067u64, "seg"))

  test "missing segment raises":
    expect StripError:
      discard stripMkvData(elem(0x1A45DFA3u64, "head"))

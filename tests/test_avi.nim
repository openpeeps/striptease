import std/strutils
import unittest

import striptease/stripapi
import striptease/avistrip

proc le32(v: uint32): string =
  result = newString(4)
  result[0] = chr(int(v and 0xFF))
  result[1] = chr(int((v shr 8) and 0xFF))
  result[2] = chr(int((v shr 16) and 0xFF))
  result[3] = chr(int((v shr 24) and 0xFF))

proc chunk(id, payload: string): string =
  assert id.len == 4
  result = id & le32(uint32(payload.len)) & payload
  if (payload.len mod 2) == 1:
    result.add('\0')

proc listChunk(listType: string, payload: string): string =
  assert listType.len == 4
  var inner = listType & payload
  result = "LIST" & le32(uint32(inner.len)) & inner
  if (inner.len mod 2) == 1:
    result.add('\0')

proc aviFile(topPayload: string): string =
  var body = "AVI " & topPayload
  result = "RIFF" & le32(uint32(body.len)) & body

suite "avi stripping":
  test "clean file keeps size":
    let data = aviFile(
      listChunk("hdrl", chunk("avih", "headerdata12")) &
      listChunk("movi", chunk("00dc", "framedata")) &
      chunk("idx1", "indexdata12"))
    let (output, res) = stripAviData(data)
    check res.dropped.len == 0
    check output == data

  test "LIST INFO is neutralised to JUNK":
    let info = listChunk("INFO", chunk("INAM", "secret-title") &
      chunk("IART", "secret-artist"))
    let data = aviFile(
      listChunk("hdrl", chunk("avih", "headerdata12")) &
      info &
      listChunk("movi", chunk("00dc", "framedata")) &
      chunk("idx1", "indexdata12"))
    let (output, res) = stripAviData(data)
    check res.dropped.len == 1
    check res.dropped[0].id == "LIST-INFO"
    check "secret-title" notin output
    check "secret-artist" notin output
    check output.len == data.len
    check output.find("JUNK") >= 0
    let (_, res2) = stripAviData(output)
    check res2.dropped.len == 0

  test "id3 chunk is neutralised":
    let data = aviFile(
      listChunk("hdrl", chunk("avih", "headerdata12")) &
      chunk("id3 ", "tag-secret!") &
      listChunk("movi", chunk("00dc", "framedata")))
    let (output, res) = stripAviData(data)
    check res.dropped.len == 1
    check "tag-secret!" notin output
    check output.len == data.len

  test "missing movi raises":
    let data = aviFile(listChunk("hdrl", chunk("avih", "headerdata12")))
    expect StripError:
      discard stripAviData(data)

  test "bad magic raises":
    expect StripError:
      discard stripAviData("RIFF\x00\x00\x00\x00NOT !....")

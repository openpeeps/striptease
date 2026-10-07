import std/[json, unicode]
import unittest

import striptease/stripapi
import striptease/textstrip
import striptease/inspect

proc cleanWith(s: string,
    normalizeSpaces = true,
    aggressive = false,
    stripEmojiGlue = false,
    stripBidi = false,
    forceText = true): string =
  var opts = defaultOptions()
  opts.normalizeSpaces = normalizeSpaces
  opts.aggressiveHomoglyphs = aggressive
  opts.stripEmojiGlue = stripEmojiGlue
  opts.stripBidi = stripBidi
  opts.forceText = forceText
  let (output, _) = stripTextData(s, opts)
  output

suite "text Layer A":
  test "zero-width carriers are stripped":
    check cleanWith("Hello\u200BWorld") == "HelloWorld"
    check cleanWith("a\u200C\u200D" & "b") == "ab"
    check cleanWith("x\uFEFFy") == "xy"
    check cleanWith("x\u00ADy") == "xy"

  test "exotic spaces normalize by default, opt-out preserves":
    check cleanWith("a b") == "a b"
    check cleanWith("a b") == "a b"
    check cleanWith("a　b") == "a b"
    var opts = defaultOptions()
    opts.normalizeSpaces = false
    opts.forceText = true
    let (output, _) = stripTextData("a b", opts)
    check output == "a b"

  test "bidi: marks preserved, overrides and unpaired embeddings stripped":
    # LRM / RLM / isolates kept by default
    check cleanWith("a‎b‏c") == "a‎b‏c"
    # RLO override stripped
    check cleanWith("a‮b") == "ab"
    # unpaired LRE stripped
    check cleanWith("a‪b") == "ab"
    # paired LRE...PDF preserved
    check cleanWith("a‪b‬c") == "a‪b‬c"
    # --strip-bidi strips legitimate marks too
    check cleanWith("a‎b", stripBidi = true) == "ab"

  test "tag chars stripped except complete flag sequences":
    check cleanWith("a󠀁b") == "ab"
    let flag = "🏴" & "󠁧" & "󠁢" & "󠁳" & "󠁣" & "󠁴" & "󠁿"
    check cleanWith(flag) == flag
    check cleanWith("a󠀠b") == "ab"

  test "emoji glue preserved, isolated glue stripped":
    let family = "👨" & "‍" & "👩" & "‍" & "👧"
    check cleanWith(family) == family
    check cleanWith("❤️" & "‍" & "🔥") == "❤️" & "‍" & "🔥"
    check cleanWith("⚖️") == "⚖️"
    check cleanWith("a‍b") == "ab"

  test "CJK and Mongolian variation selectors kept in context":
    check cleanWith("中" & "󠄀") == "中" & "󠄀"
    check cleanWith("ᠠ" & "᠋") == "ᠠ" & "᠋"
    check cleanWith("a᠋b") == "ab"

  test "script joiners and fillers kept in context only":
    # ZWNJ inside Persian word kept (same joining script both sides)
    check cleanWith("می‌روم") == "می‌روم"
    check cleanWith("a‌b") == "ab"

  test "private use, noncharacters and reserved ignorables stripped":
    check cleanWith("ab") == "ab"
    check cleanWith("a﷐b") == "ab"
    check cleanWith("a\u2065b") == "ab"

  test "confusables only with aggressive flag":
    check cleanWith("АBC") == "АBC"
    check cleanWith("АBC", aggressive = true) == "ABC"
    check cleanWith("Ａ", aggressive = true) == "A"

  test "paranoid strip-emoji-glue removes load-bearing invisibles":
    let family = "👨" & "‍" & "👩"
    check cleanWith(family, stripEmojiGlue = true) != family

  test "binary guard refuses containers without --force-text":
    var opts = defaultOptions()
    expect StripError:
      discard stripTextData("\x89PNG\x0D\x0A\x1A\x0A" & "junk", opts)
    opts.forceText = true
    # valid UTF-8 text with force flag passes (may still clean)
    let (output, _) = stripTextData("plain", opts)
    check output == "plain"

  test "invalid UTF-8 raises without --force-text":
    var opts = defaultOptions()
    expect StripError:
      discard stripTextData("\xFF\xFE\x00bad", opts)

  test "strip result reports kinds as dropped chunks":
    var opts = defaultOptions()
    opts.forceText = true
    let (output, res) = stripTextData("a b\u200Bc", opts)
    check output == "a bc"
    check res.bytesIn > res.bytesOut
    check res.dropped.len >= 1

  test "inspect reports hits with offsets":
    let meta = inspectTextData("a b\u200Bc")
    check meta["suspicious_total"].getInt() >= 2
    check meta["hits"].len >= 1
    let clean = inspectTextData("plain")
    check clean["suspicious_total"].getInt() == 0

  test "inspectData dispatcher routes text":
    let meta = inspectData("text", "a\u200Bb")
    check meta["suspicious_total"].getInt() == 1

  test "media string scrub strips carriers, preserves emoji":
    check scrubMediaString("a󠀁b") == "ab"
    check scrubMediaString("plain title") == "plain title"

  test "isTextPath matches minimal set":
    check isTextPath("notes.md")
    check isTextPath("notes.txt")
    check isTextPath("data.json")
    check not isTextPath("photo.jpg")
    check not isTextPath("clip.mp4")

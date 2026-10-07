# Text Layer A: invisible Unicode, exotic spaces, bidi, tag chars.
# Nim port of watermarks-remover `service/scripts/text_unicode.py`
# (deterministic edit-based carrier scrub; no statistical rewriting).
#
# Zero dependencies, std/unicode Rune-based. Nim stdlib has no UCD
# category/name tables and no NFKC, so:
# - letter checks use explicit range tables (slightly over-preserving
#   joiners is the safe direction);
# - inspect labels are `U+XXXX kind` (no unicodedata.name);
# - `--nfkc` is accepted for CLI compat but is currently a no-op
#   (stat reports nfkc_changed=false). Do not add deps for it.

import std/[json, unicode, strutils, tables, algorithm]

import stripapi

const textExts* = [".txt", ".text", ".md", ".markdown", ".json", ".csv",
  ".html", ".htm", ".xml", ".yaml", ".yml"]

func isTextPath*(path: string): bool =
  let lower = path.toLowerAscii()
  for e in textExts:
    if lower.endsWith(e):
      return true
  return false

# ------------------------------------------------------------ tables ---

func isStripCp(cp: int): bool =
  case cp
  of 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5,
     0x180B, 0x180C, 0x180D, 0x180E, 0x180F,
     0x200B, 0x200C, 0x200D, 0x200E, 0x200F,
     0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
     0x2060, 0x2061, 0x2062, 0x2063, 0x2064,
     0x2066, 0x2067, 0x2068, 0x2069,
     0x206A, 0x206B, 0x206C, 0x206D, 0x206E, 0x206F,
     0xFEFF,
     0xFE00, 0xFE01, 0xFE02, 0xFE03, 0xFE04, 0xFE05, 0xFE06, 0xFE07,
     0xFE08, 0xFE09, 0xFE0A, 0xFE0B, 0xFE0C, 0xFE0D, 0xFE0E, 0xFE0F,
     0x3164, 0xFFA0, 0xFFF9, 0xFFFA, 0xFFFB:
    true
  else:
    false

func normalizeSpaceCp(cp: int): int =
  ## Returns 0x20 when cp is an exotic space homoglyph, else -1.
  case cp
  of 0x00A0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
     0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000:
    0x20
  else:
    -1

func confusableReplacement(cp: int): int =
  ## Cyrillic + fullwidth Latin lookalikes, aggressive mode only.
  ## Returns ASCII codepoint or -1.
  case cp
  of 0x0410: 0x41 # А -> A
  of 0x0412: 0x42
  of 0x0415: 0x45
  of 0x041A: 0x4B
  of 0x041C: 0x4D
  of 0x041D: 0x48
  of 0x041E: 0x4F
  of 0x0420: 0x50
  of 0x0421: 0x43
  of 0x0422: 0x54
  of 0x0425: 0x58
  of 0x0430: 0x61
  of 0x0435: 0x65
  of 0x043E: 0x6F
  of 0x0440: 0x70
  of 0x0441: 0x63
  of 0x0443: 0x79
  of 0x0445: 0x78
  of 0x0456: 0x69
  else:
    if cp >= 0xFF21 and cp <= 0xFF3A:
      0x41 + (cp - 0xFF21)
    elif cp >= 0xFF41 and cp <= 0xFF5A:
      0x61 + (cp - 0xFF41)
    else:
      -1

func isVsSupplement(cp: int): bool =
  cp >= 0xE0100 and cp <= 0xE01EF

func isTagChar(cp: int): bool =
  cp >= 0xE0001 and cp <= 0xE007F

func isTagRange(cp: int): bool =
  cp >= 0xE0020 and cp <= 0xE007F

func isNoncharacter(cp: int): bool =
  (cp >= 0xFDD0 and cp <= 0xFDEF) or
    (cp <= 0x10FFFF and (cp and 0xFFFE) == 0xFFFE and cp >= 0xFFFE)

func isReservedIgnorable(cp: int): bool =
  if cp == 0x2065 or cp == 0xE0000:
    return true
  if cp >= 0xFFF0 and cp <= 0xFFF8:
    return true
  if cp >= 0xE0080 and cp <= 0xE00FF:
    return true
  if cp >= 0xE01F0 and cp <= 0xE0FFF:
    return true
  return false

func isPrivateUse(cp: int): bool =
  (cp >= 0xE000 and cp <= 0xF8FF) or
    (cp >= 0xF0000 and cp <= 0xFFFFD) or
    (cp >= 0x100000 and cp <= 0x10FFFD)

func isStripCpFull(cp: int): bool =
  if isStripCp(cp):
    return true
  if isVsSupplement(cp):
    return true
  if isTagChar(cp):
    return true
  if isNoncharacter(cp):
    return true
  if isReservedIgnorable(cp):
    return true
  if isPrivateUse(cp):
    return true
  return false

func isBidi(cp: int): bool =
  case cp
  of 0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
     0x2066, 0x2067, 0x2068, 0x2069:
    true
  else:
    false

func isPreservableBidi(cp: int): bool =
  case cp
  of 0x061C, 0x200E, 0x200F, 0x2066, 0x2067, 0x2068, 0x2069:
    true
  else:
    false

func isZwFamily(cp: int): bool =
  case cp
  of 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x180E:
    true
  else:
    false

func isEmojiGlue(cp: int): bool =
  cp == 0x200D or cp == 0xFE0E or cp == 0xFE0F

func isMongolianFvs(cp: int): bool =
  cp == 0x180B or cp == 0x180C or cp == 0x180D or cp == 0x180F

func isVariationSelector(cp: int): bool =
  isVsSupplement(cp) or (cp >= 0xFE00 and cp <= 0xFE0F) or isMongolianFvs(cp)

func isScriptJoiner(cp: int): bool =
  cp == 0x200C or cp == 0x200D

func isKhmerVowel(cp: int): bool =
  cp == 0x17B4 or cp == 0x17B5

func isHangulFiller(cp: int): bool =
  cp == 0x115F or cp == 0x1160 or cp == 0x3164 or cp == 0xFFA0

func isScriptGlue(cp: int): bool =
  isMongolianFvs(cp) or isKhmerVowel(cp) or isHangulFiller(cp)

func isGlue(cp: int): bool =
  isEmojiGlue(cp) or isVariationSelector(cp) or isScriptJoiner(cp) or
    isTagRange(cp) or isScriptGlue(cp)

func isOrthographicCf(cp: int): bool =
  case cp
  of 0x0600, 0x0601, 0x0602, 0x0603, 0x0604, 0x0605, 0x06DD, 0x070F,
     0x08E2, 0x110BD, 0x110CD:
    true
  else:
    false

func stripKind(cp: int): string =
  if cp >= 0xE0001 and cp <= 0xE007F:
    return "tag_chars"
  if isNoncharacter(cp):
    return "noncharacter"
  if isReservedIgnorable(cp):
    return "reserved_ignorable"
  if isVsSupplement(cp) or (cp >= 0xFE00 and cp <= 0xFE0F) or
      isMongolianFvs(cp):
    return "variation_selector"
  if isBidi(cp):
    return "bidi"
  if isZwFamily(cp):
    return "zwj_family"
  if isPrivateUse(cp):
    return "private_use"
  return "strip"

func isEmojiBase(cp: int): bool =
  if cp >= 0x1F000 and cp <= 0x1FAFF:
    return true
  if cp >= 0x2190 and cp <= 0x25FF:
    return true
  if cp >= 0x2600 and cp <= 0x27BF:
    return true
  if cp >= 0x2B00 and cp <= 0x2BFF:
    return true
  case cp
  of 0x203C, 0x2049, 0x2139, 0x2934, 0x2935,
     0x00A9, 0x00AE, 0x2122, 0x3030, 0x303D, 0x3297, 0x3299,
     0x0023, 0x002A:
    return true
  else:
    discard
  if cp >= 0x0030 and cp <= 0x0039:
    return true
  return false

func isCjkIdeograph(cp: int): bool =
  (cp >= 0x3400 and cp <= 0x4DBF) or
    (cp >= 0x4E00 and cp <= 0x9FFF) or
    (cp >= 0xF900 and cp <= 0xFAFF) or
    (cp >= 0x20000 and cp <= 0x323AF)

func isMongolianBase(cp: int): bool =
  cp >= 0x1800 and cp <= 0x18AF

func joiningScript(cp: int): int =
  ## Broad script group where ZWJ/ZWNJ can be orthographic.
  ## Approximation: Nim has no UCD L/M tables, so any cp in the broad
  ## range counts. Over-preserving here is the safe direction.
  if cp >= 0x0600 and cp <= 0x08FF:
    return 1
  if cp >= 0x0900 and cp <= 0x0DFF:
    return 2
  if cp >= 0x0F00 and cp <= 0x109F:
    return 3
  if cp >= 0x1780 and cp <= 0x17FF:
    return 4
  if cp >= 0x1800 and cp <= 0x18AF:
    return 5
  return 0

func isMongolianLetter(cp: int): bool =
  cp >= 0x1820 and cp <= 0x18AA

func isKhmerLetter(cp: int): bool =
  cp >= 0x1780 and cp <= 0x17B3

func isHangulJamo(cp: int): bool =
  (cp >= 0x1100 and cp <= 0x11FF) or
    (cp >= 0xA960 and cp <= 0xA97C) or
    (cp >= 0xD7B0 and cp <= 0xD7C6) or
    (cp >= 0x3131 and cp <= 0x318E) or
    (cp >= 0xFFA1 and cp <= 0xFFDC)

func layoutCfScriptContains(controlCp, neighborCp: int): bool =
  if controlCp >= 0x13430 and controlCp <= 0x1343F:
    return neighborCp >= 0x13000 and neighborCp <= 0x143FF
  if controlCp >= 0x1BCA0 and controlCp <= 0x1BCA3:
    return neighborCp >= 0x1BC00 and neighborCp <= 0x1BCA3
  if controlCp >= 0x1D173 and controlCp <= 0x1D17A:
    return neighborCp >= 0x1D100 and neighborCp <= 0x1D1FF
  return false

func isLayoutCf(cp: int): bool =
  (cp >= 0x13430 and cp <= 0x1343F) or
    (cp >= 0x1BCA0 and cp <= 0x1BCA3) or
    (cp >= 0x1D173 and cp <= 0x1D17A)

func isCf(cp: int): bool =
  ## Exhaustive Cf list for this Unicode version (mirrors
  ## `unicodedata.category == "Cf"` used by the reference fallback).
  ## Re-check on Unicode bumps: new Cf must be added here.
  if isStripCp(cp):
    return true
  case cp
  of 0x0600, 0x0601, 0x0602, 0x0603, 0x0604, 0x0605, 0x06DD, 0x070F,
     0x0890, 0x0891, 0x08E2, 0x110BD, 0x110CD,
     0x13430, 0x13431, 0x13432, 0x13433, 0x13434, 0x13435, 0x13436,
     0x13437, 0x13438,
     0x1BCA0, 0x1BCA1, 0x1BCA2, 0x1BCA3,
     0x1D173, 0x1D174, 0x1D175, 0x1D176, 0x1D177, 0x1D178, 0x1D179,
     0x1D17A:
    return true
  else:
    discard
  if cp >= 0xE0001 and cp <= 0xE007F:
    return true
  return false

func cpLabel(cp: int): string =
  "U+" & toHex(cp, 4)

# ------------------------------------------------------------ context ---

proc validFlagTagIndices(runes: seq[Rune]): seq[bool] =
  result = newSeq[bool](runes.len)
  var i = 0
  while i < runes.len:
    if int(runes[i]) != 0x1F3F4:
      inc i
      continue
    var j = i + 1
    while j < runes.len and int(runes[j]) >= 0xE0020 and
        int(runes[j]) <= 0xE007E:
      inc j
    if j > i + 1 and j < runes.len and int(runes[j]) == 0xE007F:
      for k in (i + 1) .. j:
        result[k] = true
      i = j + 1
    else:
      inc i

proc validBidiEmbeddingIndices(runes: seq[Rune]): seq[bool] =
  result = newSeq[bool](runes.len)
  var stack: seq[(int, int)] = @[]
  for idx, r in runes:
    let cp = int(r)
    if cp == 0x202A or cp == 0x202B or cp == 0x202D or cp == 0x202E:
      stack.add((cp, idx))
    elif cp == 0x202C:
      if stack.len == 0:
        continue
      let (opener, openerIdx) = stack.pop()
      if opener == 0x202A or opener == 0x202B:
        result[openerIdx] = true
        result[idx] = true

type DecideAction = enum
  daKeep
  daStrip
  daReplace

type DecideOut = object
  action: DecideAction
  outCp: int
  kind: string

func decide(cp: int, prevKept: int, prevInput: int, nextInput: int,
    validFlagTag: bool, validBidiEmbedding: bool,
    normalizeSpaces: bool, treatConfusables: bool,
    stripEmojiGlue: bool, stripBidi: bool): DecideOut =
  if validBidiEmbedding and not stripBidi:
    return DecideOut(action: daKeep, outCp: cp, kind: "")
  if isPreservableBidi(cp) and not stripBidi:
    return DecideOut(action: daKeep, outCp: cp, kind: "")
  if prevInput >= 0 and not stripEmojiGlue:
    if isVsSupplement(cp) and isCjkIdeograph(prevInput):
      return DecideOut(action: daKeep, outCp: cp, kind: "")
    if isMongolianFvs(cp) and isMongolianBase(prevInput):
      return DecideOut(action: daKeep, outCp: cp, kind: "")
    if cp >= 0xFE00 and cp <= 0xFE0D and isCjkIdeograph(prevInput):
      return DecideOut(action: daKeep, outCp: cp, kind: "")
  if isEmojiGlue(cp) and not stripEmojiGlue:
    if (cp == 0xFE0E or cp == 0xFE0F) and prevInput >= 0 and
        isEmojiBase(prevInput):
      return DecideOut(action: daKeep, outCp: cp, kind: "")
    if cp == 0x200D and prevKept >= 0 and nextInput >= 0 and
        isEmojiBase(prevKept) and isEmojiBase(nextInput):
      return DecideOut(action: daKeep, outCp: cp, kind: "")
  if not stripEmojiGlue:
    if (cp == 0x200C or cp == 0x200D) and prevInput >= 0 and
        nextInput >= 0:
      let ps = joiningScript(prevInput)
      let ns = joiningScript(nextInput)
      if ps != 0 and ps == ns:
        return DecideOut(action: daKeep, outCp: cp, kind: "")
    if isTagRange(cp) and validFlagTag:
      return DecideOut(action: daKeep, outCp: cp, kind: "")
    if isMongolianFvs(cp) and prevKept >= 0 and
        isMongolianLetter(prevKept):
      return DecideOut(action: daKeep, outCp: cp, kind: "")
    if isKhmerVowel(cp) and prevKept >= 0 and isKhmerLetter(prevKept):
      return DecideOut(action: daKeep, outCp: cp, kind: "")
    if isHangulFiller(cp) and prevKept >= 0 and isHangulJamo(prevKept):
      return DecideOut(action: daKeep, outCp: cp, kind: "")
    if isOrthographicCf(cp):
      return DecideOut(action: daKeep, outCp: cp, kind: "")
    if isLayoutCf(cp):
      if (prevInput >= 0 and
          layoutCfScriptContains(cp, prevInput)) or
         (nextInput >= 0 and
          layoutCfScriptContains(cp, nextInput)):
        return DecideOut(action: daKeep, outCp: cp, kind: "")
  if isStripCpFull(cp):
    return DecideOut(action: daStrip, outCp: -1, kind: stripKind(cp))
  if normalizeSpaces:
    let sp = normalizeSpaceCp(cp)
    if sp >= 0:
      return DecideOut(action: daReplace, outCp: sp, kind: "space")
  if treatConfusables:
    let rep = confusableReplacement(cp)
    if rep >= 0:
      return DecideOut(action: daReplace, outCp: rep, kind: "confusable")
  if isCf(cp):
    return DecideOut(action: daStrip, outCp: -1, kind: "other_cf")
  return DecideOut(action: daKeep, outCp: cp, kind: "")

# ------------------------------------------------------------ guard ---

func looksLikeBinary*(data: string): bool =
  if data.len == 0:
    return false
  if data.len >= 8 and data[0 .. 7] == "\x89PNG\x0D\x0A\x1A\x0A":
    return true
  if data.len >= 2 and ord(data[0]) == 0xFF and ord(data[1]) == 0xD8:
    return true
  if data.len >= 6 and (data[0 .. 5] == "GIF87a" or data[0 .. 5] == "GIF89a"):
    return true
  if data.len >= 4 and data[0 .. 3] == "RIFF":
    return true
  if data.len >= 4 and data[0 .. 3] == "PK\x03\x04":
    return true
  if data.len >= 4 and data[0] == '\0':
    return true
  var controls = 0
  var checkLen = min(data.len, 4096)
  for i in 0 ..< checkLen:
    let c = ord(data[i])
    if c == 0:
      return true
    if (c < 0x09) or (c == 0x0B) or (c == 0x0C) or
        (c >= 0x0E and c < 0x20) or c == 0x7F:
      inc controls
  if checkLen > 0 and controls * 100 > checkLen * 30:
    return true
  return false

proc checkTextInput*(data: string, path: string,
    forceText: bool): void =
  if validateUtf8(data) != -1:
    if not forceText:
      raise newException(StripError,
        "not valid UTF-8 text (use --force-text to scan raw bytes anyway): " &
        path)
  if looksLikeBinary(data) and not forceText:
    raise newException(StripError,
      "looks like a binary container (use --force-text to treat as text anyway): " &
      path)

# ------------------------------------------------------------ core ---

proc cleanTextRunes*(runes: seq[Rune], opts: StripOptions): tuple[
    output: string, removed: CountTable[string],
    replaced: CountTable[string]] =
  let validFlags = validFlagTagIndices(runes)
  let validBidi = validBidiEmbeddingIndices(runes)
  var outStr = newStringOfCap(runes.len * 2)
  var removed = initCountTable[string]()
  var replaced = initCountTable[string]()
  var prevKept = -1
  for i, r in runes:
    let cp = int(r)
    let prevIn =
      if i > 0: int(runes[i - 1])
      else: -1
    let nextIn =
      if i + 1 < runes.len: int(runes[i + 1])
      else: -1
    let d = decide(cp, prevKept, prevIn, nextIn, validFlags[i],
      validBidi[i], opts.normalizeSpaces, opts.aggressiveHomoglyphs,
      opts.stripEmojiGlue, opts.stripBidi)
    case d.action
    of daKeep:
      outStr.add(Rune(d.outCp).toUTF8())
      if not isGlue(cp):
        prevKept = d.outCp
    of daReplace:
      outStr.add(Rune(d.outCp).toUTF8())
      replaced.inc(cpLabel(cp) & " " & d.kind)
      prevKept = d.outCp
    of daStrip:
      removed.inc(cpLabel(cp) & " " & d.kind)
  result = (output: outStr, removed: removed, replaced: replaced)

proc stripTextData*(data: string,
    opts: StripOptions): tuple[output: string, res: StripResult] =
  ## Cleans text with safe-preserve defaults. Raises StripError on
  ## binary / invalid UTF-8 unless opts.forceText.
  checkTextInput(data, "input", opts.forceText)
  var res: StripResult
  res.bytesIn = data.len
  let runes = data.toRunes()
  let (cleaned, removed, replaced) = cleanTextRunes(runes, opts)
  # NFKC is accepted for CLI compat but has no stdlib support in Nim;
  # report nfkc_changed=false (see module header).
  res.bytesOut = cleaned.len
  res.kept.add(ChunkReport(id: "text", size: uint32(cleaned.len),
    action: caKeep))
  var byKind = initCountTable[string]()
  for label, count in removed:
    let parts = label.split(' ')
    let kind =
      if parts.len > 1: parts[^1]
      else: "strip"
    byKind.inc(kind, count)
  for label, count in replaced:
    let parts = label.split(' ')
    let kind =
      if parts.len > 1: parts[^1]
      else: "space"
    byKind.inc(kind, count)
  var kinds: seq[string] = @[]
  for k in byKind.keys:
    kinds.add(k)
  kinds.sort()
  for k in kinds:
    res.dropped.add(ChunkReport(id: k, size: uint32(byKind[k]),
      action: caDrop))
  result = (output: cleaned, res: res)

proc inspectTextData*(data: string, aggressive = false,
    stripEmojiGlue = false): JsonNode =
  ## Reports suspicious carriers without writing. Uses
  ## normalizeSpaces=true to match reference inspect behaviour.
  var opts = defaultOptions()
  opts.normalizeSpaces = true
  opts.aggressiveHomoglyphs = aggressive
  opts.stripEmojiGlue = stripEmojiGlue
  opts.stripBidi = true
  opts.forceText = true
  let runes =
    try:
      data.toRunes()
    except CatchableError:
      raise newException(StripError, "not valid UTF-8 text")
  let validFlags = validFlagTagIndices(runes)
  let validBidi = validBidiEmbeddingIndices(runes)
  var buckets = initTable[(int, string), seq[int]]()
  var prevKept = -1
  for i, r in runes:
    let cp = int(r)
    let prevIn =
      if i > 0: int(runes[i - 1])
      else: -1
    let nextIn =
      if i + 1 < runes.len: int(runes[i + 1])
      else: -1
    let d = decide(cp, prevKept, prevIn, nextIn, validFlags[i],
      validBidi[i], true, aggressive, stripEmojiGlue, true)
    if d.kind == "":
      if not isGlue(cp):
        prevKept = d.outCp
      continue
    let key = (cp, d.kind)
    if not buckets.hasKey(key):
      buckets[key] = @[]
    buckets[key].add(i)
    if d.action == daReplace:
      prevKept = d.outCp
  var hits = newJArray()
  var total = 0
  var keys: seq[(int, string)] = @[]
  for k in buckets.keys:
    keys.add(k)
  keys.sort(proc(a, b: (int, string)): int =
    let ca = buckets[a].len
    let cb = buckets[b].len
    if ca != cb:
      return cb - ca
    return a[0] - b[0])
  for key in keys:
    let offs = buckets[key]
    let conf =
      if key[1] == "space": "informational"
      else: "probable"
    var samples = newJArray()
    for o in offs[0 ..< min(offs.len, 10)]:
      samples.add(% o)
    hits.add(%* {"codepoint": cpLabel(key[0]), "label": cpLabel(key[0]),
      "count": offs.len, "kind": key[1], "confidence": conf,
      "sample_offsets": samples})
    total += offs.len
  var notes = newJArray()
  notes.add(% "Layer A only: invisible/format Unicode and space homoglyphs (edit-based carriers).")
  notes.add(% "Statistical (token-sampling) watermarks are not detectable here.")
  notes.add(% "Inspect kinds: strip, bidi, tag_chars, variation_selector, zwj_family, private_use, space, confusable, other_cf.")
  notes.add(% "Load-bearing invisibles are preserved by default during cleaning: emoji glue, CJK/Mongolian variation selectors, script joiners, complete flag tag sequences, same-script fillers/selectors, RTL directional marks/paired embeddings, orthographic Cf, visible-layout controls next to their own script. Use explicit strip flags only after review.")
  if total == 0:
    notes.add(% "No deterministic Layer A (invisible Unicode/format) carriers detected.")
  result = %* {"length": runes.len, "suspicious_total": total,
    "hits": hits, "notes": notes}

proc scrubMediaString*(s: string): string =
  ## Context-aware scrub for short media metadata strings shown in
  ## --inspect JSON. Safe defaults: keep spaces and RTL marks, drop
  ## dangerous carriers, preserve emoji glue.
  var opts = defaultOptions()
  opts.normalizeSpaces = false
  opts.aggressiveHomoglyphs = false
  opts.stripEmojiGlue = false
  opts.stripBidi = false
  opts.forceText = true
  let runes =
    try:
      s.toRunes()
    except CatchableError:
      return s
  let (cleaned, _, _) = cleanTextRunes(runes, opts)
  return cleaned

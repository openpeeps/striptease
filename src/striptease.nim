# striptease CLI entry point.
# Supports WAV audio, JPEG/PNG/GIF/WebP images and MP4/MOV/AVI/MKV
# video. Each format module plugs in through the dispatcher below.

import std/[os, parseopt, strutils, json]

import striptease/stripapi
import striptease/wavstrip
import striptease/jpegstrip
import striptease/pngstrip
import striptease/gifstrip
import striptease/webpstrip
import striptease/mp4strip
import striptease/avistrip
import striptease/mkvstrip
import striptease/inspect
import striptease/rawstrip
import striptease/cr3strip
import striptease/heicstrip

const versionStr = "0.3.0"

const
  ansiReset = "\e[0m"
  ansiBoldWhite = "\e[1;37m"
  ansiGrey = "\e[90m"
  ansiRed = "\e[31m"

proc useColor(): bool =
  getEnv("NO_COLOR") == "" and getEnv("TERM") != "dumb"

proc paint(s, code: string): string =
  if useColor():
    code & s & ansiReset
  else:
    s

proc label(s: string): string =
  paint(s, ansiBoldWhite)

proc grey(s: string): string =
  paint(s, ansiGrey)

proc errPrefix(): string =
  paint("error:", ansiRed)

const supportedExts = [".wav", ".jpg", ".jpeg", ".png", ".gif", ".webp",
  ".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm", ".cr2", ".nef", ".nrw",
  ".arw", ".srf", ".dng", ".rw2", ".orf", ".pef", ".srw", ".tif", ".tiff",
  ".cr3", ".heic", ".heif", ".hif"]

proc formatKind(path: string): string =
  ## Returns a short format key ("wav", "jpeg", ...) or "" if unsupported.
  let lower = path.toLowerAscii()
  if lower.endsWith(".wav"):
    return "wav"
  if lower.endsWith(".jpg") or lower.endsWith(".jpeg"):
    return "jpeg"
  if lower.endsWith(".png"):
    return "png"
  if lower.endsWith(".gif"):
    return "gif"
  if lower.endsWith(".webp"):
    return "webp"
  if lower.endsWith(".mp4") or lower.endsWith(".mov") or
      lower.endsWith(".m4v"):
    return "mp4"
  if lower.endsWith(".avi"):
    return "avi"
  if lower.endsWith(".mkv") or lower.endsWith(".webm"):
    return "mkv"
  if lower.endsWith(".cr2") or lower.endsWith(".nef") or
      lower.endsWith(".nrw") or lower.endsWith(".arw") or
      lower.endsWith(".srf") or lower.endsWith(".dng") or
      lower.endsWith(".rw2") or lower.endsWith(".orf") or
      lower.endsWith(".pef") or lower.endsWith(".srw") or
      lower.endsWith(".tif") or lower.endsWith(".tiff"):
    return "raw"
  if lower.endsWith(".cr3"):
    return "cr3"
  if lower.endsWith(".heic") or lower.endsWith(".heif") or
      lower.endsWith(".hif"):
    return "heic"
  return ""

proc isSupportedPath(path: string): bool =
  formatKind(path) != ""

proc printHelp() =
  echo grey("striptease " & versionStr & " – strip metadata from photos, PDFs, videos, and documents") & "\n"
  echo grey("MIT license | Made by Humans from OpenPeeps\n  https://github.com/openpeeps/striptease")
  echo ""
  echo "usage: striptease <input|input-dir> --out:<dir> [options]"
  echo ""
  echo label("required:")
  echo "  <input>             " & grey("file or directory (mixed formats allowed)")
  echo "  -o, --out:<dir>     " & grey("output directory for cleaned copies")
  echo grey("                      (single file input plus --out:foo.ext writes one file,")
  echo grey("                       not needed with --inspect)")
  echo ""
  echo label("supported formats:")
  echo "  " & grey("audio: .wav | images: .jpg .jpeg .png .gif .webp")
  echo "  " & grey("raw: .cr2 .nef .nrw .arw .srf .dng .rw2 .orf .pef .srw .tif .tiff")
  echo "  " & grey("video: .mp4 .mov .m4v .avi .mkv .webm | canon raw: .cr3 | heic: .heic .heif .hif")
  echo ""
  echo label("options:")
  echo "  --dry-run           " & grey("report only, write nothing")
  echo "  --inspect           " & grey("print metadata as pretty JSON, write nothing")
  echo "  --verbose           " & grey("per file kept and dropped chunks plus bytes saved")
  echo "  --overwrite         " & grey("overwrite existing files in out dir (default: skip)")
  echo "  --keep-musical      " & grey("WAV only: also keep cue, smpl, inst, acid chunks")
  echo "  -h, --help          " & grey("show this help")
  echo "  --version           " & grey("show version")

proc printResult(path: string, res: StripResult, verbose: bool) =
  if verbose:
    var keptIds: seq[string] = @[]
    for k in res.kept:
      keptIds.add(k.id.strip() & "(" & $k.size & ")")
    var droppedIds: seq[string] = @[]
    for d in res.dropped:
      droppedIds.add(d.id.strip() & "(" & $d.size & ")")
    echo "  kept: " & keptIds.join(", ")
    if droppedIds.len > 0:
      echo "  dropped: " & droppedIds.join(", ")
    else:
      echo "  dropped: none"
    echo "  bytes: " & $res.bytesIn & " -> " & $res.bytesOut &
      " (saved " & $res.bytesSaved() & ")"
  else:
    echo "  dropped " & $res.dropped.len & " chunk(s), saved " &
      $res.bytesSaved() & " bytes"

proc collectInputs(input: string): seq[string] =
  if fileExists(input):
    if not isSupportedPath(input):
      raise newException(UnsupportedFormatError,
        "unsupported format (supported: " & supportedExts.join(" ") &
        "): " & input)
    return @[input]
  if dirExists(input):
    result = @[]
    for kind, p in walkDir(input):
      if kind == pcFile and isSupportedPath(p):
        result.add(p)
    return result
  raise newException(OSError, "input not found: " & input)

proc resolveOutPath(inPath: string, inputWasFile: bool, outArg: string,
    outIsFile: bool): string =
  if outIsFile and inputWasFile:
    return outArg
  return outArg / extractFilename(inPath)

proc stripByFormat(kind: string, data: string,
    keepMusical: bool): tuple[output: string, res: StripResult] =
  case kind
  of "wav":
    return stripWavData(data, keepMusical)
  of "jpeg":
    return stripJpegData(data)
  of "png":
    return stripPngData(data)
  of "gif":
    return stripGifData(data)
  of "webp":
    return stripWebpData(data)
  of "mp4":
    return stripMp4Data(data)
  of "avi":
    return stripAviData(data)
  of "mkv":
    return stripMkvData(data)
  of "raw":
    return stripRawData(data)
  of "cr3":
    return stripCr3Data(data)
  of "heic":
    return stripHeicData(data)
  else:
    raise newException(UnsupportedFormatError,
      "unsupported format: " & kind)

proc inspectOneFile(inPath: string, opts: StripOptions,
    reports: var JsonNode): bool =
  var data: string
  try:
    data = readFile(inPath)
  except IOError as e:
    reports.add(%* {"file": inPath, "format": "", "error": "cannot read: " &
        e.msg})
    return false
  let kind = formatKind(inPath)
  try:
    let (_, res) = stripByFormat(kind, data, opts.keepMusical)
    let meta = inspectData(kind, data, opts.keepMusical)
    var dropped = newJArray()
    for d in res.dropped:
      dropped.add(%* {"id": d.id.strip(), "size": int(d.size)})
    reports.add(%* {"file": inPath, "format": kind, "bytes": data.len,
      "metadata": meta, "dropped": dropped})
    return true
  except StripError as e:
    reports.add(%* {"file": inPath, "format": kind, "error": e.msg})
    return false
  except CatchableError as e:
    reports.add(%* {"file": inPath, "format": kind, "error": e.msg})
    return false

proc processOneFile(inPath: string, outPath: string,
    opts: StripOptions): bool =
  var data: string
  try:
    data = readFile(inPath)
  except IOError as e:
    echo "FAIL " & inPath & ": cannot read (" & e.msg & ")"
    return false
  var stripped: tuple[output: string, res: StripResult]
  try:
    stripped = stripByFormat(formatKind(inPath), data, opts.keepMusical)
  except StripError as e:
    echo "FAIL " & inPath & ": " & e.msg
    return false
  except CatchableError as e:
    echo "FAIL " & inPath & ": " & e.msg
    return false
  if opts.dryRun:
    echo "DRY " & inPath & " -> " & outPath
    printResult(inPath, stripped.res, true)
    return true
  if fileExists(outPath) and not opts.overwrite:
    echo "SKIP " & inPath & " (exists, use --overwrite): " & outPath
    printResult(inPath, stripped.res, opts.verbose)
    return true
  try:
    createDir(parentDir(outPath))
    let tmpPath = outPath & ".tmp"
    writeFile(tmpPath, stripped.output)
    moveFile(tmpPath, outPath)
  except OSError as e:
    echo "FAIL " & inPath & ": cannot write (" & e.msg & ")"
    return false
  except IOError as e:
    echo "FAIL " & inPath & ": cannot write (" & e.msg & ")"
    return false
  echo "OK " & inPath & " -> " & outPath
  printResult(inPath, stripped.res, opts.verbose)
  return true

proc main(): int =
  var input = ""
  var outArg = ""
  var opts = defaultOptions()
  var showHelp = false
  var showVersion = false
  var p = initOptParser(commandLineParams())
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      if input == "":
        input = key
      else:
        echo errPrefix() & " only one input allowed"
        printHelp()
        return 1
    of cmdLongOption, cmdShortOption:
      case key
      of "help", "h":
        showHelp = true
      of "version":
        showVersion = true
      of "out", "o":
        outArg = val
      of "dry-run":
        opts.dryRun = true
      of "inspect":
        opts.inspect = true
      of "verbose":
        opts.verbose = true
      of "overwrite":
        opts.overwrite = true
      of "keep-musical":
        opts.keepMusical = true
      else:
        echo errPrefix() & " unknown option --" & key
        printHelp()
        return 1
    of cmdEnd:
      discard
  if showVersion:
    echo versionStr
    return 0
  if showHelp:
    printHelp()
    return 0
  if input == "" or (outArg == "" and not opts.inspect):
    printHelp()
    if opts.inspect:
      echo "\n" & errPrefix() & " input is required"
    else:
      echo "\n" & errPrefix() & " input and --out are required"
    return 1
  let inputWasFile = fileExists(input)
  let outIsFile = inputWasFile and outArg != "" and isSupportedPath(outArg)
  if not inputWasFile and not dirExists(input):
    echo errPrefix() & " input not found: " & input
    return 1
  var files: seq[string]
  try:
    files = collectInputs(input)
  except UnsupportedFormatError as e:
    echo errPrefix() & " " & e.msg
    return 1
  except OSError as e:
    echo errPrefix() & " " & e.msg
    return 1
  if files.len == 0:
    echo "no supported files found in: " & input &
      " (" & supportedExts.join(" ") & ")"
    return 1
  if not opts.dryRun and not opts.inspect:
    try:
      if outIsFile:
        createDir(parentDir(outArg))
      else:
        createDir(outArg)
    except OSError as e:
      echo errPrefix() & " cannot create out dir: " & e.msg
      return 1
  var okCount = 0
  var failCount = 0
  var reports = newJArray()
  for f in files:
    if opts.inspect:
      if inspectOneFile(f, opts, reports):
        inc okCount
      else:
        inc failCount
      continue
    let outPath = resolveOutPath(f, inputWasFile, outArg, outIsFile)
    if processOneFile(f, outPath, opts):
      inc okCount
    else:
      inc failCount
  if opts.inspect:
    echo pretty(reports)
    if failCount > 0:
      return 2
    return 0
  echo "done: " & $okCount & " ok, " & $failCount & " failed"
  if failCount > 0:
    return 2
  return 0

when isMainModule:
  quit(main())

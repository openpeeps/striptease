# Shared types for striptease format strippers.
# Each audio format implements stripping against this interface
# so the CLI dispatcher stays stable as new formats are added.

type
  ChunkAction* = enum
    caKeep
    caDrop

  ChunkReport* = object
    id*: string
    size*: uint32
    action*: ChunkAction

  StripOptions* = object
    keepMusical*: bool
    overwrite*: bool
    dryRun*: bool
    verbose*: bool

  StripResult* = object
    kept*: seq[ChunkReport]
    dropped*: seq[ChunkReport]
    bytesIn*: int
    bytesOut*: int

  StripError* = object of CatchableError
  UnsupportedFormatError* = object of CatchableError

proc defaultOptions*(): StripOptions =
  StripOptions(keepMusical: false, overwrite: false, dryRun: false,
      verbose: false)

proc bytesSaved*(r: StripResult): int =
  r.bytesIn - r.bytesOut

proc actionLabel*(a: ChunkAction): string =
  case a
  of caKeep: "keep"
  of caDrop: "drop"

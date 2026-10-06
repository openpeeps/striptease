<p align="center">
  Strip metadata from audio, images and videos. 👑 Written in Nim language
</p>

<p align="center">
  <code>nimble install striptease</code> / <code>clue install striptease --build</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/striptease">API reference</a><br>
  <img src="https://github.com/openpeeps/striptease/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/striptease/workflows/docs/badge.svg" alt="Github Actions">
</p>

## 😍 Key Features
- [x] Open Source | `MIT` License
- [x] Written in Nim language
- [x] Zero dependencies, single static binary
- [x] Audio: `.wav` — drops `LIST INFO`, `id3`, `bext`, `iXML` and friends (rebuilds file, keeps `fmt` + `data`)
- [x] Images: `.jpg` / `.jpeg` (drops `APP0`–`APP15`, `COM`), `.png` (drops `tEXt` / `zTXt` / `iTXt`, `eXIf`, `iCCP`, `tIME`), `.gif` (drops comments, plain text and non-`NETSCAPE` app extensions), `.webp` (drops `EXIF`, `XMP`, `ICCP`)
- [x] Video: `.mp4` / `.mov` / `.m4v` (neutralises `udta`, `meta`, `uuid`, zeroes `mvhd` / `tkhd` / `mdhd` timestamps), `.avi` (neutralises `LIST INFO`, `id3`), `.mkv` / `.webm` (voids `Tags`, `Attachments`, `Info` title / date / apps)
- [x] RAW photos: `.cr2` `.nef` `.nrw` `.arw` `.srf` `.dng` (incl. Apple ProRAW) `.rw2` `.orf` `.pef` `.srw` `.tif` / `.tiff` — zeroes Artist, GPS, XMP and thumbnail metadata in place. MakerNote is preserved (it can hold serials/shutter count, but removing it breaks Apple decoders).
- [x] Canon `.cr3` (EXIF `uuid` sanitised, XMP zeroed) and `.heic` / `.heif` (Exif item sanitised, XMP items zeroed, image items untouched). Stripped Live Photo stills and videos stay playable standalone but lose their Live pairing.
- [x] Video-safe: size-preserving edits keep `stco`, `idx1` and `Cues` offsets valid, no re-encode
- [x] `--dry-run` and `--verbose` reporting, `--overwrite` protection by default
- [x] `--inspect` prints embedded metadata as pretty JSON without touching files

## Usage
```
striptease 0.3.0 – strip metadata from photos, PDFs, videos, and documents

MIT license | Made by Humans from OpenPeeps
  https://github.com/openpeeps/striptease

usage: striptease <input|input-dir> --out:<dir> [options]

required:
  <input>             file or directory (mixed formats allowed)
  -o, --out:<dir>     output directory for cleaned copies
                      (single file input plus --out:foo.ext writes one file,
                       not needed with --inspect)

supported formats:
  audio: .wav | images: .jpg .jpeg .png .gif .webp
  raw: .cr2 .nef .nrw .arw .srf .dng .rw2 .orf .pef .srw .tif .tiff
  video: .mp4 .mov .m4v .avi .mkv .webm | canon raw: .cr3 | heic: .heic .heif .hif

options:
  --dry-run           report only, write nothing
  --inspect           print metadata as pretty JSON, write nothing
  --verbose           per file kept and dropped chunks plus bytes saved
  --overwrite         overwrite existing files in out dir (default: skip)
  --keep-musical      WAV only: also keep cue, smpl, inst, acid chunks
  -h, --help          show this help
  --version           show version

```

## Examples
Strip a single photo (writes one file):

```sh
striptease photo.jpg --out:clean.jpg --verbose
```

Strip a mixed folder of audio, images and video:

```sh
striptease ./uploads --out:./clean --overwrite
```

Report only, write nothing:

```sh
striptease clip.mp4 --out:./clean --dry-run
```

Inspect embedded metadata as pretty JSON (writes nothing, `--out` not needed):

```sh
striptease photo.jpg --inspect
```

Keep WAV musical chunks (`cue`, `smpl`, `inst`, `acid`):

```sh
striptease take.wav --out:./clean --keep-musical
```

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/striptease/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/striptease/fork)

### 🎩 License
MIT license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.

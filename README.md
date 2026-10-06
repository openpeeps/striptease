<p align="center">
  Strip metadata from audio, images and videos. 👑 Written in Nim language
</p>

<p align="center">
  <code>nimble install striptease</code>
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
- [x] Video-safe: size-preserving edits keep `stco`, `idx1` and `Cues` offsets valid, no re-encode
- [x] `--dry-run` and `--verbose` reporting, `--overwrite` protection by default

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

# img2mp4

Convert image series to video with timecode as subtitle.

## Installation

### From Source

1. Install dependencies:
```bash
pip install -r requirements.txt
```

2. Make the script executable:
```bash
chmod +x img2mp4
```

3. Ensure `ffmpeg` is installed on your system.

### Debian Package

Build and install the Debian package:
```bash
dpkg-buildpackage -us -uc
sudo dpkg -i ../img2mp4_*.deb
```

### Requirements

- Python 3.6+
- Pillow (PIL) >= 10.0.0
- ffmpeg
- exiftool (optional, for better EXIF support)

## Usage

```bash
img2mp4 [OPTIONS] IMAGE... [DIRECTORY...]
```

If a directory is specified, all image files in that directory will be used, sorted in version order (natural sort). This correctly handles mixed text/numbers, ordering file-1.9 before file-1.10, file9a before file10a, etc.

When the first argument is a directory, the output video will be placed beside the directory (not inside it).

### Options

- `-g, --resize SIZE(W|WxH|W*H)[TYPE]`: Resize images to fit within SIZE. Default 1080 means height 1080. Can specify `WxH` or `W*H` for width and height. Type can be `p` or `i`, for example `1080i`, `4kp`
- `-r, --fps FPS`: Frame rate (default: 29.97)
- `-o, --output FILE.EXT`: Output file. Default uses the first IMAGE name with `.mp4` extension. Default codec is H.265 (use `-4` for H.264, or `.webm` extension for VP9).
- `--crf CRF NUM`: Specify constant rate factor
- `-b, --bandwidth NUM[unit=M]`: Specify bandwidth (bps), e.g., `4M`
- `-4, --h264`: Use H.264 codec (default: H.265)
- `-5, --h265`: Use H.265 codec (default, can be omitted)
- `-t, --theme NAME`: Specify subtitle theme (default: `split`)
- `-F, --filetime`: Use file modification time instead of EXIF (default: use EXIF)
- `-e, --exif FIELD`: Use specific EXIF field, `DateTimeOriginal` by default
- `-S, --nosubsec`: Ignore subsecond fields (default: included)
- `--timezone OFFSET`: Timezone offset (default: auto-detected from system)
- `-k, --delete`: Delete input image files after successful conversion
- `-q, --quiet`: Quiet mode (decrease loglevel, can be specified multiple times)
- `-v, --verbose`: Verbose output (use `-vv`, `-vvv` for more detail)

### Subtitle Themes

- **split** (default): Subtitle at top left and bottom right
  - Top left: Date (e.g., "2025-12-18")
  - Bottom right: Time with timezone (e.g., "03:21:53.123 +0800")
  
- **simple**: Subtitle at bottom right
  - Full datetime (e.g., "2025-12-18 03:21:53.123 +0800")
  
- **large**: Subtitle at bottom center
  - Large formatted datetime (e.g., "Thu Dec 18 03:21:53.123 PM CST 2025")

### EXIF Fields

Case-insensitive field names:
- `9003` / `Original` / `Taken` / `DateTimeOriginal` (default)
- `9004` / `Digitized` / `DateTimeDigitized`
- `0132` / `Modify` / `Modified` / `FileModifyDate` / `Date`

### Reference

| Resolution | Recommended Bitrate | Recommended CRF | Recommended FPS |
|------------|---------------------|----------------|-----------------|
| 4K         | 20–35 Mbps          | 18–22          | 30/60           |
| 1080p      | 5–8 Mbps            | 20–23          | 30/60           |
| 720p       | 2.5–5 Mbps          | 23–25          | 30              |

## Versions

Two implementations are provided:

1. **img2mp4** (Python): Full-featured implementation with PIL for EXIF extraction
2. **img2mp4.sh** (Bash): Lightweight bash implementation using exiftool

Both versions provide the same functionality and command-line interface.

## Examples

```bash
# Basic usage
img2mp4 image1.jpg image2.jpg image3.jpg

# Resize to 1080p, 30fps
img2mp4 -g 1080p -r 30 *.jpg

# Use H.264 codec with CRF 20 (H.265 is default)
img2mp4 -4 --crf 20 -o output.mp4 *.jpg

# Explicitly use H.265 with CRF 20
img2mp4 -5 --crf 20 -o output.mp4 *.jpg

# Use file modification time, simple theme
img2mp4 -F -t simple *.jpg

# 4K output with specific bandwidth
img2mp4 -g 4kp -b 25M *.jpg

# Process all images in a directory
img2mp4 /path/to/images/

# Process directory and delete source images after conversion
img2mp4 -k /path/to/images/

# Verbose mode to see ffmpeg command
img2mp4 -v *.jpg

# Quiet mode (suppress progress messages)
img2mp4 -q *.jpg
```


#!/bin/bash
    : ${RCSID:=$Id: img2mp4.sh 1.0.0 2024-12-18 - $}
    : ${PROGRAM_TITLE:="Convert image series to video with timecode as subtitle"}
    : ${PROGRAM_SYNTAX:="[OPTIONS] IMAGE..."}

    . shlib-import cliboot log
    option -g --resize =SIZE        "Resize images (default: 1080)"
    option -r --fps =FPS            "Frame rate (default: 29.97)"
    option -o --output =FILE         "Output file"
    option    --crf =NUM             "Constant rate factor"
    option -b --bandwidth =NUM       "Bandwidth (e.g., 4M)"
    option -4 --h264                 "Use H.264 codec"
    option -5 --h265                 "Use H.265 codec"
    option -t --theme =NAME          "Subtitle theme (split/simple/large, default: split)"
    option -F --filetime             "Use file modification time instead of EXIF"
    option -e --exif =FIELD          "EXIF field to use (default: DateTimeOriginal)"
    option -S --nosubsec             "Ignore subsecond fields"
    option    --timezone =OFFSET     "Timezone offset (default: auto-detected)"
    option -q --quiet
    option -v --verbose
    option -h --help
    option    --version

    # Default values
    FPS=29.97
    THEME="split"
    OUTPUT=""
    RESIZE=""
    CRF=""
    BANDWIDTH=""
    CODEC=""
    FILETIME=false
    EXIF_FIELD="DateTimeOriginal"
    NOSUBSEC=false
    TIMEZONE=""

# Get system timezone
get_system_timezone() {
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl show -p Timezone --value | date +%z 2>/dev/null || echo "+0000"
    else
        date +%z 2>/dev/null || echo "+0000"
    fi
}

# Parse resize specification
parse_resize() {
    local size_str="$1"
    size_str=$(echo "$size_str" | tr '[:upper:]' '[:lower:]' | xargs)
    
    local width=""
    local height=1080
    local interlace=false
    
    # Check for type suffix
    if [[ "$size_str" =~ [pi]$ ]]; then
        if [[ "$size_str" =~ i$ ]]; then
            interlace=true
        fi
        size_str="${size_str%?}"
    fi
    
    # Parse dimensions
    if [[ "$size_str" =~ [x*] ]]; then
        local sep
        if [[ "$size_str" == *"x"* ]]; then
            sep="x"
        else
            sep="*"
        fi
        width=$(echo "$size_str" | cut -d"$sep" -f1)
        height=$(echo "$size_str" | cut -d"$sep" -f2)
    else
        height="$size_str"
        width=$((height * 16 / 9))
    fi
    
    echo "$width $height $interlace"
}

# Extract EXIF metadata for video
extract_exif_metadata() {
    local img_path="$1"
    local metadata_file=$(mktemp -t img2mp4_metadata_XXXXXX)
    
    if ! command -v exiftool >/dev/null 2>&1; then
        echo ""
        return 1
    fi
    
    # Extract all EXIF data and format for ffmpeg metadata
    exiftool -s -s -s -j "$img_path" 2>/dev/null > "$metadata_file" || {
        rm -f "$metadata_file"
        echo ""
        return 1
    }
    
    echo "$metadata_file"
}

# Get EXIF datetime
get_exif_datetime() {
    local img_path="$1"
    local exif_field="$2"
    local include_subsec="$3"
    
    if ! command -v exiftool >/dev/null 2>&1; then
        return 1
    fi
    
    local dt_str
    case "$exif_field" in
        DateTimeOriginal|9003|original|taken|datetimeoriginal)
            dt_str=$(exiftool -s -s -s -DateTimeOriginal "$img_path" 2>/dev/null)
            ;;
        DateTimeDigitized|9004|digitized|datetimedigitized)
            dt_str=$(exiftool -s -s -s -DateTimeDigitized "$img_path" 2>/dev/null)
            ;;
        DateTime|0132|modify|modified|filemodifydate|date)
            dt_str=$(exiftool -s -s -s -DateTime "$img_path" 2>/dev/null)
            ;;
        *)
            dt_str=$(exiftool -s -s -s "-$exif_field" "$img_path" 2>/dev/null)
            ;;
    esac
    
    if [ -z "$dt_str" ]; then
        return 1
    fi
    
    # Convert format from "YYYY:MM:DD HH:MM:SS" to match expected format
    dt_str=$(echo "$dt_str" | sed 's/\([0-9]\{4\}\):\([0-9]\{2\}\):\([0-9]\{2\}\) \([0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\)/\1:\2:\3 \4/')
    
    if [ "$include_subsec" = "true" ]; then
        local subsec=$(exiftool -s -s -s -SubSecTimeOriginal "$img_path" 2>/dev/null)
        if [ -n "$subsec" ]; then
            dt_str="${dt_str}.${subsec}"
        fi
    fi
    
    echo "$dt_str"
}

# Get file modification time
get_file_datetime() {
    local img_path="$1"
    local include_subsec="$2"
    
    if [ "$include_subsec" = "true" ]; then
        stat -c "%y" "$img_path" 2>/dev/null | sed 's/\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\) \([0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\)\.\([0-9]\{3\}\).*/\1:\2:\3 \4.\5/' || return 1
    else
        stat -c "%y" "$img_path" 2>/dev/null | sed 's/\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\) \([0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\).*/\1:\2:\3 \4/' || return 1
    fi
}

# Generate subtitle ASS file
generate_subtitle_ass() {
    local theme="$1"
    local fps="$2"
    local timezone="$3"
    shift 3
    local datetimes=("$@")
    
    local frame_duration=$(awk "BEGIN {printf \"%.6f\", 1.0/$fps}")
    
    # Generate ASS header based on theme
    case "$theme" in
        split)
            cat <<EOF
[Script Info]
Title: img2mp4 Subtitles
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: TopLeft, Fira Code, 16, &H00FFFFFF, &H000000FF, &H00000000, &H80000000, 0, 0, 0, 0, 100, 100, 0, 0, 1, 1, 0, 7, 10, 10, 10, 1
Style: BottomRight, Fira Code, 16, &H00FFFFFF, &H000000FF, &H00000000, &H80000000, 0, 0, 0, 0, 100, 100, 0, 0, 1, 1, 0, 3, 10, 10, 10, 1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
EOF
            ;;
        simple)
            cat <<EOF
[Script Info]
Title: img2mp4 Subtitles
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: BottomRight, Fira Code, 16, &H00FFFFFF, &H000000FF, &H00000000, &H80000000, 0, 0, 0, 0, 100, 100, 0, 0, 1, 1, 0, 3, 10, 10, 10, 1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
EOF
            ;;
        large)
            cat <<EOF
[Script Info]
Title: img2mp4 Subtitles
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: BottomCenter, Arial, 24, &H00FFFFFF, &H000000FF, &H00000000, &H80000000, 0, 0, 0, 0, 100, 100, 0, 0, 1, 2, 0, 2, 10, 10, 10, 1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
EOF
            ;;
    esac
    
    # Generate dialogue lines
    local i=0
    for dt_str in "${datetimes[@]}"; do
        local start_time=$(awk "BEGIN {printf \"%.2f\", $i * $frame_duration}")
        local end_time=$(awk "BEGIN {printf \"%.2f\", ($i + 1) * $frame_duration}")
        
        local hours=$(awk "BEGIN {printf \"%d\", int($start_time / 3600)}")
        local minutes=$(awk "BEGIN {printf \"%02d\", int(($start_time % 3600) / 60)}")
        local secs=$(awk "BEGIN {printf \"%05.2f\", $start_time % 60}")
        local start_ass="${hours}:${minutes}:${secs}"
        
        hours=$(awk "BEGIN {printf \"%d\", int($end_time / 3600)}")
        minutes=$(awk "BEGIN {printf \"%02d\", int(($end_time % 3600) / 60)}")
        secs=$(awk "BEGIN {printf \"%05.2f\", $end_time % 60}")
        local end_ass="${hours}:${minutes}:${secs}"
        
        # Parse and format datetime
        if [ -n "$dt_str" ]; then
            local date_part=$(echo "$dt_str" | cut -d' ' -f1 | tr ':' '-')
            local time_part=$(echo "$dt_str" | cut -d' ' -f2)
            
            case "$theme" in
                split)
                    echo "Dialogue: 0,${start_ass},${end_ass},TopLeft,,0,0,0,,${date_part}"
                    echo "Dialogue: 0,${start_ass},${end_ass},BottomRight,,0,0,0,,${time_part} ${timezone}"
                    ;;
                simple)
                    echo "Dialogue: 0,${start_ass},${end_ass},BottomRight,,0,0,0,,${date_part} ${time_part} ${timezone}"
                    ;;
                large)
                    # Simplified large format
                    echo "Dialogue: 0,${start_ass},${end_ass},BottomCenter,,0,0,0,,${date_part} ${time_part} ${timezone}"
                    ;;
            esac
        fi
        
        i=$((i + 1))
    done
}

function setopt() {
    case "$1" in
        -g|--resize)
            RESIZE="$2";;
        -r|--fps)
            FPS="$2";;
        -o|--output)
            OUTPUT="$2";;
        --crf)
            CRF="$2";;
        -b|--bandwidth)
            BANDWIDTH="$2";;
        -4|--h264)
            CODEC="libx264";;
        -5|--h265)
            CODEC="libx265";;
        -t|--theme)
            THEME="$2";;
        -F|--filetime)
            FILETIME=true;;
        -e|--exif)
            EXIF_FIELD="$2";;
        -S|--nosubsec)
            NOSUBSEC=true;;
        --timezone)
            TIMEZONE="$2";;
        -q|--quiet)
            LOGLEVEL=$((LOGLEVEL - 1));;
        -v|--verbose)
            LOGLEVEL=$((LOGLEVEL + 1));;
        -h|--help)
            help "$1"; exit;;
        --version)
            show_version; exit;;
        *)
            quit "invalid option: $1";;
    esac
}

function main() {
    local IMAGES=("$@")
    
    if [ ${#IMAGES[@]} -eq 0 ]; then
        _error "No images specified"
        _error "Note: If using glob patterns like *.jpg, make sure they match files"
        _error "The shell expands globs before passing to the script"
        exit 1
    fi
    
    # Get timezone if not specified
    if [ -z "$TIMEZONE" ]; then
        TIMEZONE=$(get_system_timezone)
    fi
    
    # Sort images
    IFS=$'\n' IMAGES=($(sort <<<"${IMAGES[*]}"))
    unset IFS
    
    # Determine output file
    if [ -z "$OUTPUT" ]; then
        OUTPUT="${IMAGES[0]%.*}.mp4"
    fi
    
    # Determine codec (default to H.265)
    if [ -z "$CODEC" ]; then
        case "${OUTPUT##*.}" in
            webm)
                CODEC="libvpx-vp9"
                ;;
            *)
                CODEC="libx265"  # Default to H.265
                ;;
        esac
    fi
    
    # Extract datetimes
    local datetimes=()
    local include_subsec="true"
    [ "$NOSUBSEC" = "true" ] && include_subsec="false"
    
    for img in "${IMAGES[@]}"; do
        if [ ! -f "$img" ]; then
            _error "Image not found: $img"
            exit 1
        fi
        
        local dt_str
        if [ "$FILETIME" = "true" ]; then
            dt_str=$(get_file_datetime "$img" "$include_subsec")
        else
            dt_str=$(get_exif_datetime "$img" "$EXIF_FIELD" "$include_subsec")
        fi
        
        if [ -z "$dt_str" ]; then
            dt_str=$(get_file_datetime "$img" "$include_subsec")
        fi
        
        datetimes+=("$dt_str")
    done
    
    # Create temporary directory for symlinks
    local workdir=$(mktemp -d -t img2mp4_XXXXXX)
    trap "rm -rf '$workdir'" EXIT
    
    # Get file extension
    local img_ext="${IMAGES[0]##*.}"
    [ -z "$img_ext" ] && img_ext="jpg"
    
    # Create symlinks
    _log3 "Creating symlinks in temporary directory: $workdir"
    local i=1
    for img in "${IMAGES[@]}"; do
        local symlink_name=$(printf "image%03d.%s" $i "$img_ext")
        ln -s "$(realpath "$img")" "$workdir/$symlink_name"
        i=$((i + 1))
    done
    
    # Generate subtitle file
    local subtitle_file=$(mktemp -t img2mp4_subtitle_XXXXXX.ass)
    trap "rm -f '$subtitle_file'" EXIT
    
    {
        generate_subtitle_ass "$THEME" "$FPS" "$TIMEZONE" "${datetimes[@]}"
    } > "$subtitle_file"
    
    # Build ffmpeg command
    local ffmpeg_cmd=("ffmpeg" "-y" "-hide_banner" "-loglevel" "error")
    [ $LOGLEVEL -ge 1 ] && ffmpeg_cmd[4]="info"
    
    local pattern="$workdir/image%03d.$img_ext"
    ffmpeg_cmd+=("-framerate" "$FPS" "-i" "$pattern")
    
    # Build filter
    local filter_parts=()
    if [ -n "$RESIZE" ]; then
        local resize_info=($(parse_resize "$RESIZE"))
        local width="${resize_info[0]}"
        local height="${resize_info[1]}"
        local interlace="${resize_info[2]}"
        
        if [ "$interlace" = "true" ]; then
            filter_parts+=("scale=${width}:${height}:force_original_aspect_ratio=decrease:flags=lanczos,format=yuv420p")
        else
            filter_parts+=("scale=${width}:${height}:force_original_aspect_ratio=decrease:flags=lanczos")
        fi
    fi
    
    # Add subtitles
    local escaped_subtitle=$(echo "$subtitle_file" | sed 's/\\/\\\\/g; s/:/\\:/g; s/\[/\\[/g; s/\]/\\]/g; s/,/\\,/g')
    filter_parts+=("subtitles=$escaped_subtitle")
    
    if [ ${#filter_parts[@]} -gt 0 ]; then
        local filter_complex=$(IFS=','; echo "${filter_parts[*]}")
        ffmpeg_cmd+=("-vf" "$filter_complex")
    fi
    
    # Encoding options
    ffmpeg_cmd+=("-r" "$FPS")
    local total_duration=$(awk "BEGIN {printf \"%.6f\", ${#IMAGES[@]} / $FPS}")
    ffmpeg_cmd+=("-t" "$total_duration")
    ffmpeg_cmd+=("-c:v" "$CODEC")
    
    if [ -n "$CRF" ]; then
        ffmpeg_cmd+=("-crf" "$CRF")
    elif [ -n "$BANDWIDTH" ]; then
        local bitrate="$BANDWIDTH"
        if [[ "$BANDWIDTH" =~ [Mm]$ ]]; then
            bitrate=$(echo "$BANDWIDTH" | sed 's/[Mm]$//')
            bitrate=$((bitrate * 1000000))
        elif [[ "$BANDWIDTH" =~ [Kk]$ ]]; then
            bitrate=$(echo "$BANDWIDTH" | sed 's/[Kk]$//')
            bitrate=$((bitrate * 1000))
        fi
        ffmpeg_cmd+=("-b:v" "$bitrate")
    else
        ffmpeg_cmd+=("-crf" "22")
    fi
    
    # Copy EXIF metadata from first image to video
    if command -v exiftool >/dev/null 2>&1; then
        _log3 "Extracting EXIF metadata from first image"
        # Extract common EXIF fields and add as metadata
        local dt_original=$(exiftool -s -s -s -DateTimeOriginal "${IMAGES[0]}" 2>/dev/null)
        if [ -n "$dt_original" ]; then
            # Format datetime for video (YYYY-MM-DDTHH:MM:SS)
            local formatted_dt=$(echo "$dt_original" | sed 's/\([0-9]\{4\}\):\([0-9]\{2\}\):\([0-9]\{2\}\) \([0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\)/\1-\2-\3T\4/')
            ffmpeg_cmd+=("-metadata" "creation_time=$formatted_dt")
        fi
        
        local make=$(exiftool -s -s -s -Make "${IMAGES[0]}" 2>/dev/null)
        [ -n "$make" ] && ffmpeg_cmd+=("-metadata" "com.android.capture.firmware=$make")
        
        local model=$(exiftool -s -s -s -Model "${IMAGES[0]}" 2>/dev/null)
        [ -n "$model" ] && ffmpeg_cmd+=("-metadata" "com.android.capture.device=$model")
        
        local software=$(exiftool -s -s -s -Software "${IMAGES[0]}" 2>/dev/null)
        [ -n "$software" ] && ffmpeg_cmd+=("-metadata" "encoder=$software")
        
        local artist=$(exiftool -s -s -s -Artist "${IMAGES[0]}" 2>/dev/null)
        [ -n "$artist" ] && ffmpeg_cmd+=("-metadata" "artist=$artist")
        
        local copyright=$(exiftool -s -s -s -Copyright "${IMAGES[0]}" 2>/dev/null)
        [ -n "$copyright" ] && ffmpeg_cmd+=("-metadata" "copyright=$copyright")
        
        local description=$(exiftool -s -s -s -ImageDescription "${IMAGES[0]}" 2>/dev/null)
        [ -n "$description" ] && ffmpeg_cmd+=("-metadata" "description=$description")
    fi
    
    ffmpeg_cmd+=("-pix_fmt" "yuv420p" "-an" "$OUTPUT")
    
    # Run ffmpeg
    _log1 "Converting ${#IMAGES[@]} images to $OUTPUT..."
    _log1 "FPS: $FPS, Theme: $THEME, Codec: $CODEC"
    
    _log2 "FFmpeg command: ${ffmpeg_cmd[*]}"
    
    if [ $LOGLEVEL -ge 1 ]; then
        "${ffmpeg_cmd[@]}"
    else
        "${ffmpeg_cmd[@]}" >/dev/null 2>&1
    fi
    
    # Check output
    if [ -f "$OUTPUT" ]; then
        local file_size=$(stat -f%z "$OUTPUT" 2>/dev/null || stat -c%s "$OUTPUT" 2>/dev/null)
        local file_size_mb=$(awk "BEGIN {printf \"%.2f\", $file_size / 1048576}")
        echo "Successfully created: $OUTPUT ($file_size_mb MB)"
        if [ "$file_size" -lt 1048576 ]; then
            _warn "Warning: Generated video is very small ($file_size_mb MB), may indicate encoding issues"
        fi
    else
        _error "Output file was not created: $OUTPUT"
        exit 1
    fi
}

boot "$@"

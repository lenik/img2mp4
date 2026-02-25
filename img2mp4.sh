#!/bin/bash
    : ${RCSID:=$Id: img2mp4.sh 1.0.0 2024-12-18 - $}
    : ${PROGRAM_TITLE:="Convert image series to video with timecode as subtitle"}
    : ${PROGRAM_SYNTAX:="[OPTIONS] IMAGE..."}

    . shlib-import cliboot log
    option -g --resize =SIZE        "Resize images (default: 1080)"
    option -r --fps =FPS            "Frame rate (default: 29.97)"
    option -o --output =FILE        "Output file"
    option    --crf =NUM            "Constant rate factor"
    option -b --bandwidth =NUM      "Bandwidth (e.g., 4M)"
    option -4 --h264                "Use H.264 codec"
    option -5 --h265                "Use H.265 codec"
    option -T --theme =NAME         "Subtitle theme (split/simple/large, default: split)"
    option -t --sort-time           "Sort by file modification time (or EXIF time if --exif specified) instead of filename"
    option -F --filetime            "Use file modification time instead of EXIF"
    option -e --exif =FIELD         "EXIF field to use (default: DateTimeOriginal)"
    option -S --nosubsec            "Ignore subsecond fields"
    option    --timezone =OFFSET    "Timezone offset (default: auto-detected)"
    option -k --delete              "Delete input image files after successful conversion"
    option -f --force               "Overwrite existing output file without prompting"
    option -i --interactive         "Prompt for confirmation before overwriting existing output file"
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
    FORCE=false
    INTERACTIVE=false
    SORT_TIME=false

# Get system timezone
get_system_timezone() {
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl show -p Timezone --value | date +%z 2>/dev/null || echo "+0000"
    else
        date +%z 2>/dev/null || echo "+0000"
    fi
}

# Get timestamp for sorting (EXIF if available and use_exif=true, else file mtime)
get_sort_timestamp() {
    local img="$1"
    local use_exif="$2"
    local exif_field="$3"
    
    if [ "$use_exif" = "true" ] && [ -n "$exif_field" ] && command -v exiftool >/dev/null 2>&1; then
        # Try to get EXIF datetime
        local dt_str=$(exiftool -s -s -s "-${exif_field}" "$img" 2>/dev/null)
        if [ -n "$dt_str" ]; then
            # Parse EXIF datetime format: "YYYY:MM:DD HH:MM:SS" or "YYYY:MM:DD HH:MM:SS.xxx"
            # Convert to epoch timestamp
            local year month day hour min sec
            if [[ "$dt_str" =~ ^([0-9]{4}):([0-9]{2}):([0-9]{2})\ ([0-9]{2}):([0-9]{2}):([0-9]{2}) ]]; then
                year="${BASH_REMATCH[1]}"
                month="${BASH_REMATCH[2]}"
                day="${BASH_REMATCH[3]}"
                hour="${BASH_REMATCH[4]}"
                min="${BASH_REMATCH[5]}"
                sec="${BASH_REMATCH[6]}"
                # Try GNU date first, then fallback to other methods
                local ts=$(date -d "${year}-${month}-${day} ${hour}:${min}:${sec}" +%s 2>/dev/null)
                if [ -n "$ts" ] && [ "$ts" != "0" ]; then
                    echo "$ts"
                    return
                fi
                # Fallback: try with different date format or use file mtime
            fi
        fi
    fi
    
    # Fallback to file modification time
    stat -c %Y "$img" 2>/dev/null || stat -f %m "$img" 2>/dev/null || echo 0
}

# Collect images from directory
collect_images_from_directory() {
    local dir="$1"
    local sort_by_time="$2"
    local images=()
    local image_extensions="jpg jpeg png gif bmp tiff tif JPG JPEG PNG GIF BMP TIFF TIF"
    
    # Enable nullglob to handle cases where no files match
    local old_nullglob=$(shopt -p nullglob)
    shopt -s nullglob
    
    for ext in $image_extensions; do
        for img in "$dir"/*."$ext"; do
            [ -f "$img" ] && images+=("$img")
        done
    done
    
    # Restore nullglob setting
    eval "$old_nullglob"
    
    # Sort images
    if [ "$sort_by_time" = "true" ] && [ ${#images[@]} -gt 0 ]; then
        # Sort by timestamp
        local use_exif="false"
        [ "$FILETIME" != "true" ] && use_exif="true"
        IFS=$'\n' images=($(
            for img in "${images[@]}"; do
                local ts=$(get_sort_timestamp "$img" "$use_exif" "$EXIF_FIELD")
                printf '%s\t%s\n' "$ts" "$img"
            done | sort -n -t$'\t' -k1 | cut -f2-
        ))
        unset IFS
    elif [ ${#images[@]} -gt 0 ]; then
        # Sort using version sort (natural sort)
        # sort -V handles mixed text/numbers correctly
        IFS=$'\n' images=($(printf '%s\n' "${images[@]}" | sort -V))
        unset IFS
    fi
    
    printf '%s\n' "${images[@]}"
}

# Directory names (case-insensitive) to strip from output path when from dir, e.g. foo/DCIM/file.jpg -> foo/file.mp4
STRIP_DIR_NAMES="webcam auto-shoot camera b612 dcim images image pictures picture"

# Remove trailing path components that match STRIP_DIR_NAMES (case-insensitive). Sets effective_parent and was_stripped.
path_without_trailing_strip_dirs() {
    local path="$1"
    local resolved
    resolved=$(realpath "$path" 2>/dev/null) || resolved=$(cd "$path" 2>/dev/null && pwd) || resolved="$path"
    resolved=$(echo "$resolved" | sed 's|/\+|/|g')
    effective_parent="$resolved"
    was_stripped=false
    while [ -n "$effective_parent" ]; do
        local base
        base=$(basename "$effective_parent")
        local found=false
        for name in $STRIP_DIR_NAMES; do
            if [ "$(echo "$base" | tr '[:upper:]' '[:lower:]')" = "$(echo "$name" | tr '[:upper:]' '[:lower:]')" ]; then
                found=true
                break
            fi
        done
        [ "$found" = false ] && break
        was_stripped=true
        effective_parent=$(dirname "$effective_parent")
        [ "$effective_parent" = "$resolved" ] && break
    done
    [ -z "$effective_parent" ] && effective_parent="."
}

# Remove empty directories and their empty parents as far up as possible. Argument: list of directory paths.
remove_empty_parents() {
    local deleted_dirs=("$@")
    local dir
    while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        if [ -d "$dir" ] && [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
            if rmdir "$dir" 2>/dev/null; then
                _log2 "Removed empty directory: $dir"
                local parent
                parent=$(dirname "$dir")
                while [ -n "$parent" ] && [ "$parent" != "$dir" ] && [ -d "$parent" ]; do
                    if [ -n "$(ls -A "$parent" 2>/dev/null)" ]; then
                        break
                    fi
                    if rmdir "$parent" 2>/dev/null; then
                        _log2 "Removed empty directory: $parent"
                        dir="$parent"
                        parent=$(dirname "$parent")
                    else
                        break
                    fi
                done
            else
                _log3 "Could not remove directory: $dir"
            fi
        fi
    done < <(printf '%s\n' "${deleted_dirs[@]}" | awk -F/ 'NF { print NF"\t"$0 }' | sort -rn -k1 | cut -f2-)
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
        -T|--theme)
            THEME="$2";;
        -t|--sort-time)
            SORT_TIME=true;;
        -F|--filetime)
            FILETIME=true;;
        -e|--exif)
            EXIF_FIELD="$2";;
        -S|--nosubsec)
            NOSUBSEC=true;;
        --timezone)
            TIMEZONE="$2";;
        -k|--delete)
            DELETE=true;;
        -f|--force)
            FORCE=true;;
        -i|--interactive)
            INTERACTIVE=true;;
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

# Build command line arguments from current option values and store in global array CMD_ARGS
build_cmd_args() {
    CMD_ARGS=()
    
    [ -n "$RESIZE" ] && CMD_ARGS+=(-g "$RESIZE")
    [ "$FPS" != "29.97" ] && CMD_ARGS+=(-r "$FPS")
    # Don't pass -o: each directory will get its own output beside the directory
    [ -n "$CRF" ] && CMD_ARGS+=(--crf "$CRF")
    [ -n "$BANDWIDTH" ] && CMD_ARGS+=(-b "$BANDWIDTH")
    [ "$CODEC" = "libx264" ] && CMD_ARGS+=(-4)
    [ "$CODEC" = "libx265" ] && CMD_ARGS+=(-5)
    [ "$THEME" != "split" ] && CMD_ARGS+=(-T "$THEME")
    [ "$SORT_TIME" = "true" ] && CMD_ARGS+=(-t)
    [ "$FILETIME" = "true" ] && CMD_ARGS+=(-F)
    [ "$EXIF_FIELD" != "DateTimeOriginal" ] && CMD_ARGS+=(-e "$EXIF_FIELD")
    [ "$NOSUBSEC" = "true" ] && CMD_ARGS+=(-S)
    [ -n "$TIMEZONE" ] && CMD_ARGS+=(--timezone "$TIMEZONE")
    [ "$DELETE" = "true" ] && CMD_ARGS+=(-k)
    [ "$FORCE" = "true" ] && CMD_ARGS+=(-f)
    [ "$INTERACTIVE" = "true" ] && CMD_ARGS+=(-i)
    
    # Reconstruct -q/-v flags from LOGLEVEL
    # LOGLEVEL starts at 0, each -q decreases by 1, each -v increases by 1
    # We'll approximate by adding -v for positive LOGLEVEL and -q for negative
    # This isn't perfect but should work for most cases
    local i
    if [ "$LOGLEVEL" -gt 0 ]; then
        for ((i=0; i<LOGLEVEL; i++)); do
            CMD_ARGS+=(-v)
        done
    elif [ "$LOGLEVEL" -lt 0 ]; then
        for ((i=0; i>LOGLEVEL; i--)); do
            CMD_ARGS+=(-q)
        done
    fi
}

# Create one video from IMAGES (global). Uses OUTPUT if set; else FROM_DIR for default dir output; else first image base. Deletes files only when DELETE=true (no rmdir).
mkvideo_from_files() {
    [ ${#IMAGES[@]} -eq 0 ] && return
    # Determine output file
    if [ -z "$OUTPUT" ] && [ -n "$FROM_DIR" ]; then
        local resolved
        resolved=$(realpath "$FROM_DIR" 2>/dev/null) || resolved="$FROM_DIR"
        local dir_name dir_parent
        dir_name=$(basename "$resolved")
        dir_parent=$(dirname "$resolved")
        OUTPUT="$dir_parent/$dir_name.mp4"
    fi
    if [ -z "$OUTPUT" ]; then
        OUTPUT="${IMAGES[0]%.*}.mp4"
    fi
    # Sort images
    if [ "$SORT_TIME" = "true" ]; then
        # Sort by timestamp (EXIF if --exif specified, else file mtime)
        local use_exif="false"
        [ "$FILETIME" != "true" ] && use_exif="true"
        IFS=$'\n' IMAGES=($(
            for img in "${IMAGES[@]}"; do
                local ts=$(get_sort_timestamp "$img" "$use_exif" "$EXIF_FIELD")
                printf '%s\t%s\n' "$ts" "$img"
            done | sort -n -t$'\t' -k1 | cut -f2-
        ))
        unset IFS
    else
        # Sort using version sort (natural sort)
        IFS=$'\n' IMAGES=($(printf '%s\n' "${IMAGES[@]}" | sort -V))
        unset IFS
    fi
    
    # Get timezone if not specified
    if [ -z "$TIMEZONE" ]; then
        TIMEZONE=$(get_system_timezone)
    fi
    
    # Check if output file exists and handle accordingly
    if [ -f "$OUTPUT" ]; then
        if [ "$FORCE" = "true" ]; then
            _log2 "Output file exists, overwriting: $OUTPUT"
        elif [ "$INTERACTIVE" = "true" ]; then
            printf "Output file exists: %s\nOverwrite? [y/N]: " "$OUTPUT"
            local response
            if ! read -r response; then
                _error "Operation cancelled by user"
                exit 1
            fi
            case "$response" in
                [yY]|[yY][eE][sS])
                    _log2 "User confirmed overwrite"
                    ;;
                *)
                    _error "Operation cancelled by user"
                    exit 1
                    ;;
            esac
        else
            _error "Output file already exists: $OUTPUT"
            _error "Use -f/--force to overwrite or -i/--interactive to confirm"
            exit 1
        fi
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
        
        # Copy EXIF metadata from first image to video using exiftool
        if command -v exiftool >/dev/null 2>&1; then
            _log2 "Copying EXIF metadata from first image to video..."
            # Copy all EXIF metadata from first image
            if [ $LOGLEVEL -ge 2 ]; then
                exiftool -overwrite_original -tagsFromFile "${IMAGES[0]}" "$OUTPUT"
            else
                exiftool -overwrite_original -tagsFromFile "${IMAGES[0]}" "$OUTPUT" >/dev/null 2>&1
            fi
            
            # Add generator/version info to Software field
            local current_software=$(exiftool -s -s -s -Software "$OUTPUT" 2>/dev/null)
            local generator_info="img2mp4 1.0.0"
            local new_software
            
            if [ -n "$current_software" ]; then
                new_software="${current_software}, ${generator_info}"
            else
                new_software="$generator_info"
            fi
            
            # Set Software field
            if [ $LOGLEVEL -ge 2 ]; then
                exiftool -overwrite_original -Software="$new_software" "$OUTPUT"
            else
                exiftool -overwrite_original -Software="$new_software" "$OUTPUT" >/dev/null 2>&1
            fi
            
            _log2 "EXIF metadata copied successfully"
        else
            _log3 "exiftool not found, skipping EXIF metadata copy"
        fi
        
        # Delete input images if requested (files only; no rmdir)
        if [ "$DELETE" = true ]; then
            _log1 "Deleting ${#IMAGES[@]} input image files..."
            for img in "${IMAGES[@]}"; do
                if [ -f "$img" ]; then
                    if rm -f "$img"; then
                        _log2 "Deleted: $img"
                    else
                        _warn "Could not delete: $img"
                    fi
                fi
            done
        fi
    else
        _error "Output file was not created: $OUTPUT"
        exit 1
    fi
}

# Create one video from all images in a directory; if -k, remove empty parents after delete.
mkvideo_from_dir() {
    local dir_path="$1"
    local sort_by_time="$SORT_TIME"
    IMAGES=($(collect_images_from_directory "$dir_path" "$sort_by_time"))
    if [ ${#IMAGES[@]} -eq 0 ]; then
        _warn "No image files found in directory: $dir_path"
        return 0
    fi
    # Strip trailing path components in STRIP_DIR_NAMES (e.g. foo/DCIM -> foo/filename.mp4)
    path_without_trailing_strip_dirs "$dir_path"
    if [ "$was_stripped" = true ]; then
        local first_basename
        first_basename=$(basename "${IMAGES[0]%.*}")
        OUTPUT="$effective_parent/$first_basename.mp4"
        FROM_DIR=""
    else
        OUTPUT=""
        FROM_DIR="$dir_path"
    fi
    mkvideo_from_files
    if [ "$DELETE" = true ]; then
        local deleted_dirs=()
        local img
        for img in "${IMAGES[@]}"; do
            local img_dir
            img_dir=$(dirname "$(realpath "$img" 2>/dev/null || echo "$img")")
            local found=false d
            for d in "${deleted_dirs[@]}"; do
                [ "$d" = "$img_dir" ] && found=true && break
            done
            [ "$found" = false ] && deleted_dirs+=("$img_dir")
        done
        remove_empty_parents "${deleted_dirs[@]}"
    fi
}

function main() {
    local INPUTS=("$@")
    if [ ${#INPUTS[@]} -eq 0 ]; then
        _error "No images or directories specified"
        _error "Note: If using glob patterns like *.jpg, make sure they match files"
        exit 1
    fi
    
    # Separate directory and file arguments
    local dirs=()
    local files=()
    local path
    for path in "${INPUTS[@]}"; do
        if [ ! -e "$path" ]; then
            _error "Path not found: $path"
            exit 1
        fi
        if [ -d "$path" ]; then
            dirs+=("$path")
        else
            files+=("$path")
        fi
    done
    
    # Get timezone if not specified
    if [ -z "$TIMEZONE" ]; then
        TIMEZONE=$(get_system_timezone)
    fi
    
    # One video per directory
    local dir_path
    for dir_path in "${dirs[@]}"; do
        mkvideo_from_dir "$dir_path"
    done
    
    # One video for all remaining file arguments
    if [ ${#files[@]} -gt 0 ]; then
        IMAGES=("${files[@]}")
        FROM_DIR=""
        # OUTPUT already set by -o if user passed it
        mkvideo_from_files
    fi
}

boot "$@"

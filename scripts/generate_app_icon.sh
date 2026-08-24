#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
master_icon="$project_dir/Resources/AppIconMaster.png"
iconset_dir="$project_dir/Resources/AppIcon.iconset"
output_icon="$project_dir/Resources/AppIcon.icns"
icon_tmp_dir=$(mktemp -d /private/tmp/lucent-icon.XXXXXX)
trap 'rm -rf "$icon_tmp_dir"' EXIT

# The original master already contains a rounded macOS tile. Crop through that
# tile's transparent inset so macOS does not wrap it in a second pale container.
sips --cropToHeightWidth 900 900 "$master_icon" --out "$icon_tmp_dir/full-bleed.png" >/dev/null

mkdir -p "$iconset_dir"
for specification in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"
do
    dimensions=(${=specification})
    sips --resampleHeightWidth "${dimensions[1]}" "${dimensions[1]}" \
        "$icon_tmp_dir/full-bleed.png" --out "$iconset_dir/${dimensions[2]}" >/dev/null
done

icns_builder="$project_dir/.build-local/bin/MakeICNS"
if [[ ! -x "$icns_builder" ]]; then
    icns_builder="$icon_tmp_dir/MakeICNS"
    swiftc "$project_dir/scripts/MakeICNS.swift" -o "$icns_builder"
fi
"$icns_builder" "$iconset_dir" "$output_icon"
echo "$output_icon"

#!/bin/bash

THEMES=("min-rog")
RESOLUTIONS=("1080p" "2k" "4k")

for resolution in "${RESOLUTIONS[@]}"; do
  echo "./render-assets.sh \"$theme\" \"$resolution\": "
  ./render-assets.sh "$theme" "$resolution"
done

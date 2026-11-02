#!/bin/bash
# Remove the files install.sh put in place.
set -euo pipefail
LIST=/var/lib/s15-desktop-net.files
[ -f "$LIST" ] || { echo "nothing installed"; exit 0; }
while read -r f; do rm -f "/$f"; done < "$LIST"
rm -f "$LIST"; ldconfig; echo "removed"

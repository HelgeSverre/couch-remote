#!/usr/bin/env bash
# Downloads app icons from the App Store (iTunes Lookup API) into Sources/TVKit/Resources/AppIcons.
#
# Icons for apps installed on the reference TV are the TV's own Smart Hub tiles instead, copied with
# `sdb pull /opt/share/webappservice/apps_icon/all/<app id>/304x304.png` (needs Developer Mode) and
# scaled to 256 px. This script skips files that exist, so those tiles stay unless you pass --force.
# Each line: <file slug> <App Store track ID>. Slugs match AppBrand.icon in AppCatalog.swift.
#   scripts/fetch-icons.sh          fetch missing icons
#   scripts/fetch-icons.sh --force  fetch all again
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Sources/TVKit/Resources/AppIcons
mkdir -p "$OUT"

while read -r slug id; do
  [[ -z "$slug" || "$slug" == \#* ]] && continue
  file="$OUT/$slug.png"
  [[ -f "$file" && "${1:-}" != "--force" ]] && continue
  url=$(curl -fsS "https://itunes.apple.com/lookup?id=$id&country=no" \
    | python3 -I -c 'import json,sys; r=json.load(sys.stdin)["results"]; print(r[0]["artworkUrl512"] if r else "")')
  if [[ -z "$url" ]]; then echo "no listing for $slug ($id)" >&2; continue; fi
  curl -fsS "${url%/*}/256x256bb.png" -o "$file"
  echo "$slug"
done <<'EOF'
youtube         544007664
youtube-kids    936971630
netflix         363590051
prime-video     545519333
disney-plus     1446075923
hbo-max         1666653815
nrk-tv          385114898
tv-2-play       675096718
rikstv          787496930
strim           1361563966
viaplay         409702778
skyshowtime     1616478112
discovery-plus  395972146
allente         914487438
telia-play      1213922701
apple-tv        1174078549
apple-music     1108187390
spotify         324684580
plex            383457673
twitch          460177396
xbox            736179781
pluto-tv        751712884
rakuten-tv      532577301
google-meet     1096918571
tiktok          835599320
dazn            1129523589
tidal           913943275
deezer          292738169
crunchyroll     329913454
EOF

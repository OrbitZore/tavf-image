#!/usr/bin/env bash
# gen-catalog.sh — 给 catalog.json 补上每个文件的 size / sha256（P2-01）
#
# 两种模式：
#   --local <dir>     从本地已构建产物算（CI release job 用这个）
#   --release [tag]   从 GitHub Release API 读 digest（本地/事后补录用这个）
#
# 用法：
#   scripts/gen-catalog.sh --local dist
#   scripts/gen-catalog.sh --release            # latest
#   scripts/gen-catalog.sh --release v1.3.1
#
# 输入是本仓库的 catalog.src.json（只写"有哪些镜像、各角色用哪个 asset"），
# 输出 catalog.json（带 size/sha256/uncompressed）。这样校验和永远来自实际产物，
# 不是手抄的。
set -uo pipefail

REPO="OrbitZore/tavf-image"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/catalog.src.json"
OUT="$ROOT/catalog.json"
MODE=""
DIR=""
TAG="latest"

while [ $# -gt 0 ]; do
  case "$1" in
    --local)   MODE=local;    DIR=${2:?--local 需要一个目录}; shift 2 ;;
    --release)
      MODE=release
      if [ $# -ge 2 ] && [ "${2:0:2}" != "--" ]; then TAG=$2; shift; fi
      shift ;;
    --src)     SRC=${2:?}; shift 2 ;;
    --out)     OUT=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[ -f "$SRC" ] || { echo "找不到 catalog 源文件: $SRC" >&2; exit 2; }

command -v python3 >/dev/null || { echo "需要 python3" >&2; exit 3; }

# Read the gzip ISIZE trailer over HTTP.
#   tail4_http <url> <total-size>
# A suffix range (`bytes=-4`) is answered 501 by GitHub's release CDN, so ask for
# the explicit last four bytes instead.
tail4_http() {
  local url=$1 total=$2 tmp code
  [ -n "$total" ] && [ "$total" -ge 4 ] || { echo 0; return; }
  tmp=$(mktemp)
  # -L is required: GitHub redirects to a signed CDN URL, and the Range header is
  # re-sent after the redirect. Without it we just see the 302.
  code=$(curl -sSL -o "$tmp" -w '%{http_code}' -r "$((total - 4))-$((total - 1))" "$url" 2>/dev/null || echo 000)
  if [ "$code" = "206" ] && [ "$(wc -c <"$tmp")" -eq 4 ]; then
    python3 - "$tmp" <<'PY'
import struct, sys
print(struct.unpack('<I', open(sys.argv[1], 'rb').read())[0])
PY
  else
    echo 0
  fi
  rm -f "$tmp"
}

TMPJSON=$(mktemp)

if [ "$MODE" = local ]; then
  [ -d "$DIR" ] || { echo "目录不存在: $DIR" >&2; exit 2; }
  if ! python3 - "$SRC" "$DIR" "$TMPJSON" <<'PY'
import hashlib, json, os, struct, sys
src, d, out = sys.argv[1], sys.argv[2], sys.argv[3]
cat = json.load(open(src))
missing = []
for img in cat['images']:
    for role in ('kernel', 'initrd', 'rootfs'):
        asset = img.get(role)
        if not asset:
            continue
        path = os.path.join(d, asset)
        if not os.path.isfile(path):
            missing.append(asset)
            continue
        h = hashlib.sha256()
        with open(path, 'rb') as f:
            for chunk in iter(lambda: f.read(1 << 20), b''):
                h.update(chunk)
        img[f'{role}_bytes'] = os.path.getsize(path)
        img[f'{role}_sha256'] = h.hexdigest()
        if asset.endswith('.gz') and os.path.getsize(path) >= 4:
            with open(path, 'rb') as f:
                f.seek(-4, 2)
                img[f'{role}_uncompressed'] = struct.unpack('<I', f.read(4))[0]
if missing:
    print('缺少产物文件: ' + ', '.join(sorted(set(missing))), file=sys.stderr)
    sys.exit(4)
json.dump(cat, open(out, 'w'), ensure_ascii=False, indent=2)
open(out, 'a').write('\n')
PY
  then
    echo "本地模式：产物不全，未生成 catalog" >&2
    exit 4
  fi
else
  # release mode: read digests from the GitHub API
  API="https://api.github.com/repos/$REPO/releases/$TAG"
  RELJSON=$(mktemp)
  if ! curl -fsSL -o "$RELJSON" "$API"; then
    echo "拉取 release 失败: $API" >&2; exit 4
  fi
  python3 - "$SRC" "$RELJSON" "$TMPJSON" <<'PY'
import json, sys
src, rel, out = sys.argv[1], sys.argv[2], sys.argv[3]
cat = json.load(open(src))
r = json.load(open(rel))
assets = {a['name']: a for a in r.get('assets', [])}
missing = []
for img in cat['images']:
    for role in ('kernel', 'initrd', 'rootfs'):
        asset = img.get(role)
        if not asset:
            continue
        a = assets.get(asset)
        if not a:
            missing.append(asset)
            continue
        img[f'{role}_bytes'] = a['size']
        dg = (a.get('digest') or '').replace('sha256:', '')
        if dg:
            img[f'{role}_sha256'] = dg
json.dump(cat, open(out, 'w'), ensure_ascii=False, indent=2)
open(out, 'a').write('\n')
if missing:
    print('release 里没有这些 asset: ' + ', '.join(sorted(set(missing))), file=sys.stderr)
    sys.exit(4)
PY
  # gzip uncompressed size needs the trailer; the API does not expose it
  if [ -f "$TMPJSON" ]; then
    python3 - "$TMPJSON" >"$TMPJSON.names" <<'PY'
import json, sys
cat = json.load(open(sys.argv[1]))
for img in cat['images']:
    r = img.get('rootfs') or ''
    if r.endswith('.gz'):
        print(r)
PY
    while IFS= read -r asset; do
      [ -n "$asset" ] || continue
      url="https://github.com/$REPO/releases/$TAG/download/$asset"
      asize=$(python3 -c "
import json
cat = json.load(open('$TMPJSON'))
for img in cat['images']:
    if img.get('rootfs') == '$asset':
        print(img.get('rootfs_bytes', 0))
        break
else:
    print(0)")
      unc=$(tail4_http "$url" "$asize")
      [ "$unc" = "0" ] && echo "  ! $asset 读不到 ISIZE（跳过 uncompressed）" >&2
      python3 - "$TMPJSON" "$asset" "$unc" <<'PY'
import json, sys
path, asset, unc = sys.argv[1], sys.argv[2], int(sys.argv[3])
cat = json.load(open(path))
for img in cat['images']:
    if img.get('rootfs') == asset and unc > 0:
        img['rootfs_uncompressed'] = unc
json.dump(cat, open(path, 'w'), ensure_ascii=False, indent=2)
open(path, 'a').write('\n')
PY
    done <"$TMPJSON.names"
    rm -f "$TMPJSON.names"
  fi
fi

# stamp the catalog with the date it was generated
python3 - "$TMPJSON" "$OUT" <<'PY'
import json, sys, datetime
src, out = sys.argv[1], sys.argv[2]
cat = json.load(open(src))
cat['updated'] = datetime.date.today().isoformat()
json.dump(cat, open(out, 'w'), ensure_ascii=False, indent=2)
open(out, 'a').write('\n')
PY

echo "已生成 $OUT"
python3 - "$OUT" <<'PY'
import json, sys
cat = json.load(open(sys.argv[1]))
print(f"version={cat.get('version')} updated={cat.get('updated')} images={len(cat['images'])}")
for img in cat['images']:
    parts = []
    for role in ('kernel', 'initrd', 'rootfs'):
        if not img.get(role):
            continue
        b = img.get(f'{role}_bytes')
        h = img.get(f'{role}_sha256')
        u = img.get(f'{role}_uncompressed')
        s = f"{role}={b / 1048576:.0f}MiB" if b else f"{role}=?"
        s += f" sha={h[:8]}…" if h else " sha=?"
        if u:
            s += f" → {u / 1073741824:.2f}GiB"
        parts.append(s)
    print(f"  {img['name']:16s} " + "  ".join(parts))
PY

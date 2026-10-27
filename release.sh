#!/bin/bash
# usage: ./release.sh v4
set -uo pipefail
cd "$(dirname "$0")"

TAG="${1:-}"
[ -n "$TAG" ] || { echo "usage: ./release.sh v4"; exit 2; }

LOG="release.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

say(){ printf '\n===== %s =====\n' "$1"; }

say "1/6  target $TAG"
sed -i '' "s|^SELF_URL=.*|SELF_URL=\"https://raw.githubusercontent.com/madebyshaurya/spearzee/$TAG/spearzee.sh\"|" spearzee.sh
sed -i '' 's|^SELF_SHA=.*|SELF_SHA=""|' spearzee.sh

say "2/6  syntax"
bash -n spearzee.sh || { echo "SYNTAX FAIL"; exit 1; }
echo ok

say "3/6  hash"
H=$(sed -e 's|^SELF_SHA=.*|SELF_SHA=""|' spearzee.sh | shasum -a 256 | awk '{print $1}')
sed -i '' "s|^SELF_SHA=.*|SELF_SHA=\"$H\"|" spearzee.sh
H2=$(sed -e 's|^SELF_SHA=.*|SELF_SHA=""|' spearzee.sh | shasum -a 256 | awk '{print $1}')
echo "H=$H"
echo "H2=$H2"
[ "$H" = "$H2" ] || { echo "HASH NOT STABLE"; exit 1; }
grep -n '^SELF_URL=\|^SELF_SHA=' spearzee.sh

say "4/6  commit"
git add -A
if git diff --cached --quiet; then
  echo "nothing new to commit"
else
  git commit -m "$TAG" || { echo "COMMIT FAILED"; exit 1; }
fi
git log --oneline -1

say "5/6  tag + push"
git tag -d "$TAG" >/dev/null 2>&1 && echo "removed stale local tag"
git tag "$TAG" || { echo "TAG FAILED"; exit 1; }
git push origin main  || { echo "PUSH FAILED"; exit 1; }
git push origin --tags || { echo "TAG PUSH FAILED"; exit 1; }
git ls-remote --tags origin | tail -3

say "6/6  verify live"
URL="https://raw.githubusercontent.com/madebyshaurya/spearzee/$TAG/spearzee.sh"
sleep 2
curl -fsSL "$URL" | grep -n 'phase "' || echo "FETCH FAILED"

printf '\n########## DONE %s ##########\n' "$TAG"
echo "send him:  curl -fsSL $URL | bash"

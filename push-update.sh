#!/bin/bash
# Publish the deck.
#
# THE FILE IN THIS FOLDER IS THE SOURCE OF TRUTH.
#
# By default this script publishes reference-deck.html exactly as it
# stands here: it bumps DECK_VERSION, commits and pushes. It does not look in
# ~/Downloads at all.
#
# Only --from-downloads pulls a browser-exported copy in, and even then it
# refuses a copy whose CONTENT is stale. The check is not a timestamp: a stale
# export that was re-downloaded, copied or touched this morning has a brand new
# timestamp and is still the same old file. So the download is compared, with
# the DECK_VERSION stamp neutralised, against the file in this folder and
# against every version of the deck this repository has ever committed. If it
# matches an older committed version it is refused, whatever its clock says.
# The DECK_VERSION carried inside the download is checked too: a copy exported
# from a build that is not the one in this folder is refused, because pulling it
# in would throw away everything that changed since that build. A clock is
# consulted once, and last: an older download is refused when the file in this
# folder has uncommitted changes it would undo.
#
#   ./push-update.sh                            publish what is in this folder
#   ./push-update.sh -m "what changed"          ... with your own commit message
#   ./push-update.sh --from-downloads           pull the newest ~/Downloads export first
#   ./push-update.sh --from-downloads --force   ... even if it is stale (asks you first,
#                                               and tells you exactly what you would lose)
#
set -euo pipefail
cd "$(dirname "$0")"

DECK=reference-deck.html
FROM_DOWNLOADS=0
FORCE=0
MSG="deck update"

while [ $# -gt 0 ]; do
  case "$1" in
    --from-downloads|-d) FROM_DOWNLOADS=1 ;;
    --force) FORCE=1 ;;
    -m) shift; MSG="${1:-deck update}" ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; echo "Try: $0 --help"; exit 2 ;;
  esac
  shift
done

[ -f "$DECK" ] || { echo "No $DECK in $(pwd). Nothing to publish."; exit 1; }

# The DECK_VERSION stamp is rewritten on every push, so it is the one line that
# is guaranteed to differ between two copies of otherwise identical work. Every
# content comparison below neutralises it first, so "same deck, different stamp"
# reads as the same deck.
norm_hash() {
  sed "s/const DECK_VERSION = '[^']*'/const DECK_VERSION = 'NORMALISED'/" \
    | shasum -a 256 | cut -d' ' -f1
}
version_of() {
  local v
  v=$(grep -m1 -o "const DECK_VERSION = '[^']*'" "$1" 2>/dev/null || true)
  if [ -z "$v" ]; then echo "(no DECK_VERSION found)"; else echo "${v#*\'}" | sed "s/'$//"; fi
}

if [ "$FROM_DOWNLOADS" -eq 1 ]; then
  NEWEST=$(ls -t "$HOME"/Downloads/reference-deck*.html 2>/dev/null | head -1 || true)
  if [ -z "$NEWEST" ]; then
    echo "--from-downloads was asked for, but there is no reference-deck*.html in ~/Downloads."
    exit 1
  fi

  DL_TIME=$(stat -f %m "$NEWEST")
  REPO_TIME=$(stat -f %m "$DECK")
  DL_VER=$(version_of "$NEWEST")
  REPO_VER=$(version_of "$DECK")
  echo "download : $NEWEST"
  echo "           $(date -r "$DL_TIME" '+%Y-%m-%d %H:%M:%S')  DECK_VERSION $DL_VER"
  echo "repo file: $DECK"
  echo "           $(date -r "$REPO_TIME" '+%Y-%m-%d %H:%M:%S')  DECK_VERSION $REPO_VER"

  if cmp -s "$NEWEST" "$DECK"; then
    echo "They are byte for byte identical. Nothing to pull in; publishing the repo file."
  else
    DL_HASH=$(norm_hash < "$NEWEST")
    REPO_HASH=$(norm_hash < "$DECK")

    REASON=""
    LOSES=""

    if [ "$DL_HASH" = "$REPO_HASH" ]; then
      echo "Same deck, only the DECK_VERSION stamp differs. Nothing to pull in; publishing the repo file."
    else
      # Every version of the deck this repository has ever committed, newest
      # first. If the download IS one of them, it is a copy of already-published
      # work and cannot be an export of anything newer.
      MATCH_SHA=""
      MATCH_VER=""
      MATCH_WHEN=""
      TIP_SHA=$(git log -1 --format='%H' -- "$DECK" 2>/dev/null || true)
      while IFS= read -r SHA; do
        [ -n "$SHA" ] || continue
        OLD_HASH=$(git show "$SHA:./$DECK" 2>/dev/null | norm_hash || true)
        if [ "$OLD_HASH" = "$DL_HASH" ]; then
          MATCH_SHA="$SHA"
          MATCH_VER=$(git show "$SHA:./$DECK" 2>/dev/null \
            | grep -m1 -o "const DECK_VERSION = '[^']*'" | sed "s/.*'\(.*\)'.*/\1/" || true)
          MATCH_WHEN=$(git log -1 --format='%ad' --date=format:'%Y-%m-%d %H:%M:%S' "$SHA" 2>/dev/null || true)
          break
        fi
      done < <(git log --format='%H' -n 200 -- "$DECK" 2>/dev/null || true)

      if [ -n "$MATCH_SHA" ] && [ "$MATCH_SHA" != "$TIP_SHA" ]; then
        REASON="that download is a copy of an OLDER committed version of the deck."
        LOSES="every change made since ${MATCH_SHA:0:7} ($MATCH_WHEN, DECK_VERSION $MATCH_VER)"
      elif [ -n "$MATCH_SHA" ]; then
        REASON="that download is a copy of the version already committed here, with local changes on top of it undone."
        LOSES="the uncommitted changes now in $DECK"
      elif [ "$DL_VER" != "$REPO_VER" ]; then
        REASON="that download was exported from a different build ($DL_VER), not the one in this folder ($REPO_VER)."
        LOSES="everything that changed between build $DL_VER and build $REPO_VER"
      elif [ "$DL_TIME" -lt "$REPO_TIME" ] && ! git diff --quiet -- "$DECK" 2>/dev/null; then
        # Last safety net, and the only place a clock is consulted at all. It
        # fires only when there is real work at risk: the file in this folder
        # has uncommitted changes, and the download predates them. With a clean
        # working file the content checks above have already settled it, so an
        # odd timestamp on a same-build export is not a reason to refuse.
        REASON="that download predates the uncommitted changes in this folder."
        LOSES="the uncommitted work done here since $(date -r "$DL_TIME" '+%Y-%m-%d %H:%M:%S')"
      fi

      if [ -n "$REASON" ]; then
        echo
        echo "REFUSED: $REASON"
        echo "Publishing it would throw away $LOSES."
        echo "Re-export from the live deck, or, if you really mean to go back to that copy, run:"
        echo "    $0 --from-downloads --force"
        if [ "$FORCE" -eq 1 ]; then
          echo
          echo "--force was given. This would REPLACE the deck in this folder:"
          echo "    keep    : $DECK          DECK_VERSION $REPO_VER"
          echo "    with    : $NEWEST  DECK_VERSION $DL_VER"
          echo "    you lose: $LOSES"
          printf 'Type y to overwrite and publish the download anyway. [y/N] '
          read -r ANSWER
          case "$ANSWER" in
            y|Y|yes|YES) cp "$NEWEST" "$DECK"; echo "Overwritten on your say-so." ;;
            *) echo "Left alone. Nothing published."; exit 1 ;;
          esac
        else
          exit 1
        fi
      else
        cp "$NEWEST" "$DECK"
        echo "Pulled the download in: same build ($DL_VER), newer content."
      fi
    fi
  fi
fi

# Bump DECK_VERSION so every browser purges its locally stored edits (the pushed
# file already carries them baked in; a stale restore could garble the new deck).
NEW_VERSION="v$(date +%Y%m%d-%H%M%S)"
sed -i '' "s/const DECK_VERSION = '[^']*'/const DECK_VERSION = '$NEW_VERSION'/" "$DECK"
grep -q "const DECK_VERSION = '$NEW_VERSION'" "$DECK" || { echo "DECK_VERSION bump failed. Nothing published."; exit 1; }
echo "DECK_VERSION is now $NEW_VERSION"

git add -A && git commit -m "$MSG ($NEW_VERSION)" && git push
echo "Pushed. Live in about 30 seconds at the same URL."

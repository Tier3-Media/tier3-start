#!/bin/bash
# Tier3 Media: first-time setup for Claude (macOS).
# Claude runs this for the teammate. It needs no Homebrew, no shell edits and no typing in Terminal.
# It installs the GitHub tool, signs in through the browser, installs the Tier3 kit and downloads the
# client brains. Every line that starts with "SAY:" is what Claude tells the person, word for word.
# Lines that start with "STATUS:" are for Claude. Safe to run again: finished steps are skipped.
#
# Exit codes: 0 ready, 10 waiting for the Apple developer tools install, 20 no access to Tier3-Media yet,
#             30 something failed (the line before says what).

ORG="Tier3-Media"
KIT="tier3-claude-kit"
BRAINS="tier3-client-brains"
BRAINS_DIR="$HOME/Tier3-Client-Brains"
BIN="$HOME/.local/bin"
export PATH="$BIN:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

fail() { echo "STATUS: FAILED: $1"; exit 30; }

# 1. Apple developer tools (git and python3 come with them).
if ! xcode-select -p >/dev/null 2>&1 || ! /usr/bin/git --version >/dev/null 2>&1; then
  xcode-select --install >/dev/null 2>&1
  echo "SAY: A small Apple window just opened. Click Install, then Agree. It takes about 5 minutes. Tell me when it says the software was installed."
  echo "STATUS: WAITING_DEVELOPER_TOOLS (run this script again after they say done)"
  exit 10
fi
echo "STATUS: developer tools OK"

# 2. GitHub tool (gh), from GitHub's own release, checksum checked. Kept in ~/.local/bin.
GH="$(command -v gh)"
if [ -z "$GH" ]; then
  mkdir -p "$BIN" "$HOME/.local/share/tier3" || fail "could not create $BIN"
  case "$(uname -m)" in arm64) ARCH=arm64 ;; *) ARCH=amd64 ;; esac
  TAG="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])')" \
    || fail "could not reach GitHub to download the GitHub tool"
  V="${TAG#v}"; Z="gh_${V}_macOS_${ARCH}.zip"; TMP="$(mktemp -d)"
  curl -fsSL -o "$TMP/$Z" "https://github.com/cli/cli/releases/download/$TAG/$Z" || fail "download of $Z failed"
  curl -fsSL -o "$TMP/sums" "https://github.com/cli/cli/releases/download/$TAG/gh_${V}_checksums.txt" || fail "checksum download failed"
  WANT="$(grep " $Z\$" "$TMP/sums" | cut -d' ' -f1)"
  GOT="$(shasum -a 256 "$TMP/$Z" | cut -d' ' -f1)"
  [ -n "$WANT" ] && [ "$WANT" = "$GOT" ] || fail "the GitHub tool download did not match GitHub's checksum, nothing installed"
  (cd "$TMP" && /usr/bin/unzip -q "$Z") || fail "unzip failed"
  rm -rf "$HOME/.local/share/tier3/gh" && mv "$TMP/gh_${V}_macOS_${ARCH}" "$HOME/.local/share/tier3/gh" || fail "install failed"
  ln -sf "$HOME/.local/share/tier3/gh/bin/gh" "$BIN/gh"
  rm -rf "$TMP"
  GH="$BIN/gh"
fi
echo "STATUS: GitHub tool OK ($("$GH" --version | head -1))"

# 3. GitHub sign-in through the browser. The one-time code goes to the clipboard and GitHub opens by itself.
if ! "$GH" auth status --hostname github.com >/dev/null 2>&1; then
  LOG="$(mktemp)"
  "$GH" auth login --hostname github.com --git-protocol https --web --skip-ssh-key --clipboard </dev/null >"$LOG" 2>&1 &
  PID=$!
  for _ in $(seq 1 20); do grep -q -E '[A-Z0-9]{4}-[A-Z0-9]{4}' "$LOG" && break; sleep 1; done
  CODE="$(grep -o -E '[A-Z0-9]{4}-[A-Z0-9]{4}' "$LOG" | head -1)"
  [ -n "$CODE" ] || { cat "$LOG"; kill "$PID" 2>/dev/null; fail "GitHub did not give a sign-in code"; }
  printf %s "$CODE" | pbcopy
  open "https://github.com/login/device"
  echo "SAY: A GitHub page just opened in your browser. Sign in to GitHub if it asks, press Cmd+V to paste the code (it is already copied: $CODE), click Continue, then click Authorize. Tell me when the page says you are all set."
  echo "STATUS: WAITING_GITHUB_SIGNIN (this script keeps waiting up to 15 minutes)"
  wait "$PID" || { cat "$LOG"; fail "GitHub sign-in did not finish. Run this script again for a new code."; }
  rm -f "$LOG"
fi
"$GH" auth setup-git --hostname github.com >/dev/null 2>&1 || fail "could not connect git to GitHub"
LOGIN="$("$GH" api user --jq .login 2>/dev/null)"
echo "STATUS: signed in to GitHub as $LOGIN"

# 4. Access to the Tier3 repos. A pending Tier3-Media invite is accepted here, so nobody clicks Join.
if ! "$GH" api "repos/$ORG/$KIT" --jq .name >/dev/null 2>&1; then
  if "$GH" api user/memberships/orgs --jq '.[] | select(.state=="pending") | .organization.login' 2>/dev/null | grep -qx "$ORG"; then
    "$GH" api -X PATCH "user/memberships/orgs/$ORG" -f state=active >/dev/null 2>&1 && echo "STATUS: accepted the $ORG invite"
    sleep 2
  fi
fi
if ! "$GH" api "repos/$ORG/$KIT" --jq .name >/dev/null 2>&1; then
  if "$GH" api user/memberships/orgs --jq '.[] | select(.state=="pending") | .organization.login' 2>/dev/null | grep -qx "$ORG"; then
    open "https://github.com/orgs/$ORG/invitation"
    echo "SAY: One more click: GitHub just opened your Tier3 Media invite. Click Join, then tell me."
  else
    echo "SAY: You're signed in to GitHub as $LOGIN, but Tier3 Media hasn't added you yet. I've drafted a message to Gustavo Ganem for you to send. I'll finish the moment they add you."
  fi
  echo "STATUS: NO_ACCESS login=$LOGIN"
  exit 20
fi
echo "STATUS: Tier3 GitHub access OK"

# 5. The Tier3 kit (Claude plugins). Uses the Claude app's own command line tool.
CLAUDE_BIN="${CLAUDE_CODE_EXECPATH:-$(command -v claude)}"
[ -x "$CLAUDE_BIN" ] || fail "could not find Claude's command line tool; run this from a Claude Code session"
if ! "$CLAUDE_BIN" plugin marketplace list 2>/dev/null | grep -q "tier3"; then
  "$CLAUDE_BIN" plugin marketplace add "$ORG/$KIT" >/dev/null 2>&1 || fail "could not add the Tier3 kit"
else
  "$CLAUDE_BIN" plugin marketplace update tier3 >/dev/null 2>&1
fi
"$CLAUDE_BIN" plugin install tier3-core@tier3 >/dev/null 2>&1 || fail "could not install tier3-core"
echo "STATUS: Tier3 kit installed (tier3-core)"

# 6. The client brains.
G="/usr/bin/git -C $BRAINS_DIR"
if [ -d "$BRAINS_DIR/.git" ]; then
  $G fetch --quiet origin >/dev/null 2>&1
  REMOTE_VER="$($G show origin/main:.history-version 2>/dev/null | tr -d '[:space:]')"
  LOCAL_VER="$($G config --get tier3.historyVersion 2>/dev/null)"
  if [ -n "$REMOTE_VER" ] && [ "$REMOTE_VER" != "$LOCAL_VER" ]; then
    # The brains history was cleaned for privacy: drop the old copy completely, keep nothing of it.
    $G checkout --quiet -B main origin/main >/dev/null 2>&1
    $G reset --quiet --hard origin/main >/dev/null 2>&1
    $G stash clear >/dev/null 2>&1
    for b in $($G for-each-ref --format='%(refname:short)' refs/heads); do [ "$b" = main ] || $G branch -D "$b" >/dev/null 2>&1; done
    $G reflog expire --expire=now --all >/dev/null 2>&1
    $G gc --quiet --prune=now >/dev/null 2>&1
    $G config tier3.historyVersion "$REMOTE_VER"
  else
    $G pull --ff-only --quiet >/dev/null 2>&1
  fi
else
  "$GH" repo clone "$ORG/$BRAINS" "$BRAINS_DIR" -- --quiet >/dev/null 2>&1 || fail "could not download the client brains"
  V="$($G show HEAD:.history-version 2>/dev/null | tr -d '[:space:]')"; [ -n "$V" ] && $G config tier3.historyVersion "$V"
fi
$G config core.hooksPath tools/githooks >/dev/null 2>&1
echo "STATUS: client brains at $BRAINS_DIR"

GUIDE="$(ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/marketplaces/tier3/plugins/tier3-core/skills/tier3-setup/SKILL.md 2>/dev/null | head -1)"
echo "STATUS: READY gh=$GH guide=${GUIDE:-use the tier3-setup skill}"
exit 0

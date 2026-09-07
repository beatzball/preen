#!/usr/bin/env bash
# preen installer — set up glow + delta + fzf and the roost theme on a new machine.
#
#   curl -fsSL https://raw.githubusercontent.com/beatzball/preen/main/install.sh | bash
#   ./install.sh              install everything
#   ./install.sh --dry-run    print what it would do, change nothing
#   ./install.sh --no-deps    skip package installs, do config only
#   ./install.sh --user       always install tools into ~/.local/bin (no sudo)
#   ./install.sh --dir DIR    where to clone preen (default ~/.local/share/preen)
#   ./install.sh --prefix DIR where to link preen (default ~/.local/bin)
#   ./install.sh --uninstall  undo the config and the link (keeps the packages)
set -uo pipefail

REPO_URL="${PREEN_REPO_URL:-https://github.com/beatzball/preen.git}"
CLONE_DIR="${PREEN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/preen}"

# Piped from curl there is no script file, so BASH_SOURCE is empty or "bash".
# In that case the checkout has to be fetched before anything can be installed.
_src="${BASH_SOURCE[0]:-}"
if [ -n "$_src" ] && [ -f "$_src" ]; then
  REPO="$(cd "$(dirname "$_src")" && pwd)"
else
  REPO=""
fi
PREFIX="${PREEN_PREFIX:-$HOME/.local/bin}"
GLOW_STYLE_DIR="$HOME/.config/glow"
GLOW_STYLE="$GLOW_STYLE_DIR/roost.json"
DRY=0; NO_DEPS=0; USER_ONLY=0; UNINSTALL=0
FAILED=0

# ---- output -----------------------------------------------------------------
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  C_OK=$'\033[38;2;80;250;123m'; C_WARN=$'\033[38;2;255;184;108m'
  C_ERR=$'\033[38;2;255;85;85m'; C_DIM=$'\033[38;2;138;132;176m'
  C_HEAD=$'\033[1;38;2;189;147;249m'; C_R=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_HEAD=""; C_R=""
fi
head_()  { printf '\n%s%s%s\n' "$C_HEAD" "$*" "$C_R"; }
ok()     { printf '  %s✓%s %s\n' "$C_OK" "$C_R" "$*"; }
skip()   { printf '  %s·%s %s%s%s\n' "$C_DIM" "$C_R" "$C_DIM" "$*" "$C_R"; }
warn()   { printf '  %s!%s %s\n' "$C_WARN" "$C_R" "$*"; }
err()    { printf '  %s✗%s %s\n' "$C_ERR" "$C_R" "$*" >&2; FAILED=1; }
die()    { printf '%sinstall.sh: %s%s\n' "$C_ERR" "$*" "$C_R" >&2; exit 1; }
run()    { if [ "$DRY" = 1 ]; then printf '  %swould run:%s %s\n' "$C_DIM" "$C_R" "$*"; else "$@"; fi; }

# ---- args -------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY=1 ;;
    --no-deps)   NO_DEPS=1 ;;
    --user)      USER_ONLY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --prefix)    shift; PREFIX="${1:?--prefix needs a directory}" ;;
    --dir)       shift; CLONE_DIR="${1:?--dir needs a directory}"; REPO="" ;;
    -h|--help)   sed -n '2,11p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# ---- bootstrap: make sure we have a checkout to install from -----------------
if [ "$UNINSTALL" = 0 ] && { [ -z "$REPO" ] || [ ! -x "$REPO/bin/preen" ]; }; then
  head_ "Checkout"
  if [ -x "$CLONE_DIR/bin/preen" ]; then
    ok "already cloned: $CLONE_DIR"
    run git -C "$CLONE_DIR" pull --ff-only --quiet || warn "could not update; keeping what is there"
  else
    command -v git >/dev/null 2>&1 || die "git is required to clone preen"
    run mkdir -p "$(dirname "$CLONE_DIR")"
    if run git clone --quiet "$REPO_URL" "$CLONE_DIR"; then
      ok "cloned $REPO_URL -> $CLONE_DIR"
    else
      die "could not clone $REPO_URL (private repo? try: gh repo clone beatzball/preen)"
    fi
  fi
  REPO="$CLONE_DIR"
fi

# ---- platform ---------------------------------------------------------------
OS="$(uname -s)"
case "$(uname -m)" in
  x86_64|amd64)  ARCH_GLOW="x86_64"; ARCH_DELTA="x86_64"; ARCH_FZF="amd64" ;;
  arm64|aarch64) ARCH_GLOW="arm64";  ARCH_DELTA="aarch64"; ARCH_FZF="arm64" ;;
  *) ARCH_GLOW=""; ARCH_DELTA=""; ARCH_FZF="" ;;
esac
case "$OS" in
  Darwin) OS_GLOW="Darwin"; OS_DELTA="apple-darwin";        OS_FZF="darwin" ;;
  Linux)  OS_GLOW="Linux";  OS_DELTA="unknown-linux-gnu";   OS_FZF="linux" ;;
  *) die "unsupported OS: $OS" ;;
esac

PKG=""
for m in brew apt-get dnf pacman zypper apk; do
  command -v "$m" >/dev/null 2>&1 && { PKG="$m"; break; }
done
[ "$USER_ONLY" = 1 ] && PKG=""

SUDO=""
if [ "$PKG" != "brew" ] && [ -n "$PKG" ] && [ "$(id -u)" != 0 ]; then
  command -v sudo >/dev/null 2>&1 && SUDO="sudo" || PKG=""
fi

# ---- uninstall --------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
  head_ "Removing preen config"
  for k in features syntax-theme file-style file-decoration-style hunk-header-style \
           hunk-header-decoration-style line-numbers line-numbers-left-style \
           line-numbers-right-style line-numbers-zero-style plus-style minus-style \
           plus-emph-style minus-emph-style zero-style true-color \
           sbs.side-by-side inline.side-by-side; do
    git config --global --unset "delta.$k" 2>/dev/null && ok "unset delta.$k" || skip "delta.$k not set"
  done
  [ -f "$GLOW_STYLE" ] && { run rm -f "$GLOW_STYLE"; ok "removed $GLOW_STYLE"; } || skip "no glow theme"
  [ -L "$PREFIX/preen" ] && { run rm -f "$PREFIX/preen"; ok "removed $PREFIX/preen"; } || skip "no preen link"
  skip "kept core.pager, interactive.diffFilter, delta.navigate, delta.dark (plain delta setup)"
  printf '\n%sPackages were left alone. Remove them yourself if you want.%s\n' "$C_DIM" "$C_R"
  exit 0
fi

# ---- dependency install -----------------------------------------------------
pkg_name() { # tool -> package name for this manager
  case "$1:$PKG" in
    delta:brew)   echo git-delta ;;
    delta:apt-get|delta:dnf|delta:zypper) echo git-delta ;;
    delta:pacman) echo git-delta ;;
    delta:apk)    echo delta ;;
    *) echo "$1" ;;
  esac
}

pkg_install() {
  local p="$1"
  case "$PKG" in
    brew)    run brew install "$p" ;;
    apt-get) run $SUDO apt-get install -y "$p" ;;
    dnf)     run $SUDO dnf install -y "$p" ;;
    pacman)  run $SUDO pacman -S --noconfirm "$p" ;;
    zypper)  run $SUDO zypper install -y "$p" ;;
    apk)     run $SUDO apk add "$p" ;;
    *) return 1 ;;
  esac
}

gh_asset_url() { # repo, grep pattern -> download url
  local repo="$1" pat="$2"
  curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
    | grep -o '"browser_download_url": *"[^"]*"' \
    | sed 's/.*"\(https[^"]*\)"/\1/' \
    | grep -E "$pat" | head -1
}

gh_install() { # tool, repo, asset pattern, path-inside-archive pattern
  local tool="$1" repo="$2" pat="$3" inner="$4" url tmp
  [ -n "$ARCH_GLOW" ] || { err "unknown CPU arch, cannot fetch $tool"; return 1; }
  command -v curl >/dev/null 2>&1 || { err "curl is needed to fetch $tool"; return 1; }
  url="$(gh_asset_url "$repo" "$pat")"
  [ -n "$url" ] || { err "no $tool release asset matched /$pat/"; return 1; }
  if [ "$DRY" = 1 ]; then printf '  %swould download:%s %s\n' "$C_DIM" "$C_R" "$url"; return 0; fi
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  curl -fsSL "$url" -o "$tmp/a.tar.gz" || { err "download failed: $url"; return 1; }
  tar -xzf "$tmp/a.tar.gz" -C "$tmp" || { err "could not unpack $tool"; return 1; }
  local found; found="$(find "$tmp" -type f -name "$inner" -perm -u+x | head -1)"
  [ -n "$found" ] || { err "no $inner binary inside the $tool archive"; return 1; }
  mkdir -p "$PREFIX" && install -m 0755 "$found" "$PREFIX/$tool" || { err "could not install $tool"; return 1; }
  ok "$tool -> $PREFIX/$tool (from GitHub release)"
}

have() { command -v "$1" >/dev/null 2>&1; }

ensure_tool() { # tool, repo, asset pattern, inner name
  local tool="$1"
  if have "$tool"; then skip "$tool already installed ($(command -v "$tool"))"; return 0; fi
  if [ "$NO_DEPS" = 1 ]; then warn "$tool is missing (--no-deps, not installing)"; return 0; fi
  if [ -n "$PKG" ]; then
    local p; p="$(pkg_name "$tool")"
    printf '  %sinstalling %s via %s...%s\n' "$C_DIM" "$p" "$PKG" "$C_R"
    if pkg_install "$p"; then
      { [ "$DRY" = 1 ] || have "$tool"; } && { ok "$tool installed"; return 0; }
    fi
    warn "$PKG could not provide $tool, falling back to a GitHub release"
  fi
  gh_install "$tool" "$2" "$3" "$4"
}

head_ "Dependencies"
if [ "$OS" = Darwin ] && [ "$PKG" != brew ] && [ "$NO_DEPS" = 0 ] && [ "$USER_ONLY" = 0 ]; then
  warn "Homebrew not found; using GitHub releases instead (install brew from https://brew.sh for updates)"
fi
ensure_tool glow  charmbracelet/glow  "glow_.*${OS_GLOW}_${ARCH_GLOW}\.tar\.gz$"        "glow"
# glow 2 throws away colour when its output is a pipe, which is exactly what fzf
# hands a preview. glow 3 keeps it, so anything older has to be upgraded.
glow_major() { glow --version 2>/dev/null | sed -n 's/.*version \([0-9][0-9]*\).*/\1/p'; }
if have glow && ! { [ "$(glow_major)" -ge 3 ] 2>/dev/null; }; then
  if [ "$NO_DEPS" = 1 ]; then
    warn "glow $(glow_major) is too old for coloured previews; need 3 or newer"
  else
    warn "glow $(glow_major) drops colour in pipes; upgrading to 3 or newer"
    case "$PKG" in
      brew)    run brew upgrade glow ;;
      apt-get) run $SUDO apt-get install -y --only-upgrade glow ;;
      dnf)     run $SUDO dnf upgrade -y glow ;;
      pacman)  run $SUDO pacman -S --noconfirm glow ;;
      zypper)  run $SUDO zypper update -y glow ;;
      apk)     run $SUDO apk upgrade glow ;;
    esac
    { [ "$DRY" = 1 ] || { [ "$(glow_major)" -ge 3 ] 2>/dev/null; }; } \
      || gh_install glow charmbracelet/glow "glow_.*${OS_GLOW}_${ARCH_GLOW}\.tar\.gz$" "glow"
    { [ "$DRY" = 1 ] || { [ "$(glow_major)" -ge 3 ] 2>/dev/null; }; } \
      && ok "glow $(glow_major) is new enough" \
      || err "still on glow $(glow_major); previews will have no colour"
  fi
fi
ensure_tool delta dandavison/delta    "delta-.*${ARCH_DELTA}-${OS_DELTA}\.tar\.gz$"     "delta"
ensure_tool fzf   junegunn/fzf        "fzf-.*${OS_FZF}_${ARCH_FZF}\.tar\.gz$"           "fzf"
have git || err "git is not installed — install it and run this again"

# ---- glow theme -------------------------------------------------------------
head_ "glow theme"
if [ -f "$REPO/themes/glow-roost.json" ]; then
  run mkdir -p "$GLOW_STYLE_DIR"
  if [ -f "$GLOW_STYLE" ] && cmp -s "$REPO/themes/glow-roost.json" "$GLOW_STYLE"; then
    skip "$GLOW_STYLE already current"
  else
    run cp "$REPO/themes/glow-roost.json" "$GLOW_STYLE"
    ok "$GLOW_STYLE"
  fi
else
  err "missing $REPO/themes/glow-roost.json"
fi

# ---- delta theme ------------------------------------------------------------
head_ "delta theme (git config --global)"
gset() { # key, value — only writes when the value differs
  local cur; cur="$(git config --global --get "$1" 2>/dev/null)"
  if [ "$cur" = "$2" ]; then skip "$1"; return 0; fi
  run git config --global "$1" "$2" && ok "$1 = $2"
}
if have git; then
  if [ "$DRY" = 0 ] && [ -f "$HOME/.gitconfig" ] && [ ! -f "$HOME/.gitconfig.preen.bak" ]; then
    cp "$HOME/.gitconfig" "$HOME/.gitconfig.preen.bak" && ok "backed up ~/.gitconfig"
  fi
  # side-by-side must NOT live in the main [delta] section: options there beat
  # feature options, and preen's ctrl-s toggle would stop working.
  if [ -n "$(git config --global --get delta.side-by-side 2>/dev/null)" ]; then
    run git config --global --unset delta.side-by-side && ok "moved delta.side-by-side into a feature"
  fi
  gset core.pager                            "delta"
  gset interactive.diffFilter                "delta --color-only"
  gset delta.features                        "sbs"
  gset delta.sbs.side-by-side                "true"
  gset delta.inline.side-by-side             "false"
  gset delta.navigate                        "true"
  gset delta.dark                            "true"
  gset delta.true-color                      "always"
  gset delta.syntax-theme                    "Dracula"
  gset delta.file-style                      "#bd93f9 bold"
  gset delta.file-decoration-style           "#7c6ff0 ul"
  gset delta.hunk-header-style               "#8a84b0"
  gset delta.hunk-header-decoration-style    "#7c6ff0 box"
  gset delta.line-numbers                    "true"
  gset delta.line-numbers-left-style         "#7c6ff0"
  gset delta.line-numbers-right-style        "#7c6ff0"
  gset delta.line-numbers-zero-style         "#8a84b0"
  gset delta.plus-style                      "syntax #1e3326"
  gset delta.minus-style                     "syntax #3a1e28"
  gset delta.plus-emph-style                 "syntax #2d5a3d"
  gset delta.minus-emph-style                "syntax #5c2d3a"
  gset delta.zero-style                      "syntax"
fi

# ---- link preen ---------------------------------------------------------------
head_ "preen"
if [ -x "$REPO/bin/preen" ]; then
  run mkdir -p "$PREFIX"
  if [ "$(readlink "$PREFIX/preen" 2>/dev/null)" = "$REPO/bin/preen" ]; then
    skip "$PREFIX/preen already linked"
  else
    run ln -sf "$REPO/bin/preen" "$PREFIX/preen"
    ok "$PREFIX/preen -> $REPO/bin/preen"
  fi
else
  err "missing $REPO/bin/preen (or it is not executable)"
fi

# ---- PATH advice ------------------------------------------------------------
head_ "PATH"
case ":$PATH:" in
  *":$PREFIX:"*) ok "$PREFIX is on your PATH" ;;
  *)
    warn "$PREFIX is not on your PATH"
    rc="$HOME/.bashrc"; [ -n "${ZSH_VERSION:-}" ] && rc="$HOME/.zshrc"
    [ "$(basename "${SHELL:-}")" = zsh ] && rc="$HOME/.zshrc"
    printf '    %sadd this to %s:%s\n' "$C_DIM" "$rc" "$C_R"
    printf '      export PATH="%s:$PATH"\n' "$PREFIX"
    ;;
esac

# ---- done -------------------------------------------------------------------
if [ "$FAILED" = 1 ]; then
  printf '\n%sFinished with errors — see the ✗ lines above.%s\n' "$C_ERR" "$C_R"; exit 1
fi
if [ "$DRY" = 1 ]; then
  printf '\n%sDry run. Nothing changed.%s\n' "$C_DIM" "$C_R"
else
  printf '\n%sDone.%s Try: %spreen --help%s\n' "$C_OK" "$C_R" "$C_HEAD" "$C_R"
fi

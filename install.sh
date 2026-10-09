#!/bin/sh
# Adds this Linux or macOS machine to the DevNet Board.
#
#   curl -fsSL https://raw.githubusercontent.com/Orca-DevNet/devnet-agent-releases/main/install.sh | sh -s -- <join code>
#
# The join code comes from an admin (Board, Admin, Machines). It works once and expires.
#
# What this does, in order, and nothing else:
#   1. checks git is installed, and offers to install it with the system's package manager if not (the agent needs
#      git; it needs nothing else);
#   2. downloads the agent for this OS and CPU from this repository's latest release and SHA256SUMS, and REFUSES to
#      go on if the checksum does not match;
#   3. runs `devnet-agent join`, which gets this machine its own key and writes its config;
#   4. installs a systemd user service (Linux) or a launch agent (macOS) that starts the agent at login (the agent
#      only reports in; jobs stay off until you turn them on).
# It puts everything in one folder of your own (default ~/devnet-agent). It does not need root (only to install git,
# if you say yes), does not touch your own Tailscale, and does not change your PATH.
#
# Options: --dir <folder>  --version <tag>  --yes (do not ask before installing git)  --force (replace an existing join)
#          --no-service (join but do not install the service)
set -eu

code="${DEVNET_JOIN_CODE:-}"
dir="${DEVNET_DIR:-$HOME/devnet-agent}"
version="latest"
yes=0 force=0 service=1
while [ $# -gt 0 ]; do
	case "$1" in
		--dir) dir="$2"; shift 2 ;;
		--version) version="$2"; shift 2 ;;
		--yes|-y) yes=1; shift ;;
		--force) force=1; shift ;;
		--no-service) service=0; shift ;;
		-h|--help) sed -n '2,20p' "$0" 2>/dev/null || true; exit 0 ;;
		-*) echo "ERROR: unknown option $1" >&2; exit 2 ;;
		*) if [ -z "$code" ]; then code="$1"; else echo "ERROR: one join code only (is it split across two words?)" >&2; exit 2; fi; shift ;;
	esac
done

say() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "$code" ] || die "needs the join code an admin made on the Board: sh -s -- <join code>"
case "$code" in dnj1_*) ;; *) die "that is not a join code: it should start dnj1_ (copy the whole line from the Board)" ;; esac

# ---- the machine ------------------------------------------------------------------------------------------
# DEVNET_OS and DEVNET_ARCH are for testing this script; DEVNET_RELEASES_BASE points it at a local server.
os="${DEVNET_OS:-$(uname -s | tr 'A-Z' 'a-z')}"
case "$os" in linux|darwin) ;; *) die "this installer is for Linux and macOS (this is $os); on Windows use install.ps1" ;; esac
arch="${DEVNET_ARCH:-$(uname -m)}"
case "$arch" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) die "no agent is built for the CPU $arch" ;; esac
asset="devnet-agent-$os-$arch"
repo="Orca-DevNet/devnet-agent-releases"
if [ -n "${DEVNET_RELEASES_BASE:-}" ]; then base="$DEVNET_RELEASES_BASE"
elif [ "$version" = "latest" ]; then base="https://github.com/$repo/releases/latest/download"
else base="https://github.com/$repo/releases/download/$version"; fi

if command -v curl >/dev/null 2>&1; then fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then fetch() { wget -q "$1" -O "$2"; }
else die "needs curl or wget"; fi
if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
else die "needs sha256sum or shasum to check the download"; fi

# ---- 1. git -----------------------------------------------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
	say "git is not installed (the agent needs it to do jobs)."
	sudo=""
	[ "$(id -u)" -eq 0 ] || { command -v sudo >/dev/null 2>&1 && sudo="sudo"; }
	if command -v apt-get >/dev/null 2>&1; then cmd="$sudo apt-get install -y git"
	elif command -v dnf >/dev/null 2>&1; then cmd="$sudo dnf install -y git"
	elif command -v yum >/dev/null 2>&1; then cmd="$sudo yum install -y git"
	elif command -v pacman >/dev/null 2>&1; then cmd="$sudo pacman -S --noconfirm git"
	elif command -v zypper >/dev/null 2>&1; then cmd="$sudo zypper --non-interactive install git"
	elif command -v apk >/dev/null 2>&1; then cmd="$sudo apk add git"
	elif command -v brew >/dev/null 2>&1; then cmd="brew install git"
	elif [ "$os" = darwin ]; then die "git is missing: run  xcode-select --install  (or install Homebrew and run  brew install git), then run this again"
	else die "git is missing and no package manager was found: install git, then run this again"; fi
	if [ "$yes" -ne 1 ]; then
		# curl | sh has no stdin to ask on: ask the terminal.
		if [ -r /dev/tty ]; then printf 'Install git with:  %s  ? [Y/n] ' "$cmd" >/dev/tty; read -r a </dev/tty || a=n
		else die "git is missing: install it (for example  $cmd ), or run this with --yes to let it, then run this again"; fi
		case "$a" in n|N|no|No) die "git is needed: install it, then run this again" ;; esac
	fi
	say "Installing git: $cmd"
	sh -c "$cmd" || die "git could not be installed: install it yourself, then run this again"
	command -v git >/dev/null 2>&1 || die "git was installed but is not on the PATH: open a new terminal and run this again"
fi
say "git: $(git --version)"

# ---- 2. the agent, checked ---------------------------------------------------------------------------------
mkdir -p "$dir"
tmp="$(mktemp -d 2>/dev/null || mktemp -d -t devnet)"
trap 'rm -rf "$tmp"' EXIT INT TERM
say "Downloading the agent ($version) from $base"
fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" || die "could not download SHA256SUMS from $base"
fetch "$base/$asset" "$tmp/$asset" || die "could not download $asset from $base"
want="$(awk -v a="$asset" '{n=$2; sub(/^\*/,"",n); if (n==a) {print tolower($1); exit}}' "$tmp/SHA256SUMS")"
[ -n "$want" ] || die "SHA256SUMS has no entry for $asset"
got="$(sha "$tmp/$asset" | tr 'A-Z' 'a-z')"
if [ "$got" != "$want" ]; then die "the downloaded agent's SHA256 ($got) does not match SHA256SUMS ($want). It was NOT installed. Do not run it; tell an admin."; fi
say "Checksum matches."
chmod +x "$tmp/$asset"

exe="$dir/devnet-agent"
cfg="$dir/config.json"
# A running agent (a rejoin) has to stop before its file is replaced.
if [ -x "$exe" ] && [ -f "$cfg" ]; then "$exe" --config "$cfg" stop >/dev/null 2>&1 || true; fi
mv -f "$tmp/$asset" "$exe"

# ---- 3. join ---------------------------------------------------------------------------------------------
# The code goes in the environment, not on a command line, so it is not in any process list.
say "Joining the Board..."
if [ "$force" -eq 1 ]; then DEVNET_JOIN_CODE="$code" "$exe" --config "$cfg" join --force || die "the join did not work (see above)"
else DEVNET_JOIN_CODE="$code" "$exe" --config "$cfg" join || die "the join did not work (see above)"; fi

# ---- 4. start at login -------------------------------------------------------------------------------------
if [ "$service" -eq 1 ]; then
	say "Installing the service..."
	"$exe" --config "$cfg" service install || die "the agent joined but the service could not be installed (see above). Run:  $exe --config $cfg service install"
	sleep 8
	"$exe" --config "$cfg" service status || true
fi

echo
echo "Done. This machine is on the Board (Machines). It only reports in until you turn jobs on."
echo "  Agent:  $exe"
echo "  Config: $cfg   (private to you; it holds this machine's key)"
echo "  Log:    $dir/agent.log"
echo "  Stop:   $exe --config $cfg stop"
echo "  Remove: $exe --config $cfg service uninstall"

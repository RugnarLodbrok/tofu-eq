#!/usr/bin/env bash
# Tofu EQ installer
#
#   curl -fsSL https://raw.githubusercontent.com/AoTofu/tofu-eq/main/install.sh | bash
#
# Options (append after `bash -s --` when piping):
#   --uninstall   remove Tofu EQ (keeps your presets and settings)
#   --purge       remove Tofu EQ and ~/.config/tofu-eq
#   --venv        install Python deps into a private venv instead of using distro packages
#   --no-deps     don't install any Python dependencies
set -euo pipefail

REPO="AoTofu/tofu-eq"
REF="${TOFU_EQ_REF:-main}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
PREFIX="$DATA_HOME/tofu-eq"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$DATA_HOME/applications"
ICON_DIR="$DATA_HOME/icons/hicolor/scalable/apps"
UNIT="tofu-eq-filter.service"

init_colors() {
    if [ -t 1 ]; then
        B=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GRN=$'\e[32m' YEL=$'\e[33m' BLU=$'\e[34m' RST=$'\e[0m'
    else
        B="" DIM="" RED="" GRN="" YEL="" BLU="" RST=""
    fi
}

step() { printf '%s==>%s %s%s%s\n' "$BLU" "$RST" "$B" "$*" "$RST"; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$*"; }
die()  { printf '%serror:%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

refresh_menus() {  # best effort; not every desktop ships these tools
    if have update-desktop-database; then update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || :; fi
    if have gtk-update-icon-cache; then gtk-update-icon-cache -q -t "$DATA_HOME/icons/hicolor" >/dev/null 2>&1 || :; fi
    if have kbuildsycoca6; then kbuildsycoca6 >/dev/null 2>&1 || :; fi
}

uninstall() {
    local mode="$1"

    step "Removing Tofu EQ"
    if have systemctl; then
        systemctl --user disable --now "$UNIT" >/dev/null 2>&1 || true
        rm -f "$CONFIG_HOME/systemd/user/$UNIT"
        systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
    rm -rf "$PREFIX"
    rm -f "$BIN_DIR/tofu-eq" "$APPS_DIR/tofu-eq.desktop" "$ICON_DIR/tofu-eq.svg"
    refresh_menus
    ok "app, launcher, menu entry and background service removed"
    if [ "$mode" = purge ]; then
        rm -rf "$CONFIG_HOME/tofu-eq"
        ok "settings and presets removed ($CONFIG_HOME/tofu-eq)"
    else
        printf '  %sYour presets are kept in %s (use --purge to delete them).%s\n' "$DIM" "$CONFIG_HOME/tofu-eq" "$RST"
    fi
}

version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

check_system() {
    local cmd pw_version wp_version

    step "Checking your system"
    [ "$(uname -s)" = Linux ] || die "Tofu EQ only runs on Linux."
    [ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not root (it installs into your home directory)."
    for cmd in python3 pw-cli pw-dump pw-record pw-link systemctl; do
        have "$cmd" || die "'$cmd' not found. Tofu EQ needs PipeWire, systemd and Python 3."
    done
    pw-cli info 0 >/dev/null 2>&1 || die "PipeWire doesn't seem to be running for this user."

    pw_version="$(pipewire --version 2>/dev/null | sed -n 's/.*libpipewire \([0-9.]*\).*/\1/p' | tail -n1)"
    if [ -n "$pw_version" ] && ! version_ge "$pw_version" 1.0.0; then
        die "PipeWire $pw_version is too old (need 1.0 or newer)."
    fi
    ok "PipeWire ${pw_version:-(unknown version)}"

    wp_version="$(wireplumber --version 2>/dev/null | sed -n 's/.*libwireplumber \([0-9.]*\).*/\1/p' | head -n1)"
    if [ -n "$wp_version" ] && version_ge "$wp_version" 0.5.0; then
        ok "WirePlumber $wp_version"
    else
        warn "WirePlumber ${wp_version:-not found} is older than 0.5: the EQ won't insert itself automatically."
        warn "Pick \"Tofu EQ\" as your output device in your sound settings instead."
    fi
    python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' || die "Python 3.9 or newer is required."
    ok "Python $(python3 -c 'import platform; print(platform.python_version())')"
}

deps_ok() { "$1" -c 'import PySide6.QtWidgets, numpy' >/dev/null 2>&1; }

distro_install() {
    local id like
    # shellcheck source=/dev/null
    id="$(. /etc/os-release 2>/dev/null; echo "${ID:-}")"
    # shellcheck source=/dev/null
    like="$(. /etc/os-release 2>/dev/null; echo "${ID_LIKE:-}")"
    local -a cmd=()
    case " $id $like " in
        *" fedora "*|*" rhel "*)
            cmd=(sudo dnf install -y python3-pyside6 python3-numpy) ;;
        *" arch "*)
            cmd=(sudo pacman -S --needed --noconfirm pyside6 python-numpy) ;;
        *" debian "*|*" ubuntu "*)
            if apt-cache show python3-pyside6.qtwidgets >/dev/null 2>&1; then
                cmd=(sudo apt-get install -y python3-pyside6.qtwidgets python3-numpy)
            fi ;;
        *" suse "*|*" opensuse "*)
            cmd=(sudo zypper --non-interactive install python3-PySide6 python3-numpy) ;;
        *) ;;
    esac
    (( ${#cmd[@]} > 0 )) || return 1
    printf '  %sRunning: %s%s\n' "$DIM" "${cmd[*]}" "$RST"
    # keep the package manager from reading the rest of this script when it is piped into bash
    if [ -r /dev/tty ]; then
        "${cmd[@]}" </dev/tty
    else
        "${cmd[@]}" </dev/null
    fi
}

venv_install() {
    printf '  %sCreating a private Python environment in %s/venv%s\n' "$DIM" "$PREFIX" "$RST"
    mkdir -p "$PREFIX"
    python3 -m venv "$PREFIX/venv" \
        || die "python3 -m venv failed (on Debian/Ubuntu: sudo apt install python3-venv)."
    "$PREFIX/venv/bin/python" -m pip install --quiet --upgrade pip
    "$PREFIX/venv/bin/python" -m pip install --quiet "PySide6-Essentials>=6.5" numpy
    PYTHON="$PREFIX/venv/bin/python"
}

install_dependencies() {
    local deps="$1"

    PYTHON="$(command -v python3)"
    step "Python dependencies (PySide6, numpy)"
    if [ "$deps" = none ]; then
        warn "skipped (--no-deps)"
    elif [ "$deps" = venv ]; then
        venv_install
    elif deps_ok "$PYTHON"; then
        ok "already installed"
    elif [ -x "$PREFIX/venv/bin/python" ] && deps_ok "$PREFIX/venv/bin/python"; then
        PYTHON="$PREFIX/venv/bin/python"
        ok "using the existing private environment"
    else
        if ! { distro_install && deps_ok "$PYTHON"; }; then
            warn "no usable distro packages, falling back to a private environment"
            venv_install
        fi
    fi
    [ "$deps" = none ] || deps_ok "$PYTHON" || die "PySide6/numpy still can't be imported."
    [ "$deps" = none ] || ok "PySide6 and numpy are ready"
}

find_source() {
    local script_dir url
    local local_source=""

    if script_dir="$(dirname "${BASH_SOURCE[0]:-$0}")" && [ -d "$script_dir" ]; then
        local_source="$(cd "$script_dir" && pwd)"
    fi
    if [ -n "$local_source" ] && [ -f "$local_source/tofu_eq/__main__.py" ]; then
        SOURCE_DIR="$local_source"
        return
    fi

    DOWNLOAD_DIR="$(mktemp -d)"
    trap 'rm -rf "$DOWNLOAD_DIR"' EXIT
    url="https://github.com/$REPO/archive/$REF.tar.gz"
    if have curl; then
        curl -fsSL "$url" -o "$DOWNLOAD_DIR/src.tar.gz"
    elif have wget; then
        wget -qO "$DOWNLOAD_DIR/src.tar.gz" "$url"
    else
        die "curl or wget is required to download Tofu EQ."
    fi
    tar -xzf "$DOWNLOAD_DIR/src.tar.gz" -C "$DOWNLOAD_DIR"
    SOURCE_DIR="$(find "$DOWNLOAD_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
}

install_app() {
    local source_dir="$1"
    local python="$2"
    local version

    mkdir -p "$PREFIX" "$BIN_DIR" "$APPS_DIR" "$ICON_DIR"
    rm -rf "$PREFIX/app"
    mkdir -p "$PREFIX/app"
    cp -r "$source_dir/tofu_eq" "$PREFIX/app/"
    find "$PREFIX/app" -name __pycache__ -prune -exec rm -rf {} +
    cp "$source_dir/install.sh" "$PREFIX/install.sh" && chmod +x "$PREFIX/install.sh"
    version="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$source_dir/tofu_eq/__init__.py")"
    ok "Tofu EQ $version → $PREFIX/app"

    cat > "$BIN_DIR/tofu-eq" <<EOF
#!/bin/sh
PYTHONPATH="$PREFIX/app\${PYTHONPATH:+:\$PYTHONPATH}" exec "$python" -m tofu_eq "\$@"
EOF
    chmod +x "$BIN_DIR/tofu-eq"
    sed "s|^Exec=.*|Exec=$BIN_DIR/tofu-eq|" "$source_dir/data/tofu-eq.desktop" > "$APPS_DIR/tofu-eq.desktop"
    cp "$source_dir/data/tofu-eq.svg" "$ICON_DIR/tofu-eq.svg"
    refresh_menus
    ok "launcher: $BIN_DIR/tofu-eq"
    ok "app menu entry: Tofu EQ"
}

print_install_summary() {
    echo
    printf '%s%sTofu EQ is installed!%s\n' "$GRN" "$B" "$RST"
    echo "  • Open \"Tofu EQ\" from your app menu (or run: tofu-eq)."
    echo "  • The first launch sets up the background EQ service; it then starts at every login."
    echo "  • Uninstall: $PREFIX/install.sh --uninstall"
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) warn "$BIN_DIR is not in your PATH; use the app menu or run $BIN_DIR/tofu-eq" ;;
    esac
}

main() {
    local mode=install deps=auto arg

    init_colors
    for arg in "$@"; do
        case "$arg" in
            --uninstall) mode=uninstall ;;
            --purge) mode=purge ;;
            --venv) deps=venv ;;
            --no-deps) deps=none ;;
            -h|--help)
                sed -n '2,12p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
                exit 0 ;;
            *) die "unknown option: $arg" ;;
        esac
    done

    if [ "$mode" != install ]; then
        uninstall "$mode"
        exit 0
    fi

    check_system
    install_dependencies "$deps"

    step "Installing Tofu EQ"
    find_source
    install_app "$SOURCE_DIR" "$PYTHON"
    print_install_summary
}

# Invoke only after the full script has been read (including when piped into Bash).
main "$@"

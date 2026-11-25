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
#   --standalone DIR  install a built standalone distribution
set -euo pipefail

REPO="AoTofu/tofu-eq"
REF="${TOFU_EQ_REF:-main}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
PREFIX="$DATA_HOME/tofu-eq"
APP_DIR="$PREFIX/app"
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
    for cmd in pw-cli pw-dump pw-record pw-link systemctl; do
        have "$cmd" || die "'$cmd' not found. Tofu EQ needs PipeWire and systemd."
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
}

check_python() {
    have python3 || die "'python3' not found. Installing from source requires Python 3.9 or newer."
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

check_standalone() {
    local dist_dir="$1"
    [ -f "$dist_dir/tofu-eq" ] && [ -x "$dist_dir/tofu-eq" ] &&
        [ -f "$dist_dir/data/tofu-eq.desktop" ] && [ -f "$dist_dir/data/tofu-eq.svg" ] ||
        die "Standalone build missing or incomplete at '$dist_dir'. Run make build or provide a complete build directory."
}

write_launcher() {
    local python="$1"
    printf '#!/bin/bash\n'
    if [ -n "$python" ]; then
        # Expand PYTHONPATH when the generated launcher runs.
        # shellcheck disable=SC2016
        printf 'export PYTHONPATH=%q${PYTHONPATH:+:$PYTHONPATH}\n' "$APP_DIR"
        printf 'exec %q -m tofu_eq "$@"\n' "$python"
    else
        printf 'exec %q "$@"\n' "$APP_DIR/tofu-eq"
    fi
}

write_desktop_entry() {
    local assets_dir="$1"
    local exec_path="$BIN_DIR/tofu-eq"
    if [[ "$exec_path" == *[[:space:]]* ]]; then
        exec_path="\"$exec_path\""
    fi
    exec_path="${exec_path//\\/\\\\}"
    exec_path="${exec_path//&/\\&}"
    exec_path="${exec_path//|/\\|}"
    sed "s|^Exec=.*|Exec=$exec_path|" "$assets_dir/tofu-eq.desktop"
}

activate_app() {
    local staging_dir="$1"

    if [ -e "$APP_DIR" ] || [ -L "$APP_DIR" ]; then
        mv -T -- "$APP_DIR" "$staging_dir/previous"
    fi
    if mv -T -- "$staging_dir/app" "$APP_DIR" &&
        mv -fT -- "$staging_dir/tofu-eq" "$BIN_DIR/tofu-eq"; then
        return
    fi
    if [ ! -d "$staging_dir/app" ]; then
        mv -T -- "$APP_DIR" "$staging_dir/app" || trap - EXIT
    fi
    if [ -e "$staging_dir/previous" ] || [ -L "$staging_dir/previous" ]; then
        mv -T -- "$staging_dir/previous" "$APP_DIR" || trap - EXIT
    fi
    die "Could not activate the installation at '$APP_DIR'."
}

install_app() (
    local source_dir="$1" installer="$2" python="${3:-}"
    local staging_dir version

    mkdir -p "$PREFIX" "$BIN_DIR" "$APPS_DIR" "$ICON_DIR"
    staging_dir="$(mktemp -d "$PREFIX/.install.XXXXXX")"
    trap 'rm -rf -- "$staging_dir"' EXIT
    mkdir "$staging_dir/app"
    if [ -n "$python" ]; then
        cp -r "$source_dir/tofu_eq" "$staging_dir/app/"
        find "$staging_dir/app" -name __pycache__ -prune -exec rm -rf {} +
        version="Tofu EQ $(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$source_dir/tofu_eq/__init__.py")"
    else
        cp -a -- "$source_dir/." "$staging_dir/app/"
        version="$("$staging_dir/app/tofu-eq" --version)" ||
            die "The standalone binary could not run on this system."
    fi
    cp -- "$installer" "$staging_dir/install.sh"
    cp -- "$source_dir/data/tofu-eq.svg" "$staging_dir/tofu-eq.svg"
    write_launcher "$python" > "$staging_dir/tofu-eq"
    write_desktop_entry "$source_dir/data" > "$staging_dir/tofu-eq.desktop"
    chmod +x "$staging_dir/install.sh" "$staging_dir/tofu-eq"

    mv -fT -- "$staging_dir/install.sh" "$PREFIX/install.sh"
    mv -fT -- "$staging_dir/tofu-eq.desktop" "$APPS_DIR/tofu-eq.desktop"
    mv -fT -- "$staging_dir/tofu-eq.svg" "$ICON_DIR/tofu-eq.svg"
    activate_app "$staging_dir"
    refresh_menus
    ok "$version → $APP_DIR"
    ok "launcher: $BIN_DIR/tofu-eq"
    ok "app menu entry: Tofu EQ"
)

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
    local mode=install deps=auto standalone_dir=""
    local installer="${BASH_SOURCE[0]:-}"

    init_colors
    while (( $# > 0 )); do
        case "$1" in
            --uninstall) mode=uninstall ;;
            --purge) mode=purge ;;
            --venv) deps=venv ;;
            --no-deps) deps=none ;;
            --standalone)
                [[ -n "${2:-}" && "$2" != --* ]] || die "--standalone requires a build directory."
                standalone_dir="$2"
                shift ;;
            -h|--help)
                sed -n '2,11p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
                exit 0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done

    if [ -n "$standalone_dir" ]; then
        [[ "$mode" == install && "$deps" == auto ]] || die "--standalone cannot be combined with other install or removal modes."
        check_standalone "$standalone_dir"
        [ -f "$installer" ] || die "Run install.sh from a file when using --standalone."
    fi
    if [ "$mode" != install ]; then
        uninstall "$mode"
        exit 0
    fi

    check_system
    if [ -n "$standalone_dir" ]; then
        step "Installing standalone Tofu EQ"
        install_app "$standalone_dir" "$installer"
    else
        check_python
        install_dependencies "$deps"
        step "Installing Tofu EQ"
        find_source
        install_app "$SOURCE_DIR" "$SOURCE_DIR/install.sh" "$PYTHON"
    fi
    print_install_summary
}

# Invoke only after the full script has been read (including when piped into Bash).
main "$@"

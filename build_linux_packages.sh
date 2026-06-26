#!/bin/bash
set -e

# Linux Packaging Wrapper Script for Euro-Office Desktop Editors
# Supported types: deb, rpm, flatpak, aur

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PACKAGE_DIR="$ROOT_DIR/desktop-apps/package"
RELEASES_DIR="$ROOT_DIR/releases"

mkdir -p "$RELEASES_DIR"

detect_pm() {
    if command -v apt-get >/dev/null; then echo "apt";
    elif command -v dnf >/dev/null; then echo "dnf";
    elif command -v pacman >/dev/null; then echo "pacman";
    elif command -v zypper >/dev/null; then echo "zypper";
    else echo "unknown"; fi
}

install_dependency() {
    local cmd=$1
    local pkg_apt=$2
    local pkg_dnf=$3
    local pkg_pacman=$4
    local pkg_zypper=$5

    if ! command -v "$cmd" >/dev/null; then
        echo "Missing dependency: $cmd. Attempting to install..."
        local pm=$(detect_pm)
        case "$pm" in
            apt) sudo apt-get update && sudo apt-get install -y "$pkg_apt" ;;
            dnf) sudo dnf install -y "$pkg_dnf" ;;
            pacman) sudo pacman -S --noconfirm "$pkg_pacman" ;;
            zypper) sudo zypper install -y "$pkg_zypper" ;;
            *) echo "Unsupported package manager. Please install $cmd manually."; exit 1 ;;
        esac
    fi
}

build_deb() {
    echo "=== Building DEB ==="
    install_dependency "dpkg-buildpackage" "dpkg-dev" "dpkg-dev" "dpkg" "dpkg"
    make -C "$PACKAGE_DIR" deb
    echo "Copying DEB to releases..."
    find "$PACKAGE_DIR/deb/build/.." -maxdepth 1 -name "*.deb" -exec cp {} "$RELEASES_DIR/" \;
}

build_rpm() {
    echo "=== Building RPM ==="
    install_dependency "rpmbuild" "rpm" "rpm-build" "rpm-tools" "rpm-build"
    make -C "$PACKAGE_DIR" rpm
    echo "Copying RPM to releases..."
    find "$PACKAGE_DIR/rpm/build/RPMS" -type f -name "*.rpm" -exec cp {} "$RELEASES_DIR/" \;
}

build_flatpak() {
    echo "=== Building Flatpak ==="
    install_dependency "flatpak-builder" "flatpak-builder" "flatpak-builder" "flatpak-builder" "flatpak-builder"
    make -C "$PACKAGE_DIR" flatpak
    echo "Copying Flatpak to releases..."
    find "$PACKAGE_DIR/flatpak" -maxdepth 1 -name "*.flatpak" -exec cp {} "$RELEASES_DIR/" \;
}

build_aur() {
    echo "=== Building AUR ==="
    install_dependency "makepkg" "pacman-package-manager" "pacman" "pacman" "pacman"
    make -C "$PACKAGE_DIR" aur
    echo "Copying AUR package to releases..."
    find "$PACKAGE_DIR/aur" -maxdepth 1 -name "*.pkg.tar.zst" -exec cp {} "$RELEASES_DIR/" \;
}

clean_all() {
    echo "=== Cleaning up build directories ==="
    make -C "$PACKAGE_DIR" clean
}

usage() {
    echo "Usage: $0 [OPTION]"
    echo "Build packages into the releases/ directory."
    echo ""
    echo "  --deb       Build DEB package"
    echo "  --rpm       Build RPM package"
    echo "  --flatpak   Build Flatpak bundle"
    echo "  --aur       Build Arch Linux package"
    echo "  --all       Build all packages (in sequence, cleaning in between)"
    echo "  --clean     Clean build directories"
}

if [ $# -eq 0 ]; then
    usage
    exit 0
fi

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --deb) build_deb ;;
        --rpm) build_rpm ;;
        --flatpak) build_flatpak ;;
        --aur) build_aur ;;
        --clean) clean_all ;;
        --all)
            # The user requested sequential building and deleting. We delete the package build dirs, not the common 'build/main/opt' because that's reused.
            build_deb
            rm -rf "$PACKAGE_DIR/deb/build" "$PACKAGE_DIR/deb"/*.deb
            build_rpm
            rm -rf "$PACKAGE_DIR/rpm/build"
            build_flatpak
            rm -rf "$PACKAGE_DIR/flatpak/build-dir" "$PACKAGE_DIR/flatpak"/*.flatpak
            build_aur
            # Leave AUR on the hard drive
            ;;
        *) usage; exit 1 ;;
    esac
    shift
done

echo "Done! Check the $RELEASES_DIR folder."

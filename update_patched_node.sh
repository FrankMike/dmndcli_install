#!/usr/bin/env bash

set -e

# Configuration
INSTALL_DIR="/usr/local/bin"
NODE_NAME="bitcoind"

# Get the installed version
get_installed_version() {
    if command -v "$INSTALL_DIR/$NODE_NAME" &> /dev/null; then
        "$INSTALL_DIR/$NODE_NAME" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
    else
        echo "none"
    fi
}

# Get the latest version (ipc and non-ipc)
get_latest_version() {
    if command -v jq &> /dev/null; then
        curl -s "https://api.github.com/repos/Sjors/bitcoin/tags" | \
        jq -r '[.[] | select(.name | test("^sv2-tp(-ipc)?-[0-9]+\\.[0-9]+\\.[0-9]+$")) | .name] | sort_by(.[-1]) | .[0]'
    else
        curl -s "https://api.github.com/repos/Sjors/bitcoin/tags" | \
        grep -o '"name":"sv2-tp\(-ipc\)\?-[0-9]\+\.[0-9]\+\.[0-9]\+"' | \
        sed 's/"name":"\(sv2-tp[-ipc0-9.]*\)"/\1/' | \
        sort -V | \
        tail -n 1
    fi
}

# Download and install the latest version
install_latest() {
    local version_tag="$1"
    local version="${version_tag#sv2-tp-}"
    local arch
    local platform="linux-gnu"
    local machine_arch
    machine_arch=$(uname -m)

    case $machine_arch in
        x86_64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        armv7l|armv6l) arch="arm"; platform="linux-gnueabihf" ;;
        *) arch="x86_64";;
    esac

    # Determine if ipc version
    if [[ "$version_tag" == *"ipc"* ]]; then
        url="https://github.com/Sjors/bitcoin/releases/download/$version_tag/bitcoin-$version_tag-$arch-$platform.tar.gz"
        tarball="bitcoin-$version_tag-$arch-$platform.tar.gz"
    else
        url="https://github.com/Sjors/bitcoin/releases/download/$version_tag/bitcoin-sv2-tp-$version-$arch-$platform.tar.gz"
        tarball="bitcoin-sv2-tp-$version-$arch-$platform.tar.gz"
    fi

    tmpdir=$(mktemp -d)
    cd "$tmpdir"
    wget -O "$tarball" "$url"
    tar -xzf "$tarball"
    sudo cp -f bitcoin*/bin/bitcoind "$INSTALL_DIR/"
    sudo cp -f bitcoin*/bin/bitcoin-cli "$INSTALL_DIR/"
    cd -
    rm -rf "$tmpdir"
}


installed_version=$(get_installed_version)
latest_tag=$(get_latest_version)
latest_version=$(echo "$latest_tag" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

echo "Installed version: $installed_version"
echo "Latest available version: $latest_version ($latest_tag)"

if [ "$installed_version" != "$latest_version" ]; then
    echo "Updating to $latest_tag..."
    install_latest "$latest_tag"
    echo "Update complete."
else
    echo "Already up to date."
fi

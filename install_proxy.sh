#!/bin/bash

# ProxyClient Installation Script

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

PROXY_CLIENT_EXECUTABLE_PATH=""

# Messages functions
print_message() {
    echo -e "${GREEN}[+] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[!] $1${NC}"
}

print_error() {
    echo -e "${RED}[-] $1${NC}"
}

if [ "$EUID" -eq 0 ]; then
    print_message "Please run the script without sudo"
    sleep 3
    exit 0
fi

USER= &
(whoami)

print_message "Installing ProxyClient for user: $USER"

USER_HOME=$(eval echo ~$USER)

# Detect OS
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="linux"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
else
    OS="unknown"
fi

print_message "Detected OS: $OS"

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" == "x86_64" ]; then
    ARCH="x86_64"
elif [ "$ARCH" == "aarch64" ] || [ "$ARCH" == "arm64" ]; then
    ARCH="aarch64"
else
    print_error "Unsupported architecture: $ARCH"
    exit 1
fi

print_message "Detected architecture: $ARCH"

# Install dependencies
install_dependencies() {
    print_message "Installing dependencies..."

    case $OS in
    linux)
        if command -v apt-get &>/dev/null; then
            sudo apt-get update
            sudo apt-get install -y curl wget git build-essential pkg-config libssl-dev
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y curl wget git gcc gcc-c++ make openssl-devel pkg-config
        elif command -v pacman &>/dev/null; then
            sudo pacman -Sy --noconfirm curl wget git base-devel openssl pkg-config
        else
            print_warning "Unsupported Linux distribution. Please install the necessary dependencies manually."
            print_warning "Dependencies needed: curl, wget, git, compiler toolchain, and OpenSSL development libraries."
        fi
        ;;
    macos)
        if command -v brew &>/dev/null; then
            brew install curl wget git openssl pkg-config
        else
            print_warning "Homebrew not found. Installing Homebrew..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            brew install curl wget git openssl pkg-config
        fi
        ;;
    *)
        print_error "Unsupported operating system. Please install the necessary dependencies manually."
        exit 1
        ;;
    esac

    print_message "Dependencies installed successfully"
}

# Check if Rust is installed
check_rust() {
    local cargo_cmd_path=""
    local rustc_cmd_path=""

    # Check if Rust/Cargo is already available for USER
    if command -v cargo &>/dev/null; then
        cargo_cmd_path=$(command -v cargo)
    fi
    if command -v rustc &>/dev/null; then
        rustc_cmd_path=$(command -v rustc)
    fi

    if [ -n "$cargo_cmd_path" ] && [ -f "$cargo_cmd_path" ] && [ -n "$rustc_cmd_path" ] && [ -f "$rustc_cmd_path" ]; then
        print_message "Rust (rustc and cargo) appears to be installed for user $USER."
        return 0
    fi

    print_warning "Rust (rustc/cargo) not found for user $USER. Attempting to install Rust..."

    local rustup_install_cmd="curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path"

    # Run rustup
    if ! (eval "$rustup_install_cmd"); then
        print_error "Rust installation failed using rustup."
        return 1 # Failure
    fi
    print_message "Rust installed. Cargo should be at $HOME/.cargo/bin/cargo"
    if [ -f "$HOME/.cargo/env" ]; then
        source "$HOME/.cargo/env"
    else
        print_warning "Could not source $HOME/.cargo/env. Cargo might not be in PATH for immediate next steps."
    fi

    # Verify installation
    if ! command -v cargo &>/dev/null || ! command -v rustc &>/dev/null; then
        print_error "Cargo or rustc command not found in PATH."
        print_warning "Please check $HOME/.cargo/bin is in your PATH or try opening a new terminal."
        return 1 # Failure
    fi

    print_message "Rust installation process completed successfully for user $USER."
    return 0 # Success
}

# Download prebuilt binaries
download_prebuilt_binaries() {
    print_message "Downloading prebuilt binaries from GitHub releases..."

    local local_bin_os=""
    if [[ "$OS" == "linux" ]]; then
        local_bin_os="linux"
    elif [[ "$OS" == "macos" ]]; then
        local_bin_os="macos"
    else
        print_error "Unsupported OS ('$OS') for prebuilt binaries"
        return 1
    fi

    local local_bin_arch=""
    if [ "$ARCH" == "x86_64" ]; then
        local_bin_arch="x86_64"
    elif [ "$ARCH" == "aarch64" ] || [ "$ARCH" == "arm64" ]; then
        local_bin_arch="aarch64"
    else
        print_error "Unsupported architecture ('$ARCH') for prebuilt binaries"
        return 1
    fi

    local TEMP_DIR
    TEMP_DIR=$(mktemp -d)

    local CURRENT_PWD="$PWD"
    cd "$TEMP_DIR"

    print_message "Fetching latest release information..."
    local LATEST_RELEASE_URL="https://api.github.com/repos/demand-open-source/demand-cli/releases/latest"
    local RELEASE_INFO

    if command -v curl &>/dev/null; then
        RELEASE_INFO=$(curl -sL "$LATEST_RELEASE_URL")
    elif command -v wget &>/dev/null; then
        RELEASE_INFO=$(wget -q -O- "$LATEST_RELEASE_URL")
    else
        print_error "Neither curl nor wget is available. Cannot fetch release info."
        cd "$CURRENT_PWD"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    local VERSION
    VERSION=$(echo "$RELEASE_INFO" | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4)

    if [ -z "$VERSION" ]; then
        print_error "Could not determine the latest version from GitHub API."
        cd "$CURRENT_PWD"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    print_message "Found latest version: $VERSION"

    local ASSET_NAME_PATTERN="demand-cli-${local_bin_os}-${local_bin_arch}"
    local ASSET_NAME_ALT1=""

    if [ "$local_bin_os" == "macos" ] && [ "$local_bin_arch" == "x86_64" ]; then
        ASSET_NAME_ALT1="demand-cli-darwin-amd64"
    elif [ "$local_bin_os" == "macos" ] && [ "$local_bin_arch" == "aarch64" ]; then
        ASSET_NAME_ALT1="demand-cli-darwin-arm64"
    elif [ "$local_bin_os" == "linux" ] && [ "$local_bin_arch" == "x86_64" ]; then
        ASSET_NAME_ALT1="demand-cli-linux-amd64"
    fi

    local DOWNLOAD_URL
    DOWNLOAD_URL=$(echo "$RELEASE_INFO" | grep -o "browser_download_url.*${ASSET_NAME_PATTERN}" | head -1 | cut -d'"' -f4)
    local ACTUAL_ASSET_NAME="$ASSET_NAME_PATTERN"

    if [ -z "$DOWNLOAD_URL" ] && [ -n "$ASSET_NAME_ALT1" ]; then
        DOWNLOAD_URL=$(echo "$RELEASE_INFO" | grep -o "browser_download_url.*${ASSET_NAME_ALT1}" | head -1 | cut -d'"' -f4)
        if [ -n "$DOWNLOAD_URL" ]; then ACTUAL_ASSET_NAME="$ASSET_NAME_ALT1"; fi
    fi

    if [ -z "$DOWNLOAD_URL" ]; then
        print_error "Could not find download URL for a matching asset: $ASSET_NAME_PATTERN or alternatives."
        print_message "Please check available assets at $LATEST_RELEASE_URL"
        cd "$CURRENT_PWD"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    print_message "Downloading binary $ACTUAL_ASSET_NAME from: $DOWNLOAD_URL"

    local DOWNLOADED_FILE_NAME="demand-cli_downloaded_binary"
    if command -v curl &>/dev/null; then
        curl -L -o "$DOWNLOADED_FILE_NAME" "$DOWNLOAD_URL"
    elif command -v wget &>/dev/null; then
        wget -O "$DOWNLOADED_FILE_NAME" "$DOWNLOAD_URL"
    else
        print_error "Neither curl nor wget available to download the binary."
        cd "$CURRENT_PWD"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    if [ ! -f "$DOWNLOADED_FILE_NAME" ] || [ ! -s "$DOWNLOADED_FILE_NAME" ]; then
        print_error "Failed to download the binary or downloaded an empty file."
        cd "$CURRENT_PWD"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    chmod +x "$DOWNLOADED_FILE_NAME"
    local INSTALL_DIR="$USER_HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"

    if mv "$DOWNLOADED_FILE_NAME" "$INSTALL_DIR/demand-cli"; then
        PROXY_CLIENT_EXECUTABLE_PATH="$INSTALL_DIR/demand-cli"
        chmod +x "$PROXY_CLIENT_EXECUTABLE_PATH"
        print_message "Binary downloaded and installed to $PROXY_CLIENT_EXECUTABLE_PATH"
        cd "$CURRENT_PWD"
        rm -rf "$TEMP_DIR"
        return 0
    else
        print_error "Failed to move downloaded binary to $INSTALL_DIR/demand-cli"
        print_error "Please check permissions for $INSTALL_DIR. Downloaded file is in $TEMP_DIR/$DOWNLOADED_FILE_NAME"
        cd "$CURRENT_PWD"
        return 1
    fi
}

# Build from source
build_from_source() {
    print_message "Building ProxyClient from source..."

    local cargo_executable_path_check=""

    if ! command -v cargo &>/dev/null; then
        print_error "Cargo command not found in PATH. Build cannot proceed."
        return 1
    fi
    cargo_executable_path_check=$(command -v cargo)

    if ! command -v git &>/dev/null; then
        print_error "Git not found. Please install Git. Cannot build from source."
        return 1
    fi

    local BUILD_DIR_PARENT="$USER_HOME/proxyclient_build_temp"
    mkdir -p "$BUILD_DIR_PARENT"
    local BUILD_DIR
    BUILD_DIR=$(mktemp -d -p "$BUILD_DIR_PARENT")

    print_message "Cloning into temporary directory: $BUILD_DIR/demand-cli"
    local GIT_CLONE_CMD="git clone https://github.com/demand-open-source/demand-cli.git \"$BUILD_DIR/demand-cli\""
    eval "$GIT_CLONE_CMD"

    if [ ! -d "$BUILD_DIR/demand-cli/.git" ]; then
        print_error "Failed to clone the demand-cli repository into $BUILD_DIR/demand-cli"
        rm -rf "$BUILD_DIR_PARENT"
        return 1
    fi

    local CD_CMD="cd \"$BUILD_DIR/demand-cli\""
    local CARGO_BUILD_CMD="cargo build --release"
    local FULL_BUILD_CMD="$CD_CMD && $CARGO_BUILD_CMD"

    print_message "Building with Cargo in $BUILD_DIR/demand-cli... This may take a few minutes."
    if [ -f "$HOME/.cargo/env" ]; then
        source "$HOME/.cargo/env"
    fi
    eval "$FULL_BUILD_CMD"

    local BUILD_SUCCESS_CODE=$?
    if [ $BUILD_SUCCESS_CODE -ne 0 ]; then
        print_error "Failed to build ProxyClient from source using Cargo. Exit code: $BUILD_SUCCESS_CODE"
        return 1
    fi

    local INSTALL_DIR="$USER_HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"

    local BUILT_BINARY_PATH="$BUILD_DIR/demand-cli/target/release/demand-cli"
    if [ ! -f "$BUILT_BINARY_PATH" ]; then
        print_error "Built binary not found at $BUILT_BINARY_PATH even after successful build report."
        return 1
    fi

    if cp "$BUILT_BINARY_PATH" "$INSTALL_DIR/demand-cli"; then
        PROXY_CLIENT_EXECUTABLE_PATH="$INSTALL_DIR/demand-cli"
        chmod +x "$PROXY_CLIENT_EXECUTABLE_PATH"
        print_message "ProxyClient built and installed to $PROXY_CLIENT_EXECUTABLE_PATH"
        rm -rf "$BUILD_DIR_PARENT"
        return 0
    else
        print_error "Failed to copy built binary from $BUILT_BINARY_PATH to $INSTALL_DIR/demand-cli"
        print_error "Please check permissions for $INSTALL_DIR."
        return 1
    fi
}


final_config() {
    if [ -z "$PROXY_CLIENT_EXECUTABLE_PATH" ] || [ ! -f "$PROXY_CLIENT_EXECUTABLE_PATH" ]; then
        print_error "ProxyClient binary not found at expected path. Installation failed."
        return 1
    fi

    print_message "Executable installed at: ${GREEN}$PROXY_CLIENT_EXECUTABLE_PATH${NC}"

    local install_bin_dir_for_path_check="$USER_HOME/.local/bin"

    if ! echo "$PATH" | grep -q "$install_bin_dir_for_path_check"; then
        print_message "Adding '$install_bin_dir_for_path_check' to PATH for user '$USER'..."

        USER_SHELL=$(basename "$(getent passwd "$USER" | cut -d: -f7 2>/dev/null || echo "$SHELL")")
        PATH_EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'

        case "$USER_SHELL" in
            zsh)
                SHELL_RC="$USER_HOME/.zshrc"
                ;;
            *)
                SHELL_RC="$USER_HOME/.bashrc"
                ;;
        esac

        if ! grep -qF "$PATH_EXPORT_LINE" "$SHELL_RC" 2>/dev/null; then
            echo "$PATH_EXPORT_LINE" >> "$SHELL_RC"
            print_message "'$install_bin_dir_for_path_check' added to PATH in $SHELL_RC."
        fi
        export PATH="$HOME/.local/bin:$PATH"

        print_message "Reloading shell configuration..."
        if [ -f "$SHELL_RC" ]; then
            source "$SHELL_RC"
        fi
    else
        print_message "'$install_bin_dir_for_path_check' is already in PATH."
    fi

    echo
    print_message "Next, you need to set your DMND Account Token."
    print_message "You can find this token on your DMND dashboard (https://dev-app.dmnd.work/home) after logging in and clicking 'Connect'."

    local USER_TOKEN=""
    while true; do
        read -p "$(echo -e "${YELLOW}Please enter your DMND Account Token: ${NC}")" USER_TOKEN
        if [ -z "$USER_TOKEN" ]; then
            print_warning "Token cannot be empty. Please try again."
        elif [[ "$USER_TOKEN" =~ [[:space:]] ]]; then
            print_warning "Token should not contain spaces. Please check your token and try again."
        else
            break
        fi
    done

    echo
    print_message "To use the ProxyClient, the TOKEN environment variable must be set."

    print_message "Would you like to add your DMND Account Token to your shell config so it is set automatically in future sessions?"
    read -p "$(echo -e "${YELLOW}Add TOKEN to $USER_HOME/.bashrc now? (y/n): ${NC}")" ADD_TOKEN_RC

    if [[ "$ADD_TOKEN_RC" =~ ^[Yy]$ ]]; then
        USER_SHELL=$(basename "$(getent passwd "$USER" | cut -d: -f7 2>/dev/null || echo "$SHELL")")
        case "$USER_SHELL" in
            zsh)
                SHELL_RC="$USER_HOME/.zshrc"
                ;;
            *)
                SHELL_RC="$USER_HOME/.bashrc"
                ;;
        esac
        echo "export TOKEN=\"$USER_TOKEN\"" >> "$SHELL_RC"
        source "$SHELL_RC"
    else
        print_message "You can set the TOKEN for this session with:"
        echo -e "   ${YELLOW}export TOKEN=\"$USER_TOKEN\"${NC}"
    fi

    echo
    print_message "-----------------------------------------------------"
    print_message "Setup Complete! You can now start mining."
    print_message "-----------------------------------------------------"
    print_message "Would you like to run the ProxyClient now?"
    read -p "$(echo -e "${YELLOW}Run ProxyClient now? (y/n): ${NC}")" RUN_NOW

    local run_command_prefix=""
    if command -v demand-cli &>/dev/null && [[ "$(command -v demand-cli)" == "$PROXY_CLIENT_EXECUTABLE_PATH" ]]; then
        run_command_prefix="demand-cli"
    else
        run_command_prefix="\"$PROXY_CLIENT_EXECUTABLE_PATH\""
    fi

    if [[ "$RUN_NOW" =~ ^[Yy]$ ]]; then
        print_message "Running ProxyClient in test mode with example settings..."
        eval $run_command_prefix --test -d 50T
    else
        print_message "You can run the ProxyClient with the following command:"
        echo -e "  ${GREEN}${run_command_prefix} --test -d 50T${NC}"
        print_message "This example uses the test endpoint and assumes 50TH/s hashrate."
    fi
    return 0
}

# --- Main Script---

print_message "Starting ProxyClient (demand-cli) installation for user: $USER (Home: $USER_HOME)"

install_dependencies

rust_ready_status=1 # 0 for ready, 1 for not ready/error
print_message "Checking Rust installation..."
if check_rust; then
    rust_ready_status=0
    print_message "Rust environment check/setup successful."
else
    print_warning "Rust environment check/setup failed. Building from source will not be possible."
fi

print_message "Installing ProxyClient (demand-cli)..."
print_message "How would you like to install ProxyClient (demand-cli)?"
echo "1. Use prebuilt binaries"
echo "2. Build from source"
read -p "$(echo -e "${YELLOW}Enter your choice (1/2): ${NC}")" INSTALL_CHOICE

case "$INSTALL_CHOICE" in
    2)
        print_message "Building ProxyClient from source."
        if [ "$rust_ready_status" -ne 0 ]; then
            print_error "Cannot build from source because the Rust environment is not ready."
            print_error "ProxyClient installation failed."
            exit 1
        fi
        if build_from_source; then
            print_message "ProxyClient successfully built and installed from source."
        else
            print_error "Failed to install ProxyClient from source."
            exit 1
        fi
        ;;
    1|"")
        print_message "Installing ProxyClient from prebuilt binary..."
        if download_prebuilt_binaries; then
            print_message "ProxyClient successfully installed from prebuilt binary."
        else
            print_warning "Failed to install from prebuilt binary, or no suitable binary found for $OS/$ARCH."
            print_message "Attempting to build ProxyClient from source instead. This may take some time..."
            if [ "$rust_ready_status" -ne 0 ]; then
                print_error "Cannot attempt to build from source because the Rust environment is not ready."
                print_error "ProxyClient installation failed."
                exit 1
            fi
            if build_from_source; then
                print_message "ProxyClient successfully built and installed from source."
            else
                print_error "Failed to install ProxyClient from both prebuilt binary and source."
                exit 1
            fi
        fi
        ;;
    *)
        print_error "Invalid choice. Exiting."
        exit 1
        ;;
esac

if [ -n "$PROXY_CLIENT_EXECUTABLE_PATH" ] && [ -f "$PROXY_CLIENT_EXECUTABLE_PATH" ]; then
    if ! configure_final_steps; then
        print_error "Final configuration failed."
    fi
    print_message "${GREEN}ProxyClient installation and configuration process finished.${NC}"
else
    print_error "Installation failed."
    exit 1
fi

exit 0

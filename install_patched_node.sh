#!/bin/bash

# Bitcoin SV2 Template Provider Installation Script

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color


print_message() {
    echo -e "${GREEN}[Info] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[Warning] $1${NC}"
}

print_error() {
    echo -e "${RED}[Error] $1${NC}"
}

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
    print_error "Please run this script as root or with sudo"
    exit 1
fi

if [ -n "$SUDO_USER" ]; then
    ACTUAL_USER=$SUDO_USER
else
    ACTUAL_USER=$(whoami)
fi

print_message "Installing Bitcoin SV2 Template Provider for user: $ACTUAL_USER"

USER_HOME=$(eval echo ~$ACTUAL_USER)

# Detect Operating System and Distribution
OS_TYPE=""
DISTRO=""
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS_TYPE="linux"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
        print_message "Detected Linux distribution: $DISTRO"
    else
        print_error "Could not detect Linux distribution information from /etc/os-release"
        # Try lsb_release as a fallback if available
        if command -v lsb_release &> /dev/null; then
            DISTRO=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
            VERSION_ID=$(lsb_release -rs)
            print_message "Detected Linux distribution (via lsb_release): $DISTRO $VERSION_ID"
            if [ -z "$DISTRO" ]; then 
                print_error "lsb_release failed to identify distribution."
                exit 1
            fi
        else
            print_error "Could not detect Linux distribution. Please ensure /etc/os-release or lsb_release is available."
            exit 1
        fi
    fi
elif [[ "$OSTYPE" == "darwin"* ]]; then
    OS_TYPE="macos"
    print_message "Detected Operating System: macOS"
else
    print_error "Unsupported operating system: $OSTYPE"
    exit 1
fi

# Define macOS specific paths
LAUNCHD_SERVICE_LABEL="com.bitcoinsv2.bitcoind.$ACTUAL_USER" # User-specific label
LAUNCHD_SERVICE_PATH="$USER_HOME/Library/LaunchAgents/$LAUNCHD_SERVICE_LABEL.plist"
BITCOIN_DATA_DIR_MACOS="$USER_HOME/Library/Application Support/Bitcoin"

# Install dependencies based on distribution
install_dependencies() {
    print_message "Installing dependencies for $OS_TYPE..."

    if [ "$OS_TYPE" = "macos" ]; then
        if ! command -v brew &> /dev/null; then
            print_message "Homebrew not found. Installing Homebrew..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        print_message "Updating Homebrew..."
        brew update
        
        local pkgs_to_install=""
        for pkg in wget gnupg curl jq; do
            if ! brew list $pkg &>/dev/null; then
                pkgs_to_install="$pkgs_to_install $pkg"
            fi
        done
        if [ -n "$pkgs_to_install" ]; then
            print_message "Installing Homebrew packages: $pkgs_to_install..."
            brew install $pkgs_to_install || {
                print_error "Failed to install Homebrew packages: $pkgs_to_install"
                exit 1
            }
        else
            print_message "Required packages are already installed."
        fi

    elif [ "$OS_TYPE" = "linux" ]; then
        case $DISTRO in
            ubuntu|debian|pop|mint|elementary)
                apt-get update || {
                    print_error "Failed to update package lists"
                    exit 1
                }
                DEBIAN_FRONTEND=noninteractive apt-get install -y wget gnupg curl software-properties-common apt-transport-https ca-certificates jq || {
                    print_error "Failed to install dependencies"
                    exit 1
                }
                ;;
            fedora|centos|rhel)
                dnf install -y wget gnupg curl ca-certificates jq || {
                    print_error "Failed to install dependencies (wget, gnupg, curl, ca-certificates, jq)"
                    exit 1
                }
                ;;
            arch|manjaro)
                pacman -Sy --noconfirm wget gnupg curl jq || {
                    print_error "Failed to install dependencies (wget, gnupg, curl, jq)"
                    exit 1
                }
                ;;
            *)
                print_warning "Unsupported Linux distribution: $DISTRO. Installing basic dependencies (wget, gnupg, curl, jq)..."
                if command -v apt-get &> /dev/null; then
                    apt-get update
                    apt-get install -y wget gnupg curl jq
                elif command -v dnf &> /dev/null; then
                    dnf install -y wget gnupg curl jq
                elif command -v pacman &> /dev/null; then
                    pacman -Sy --noconfirm wget gnupg curl jq
                else
                    print_error "Could not install dependencies. Please install wget, gnupg, curl, and jq manually."
                    exit 1
                fi
                ;;
        esac
    fi
    
    for cmd in wget gpg curl jq; do
    print_message "Installing dependencies..."
    
    case $DISTRO in
        ubuntu|debian|pop|mint|elementary)
            apt-get update || {
                print_error "Failed to update package lists"
                exit 1
            }
            DEBIAN_FRONTEND=noninteractive apt-get install -y wget gnupg curl software-properties-common apt-transport-https ca-certificates || {
                print_error "Failed to install dependencies"
                exit 1
            }
            ;;
        fedora|centos|rhel)
            dnf install -y wget gnupg curl ca-certificates
            ;;
        arch|manjaro)
            pacman -Sy --noconfirm wget gnupg curl
            ;;
        *)
            print_warning "Unsupported distribution. Installing basic dependencies..."
            if command -v apt-get &> /dev/null; then
                apt-get update
                apt-get install -y wget gnupg curl
            elif command -v dnf &> /dev/null; then
                dnf install -y wget gnupg curl
            elif command -v pacman &> /dev/null; then
                pacman -Sy --noconfirm wget gnupg curl
            else
                print_error "Could not install dependencies. Please install wget, gnupg, and curl manually."
                exit 1
            fi
            ;;
    esac
    
    for cmd in wget gpg curl; do
        if ! command -v $cmd &> /dev/null; then
            print_error "Required dependency '$cmd' is not installed"
            exit 1
        fi
    done
    
    done
    print_message "Dependencies installed successfully"
}

# Get the latest version of the Bitcoin patched node
get_latest_version() {
    local default_version="0.1.17"
    local latest_version=""
    
    if command -v curl &> /dev/null; then
        if command -v jq &> /dev/null; then
            latest_version=$(curl -s "https://api.github.com/repos/Sjors/bitcoin/tags" | 
                           jq -r '[.[] | select(.name | test("^sv2-tp(-ipc)?-[0-9]+\\.[0-9]+\\.[0-9]+$")) | .name | sub("sv2-tp(-ipc)?-";"")] | sort_by( split(".") | map(tonumber) ) | .[-1] // ""')
        else
            latest_version=$(curl -s "https://api.github.com/repos/Sjors/bitcoin/tags" | 
                           grep -o '"name":"sv2-tp\(-ipc\)\?-[0-9]\+\.[0-9]\+\.[0-9]\+"' |
                           grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | 
                           sort -V | 
                           tail -n 1)
        fi
    elif command -v wget &> /dev/null; then
        latest_version=$(wget -q -O - "https://api.github.com/repos/Sjors/bitcoin/tags" | 
                        grep -o '"name":"sv2-tp\(-ipc\)\?-[0-9]\+\.[0-9]\+\.[0-9]\+"' |
                        grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | 
                        sort -V | 
                        tail -n 1)
    fi
    
    if [ -z "$latest_version" ]; then
        print_message "Could not fetch latest version from GitHub API, checking known versions..." >&2
        check_url_exists() {
            local url="$1"
            if command -v curl &> /dev/null; then
                if curl --output /dev/null --silent --head --fail "$url"; then
                    return 0
                else
                    return 1
                fi
            elif command -v wget &> /dev/null; then
                if wget --spider --quiet "$url"; then
                    return 0
                else
                    return 1
                fi
            else
                return 1
            fi
        }
        
        # Fallback to checking known versions if API fails
        for version_num_fallback in "0.1.17" "0.1.16" "0.1.15" "0.1.14" "0.1.13" "0.1.12"; do
            # Check for non-IPC release tag
            if check_url_exists "https://github.com/Sjors/bitcoin/releases/tag/sv2-tp-$version_num_fallback"; then
                latest_version="$version_num_fallback"
                print_message "Found existing version via fallback (non-IPC tag check): $latest_version" >&2
                break
            fi
            # Check for IPC release tag if non-IPC not found for this version_num_fallback
            if check_url_exists "https://github.com/Sjors/bitcoin/releases/tag/sv2-tp-$version_num_fallback-ipc"; then
                latest_version="$version_num_fallback"
                print_message "Found existing version via fallback (IPC tag check): $latest_version" >&2
                break
            fi
        done
        
        # Use default if no version found
        if [ -z "$latest_version" ]; then
            latest_version="$default_version"
            print_message "Falling back to default version: $default_version" >&2
        fi
    fi
    
    # Return version number
    echo "$latest_version"
}

# Download and install Bitcoin SV2 Template Provider
download_sv2_bitcoin() {
    print_message "Checking for the latest release version..."
    local base_version
    base_version=$(get_latest_version)

    if [ -z "$base_version" ]; then
        print_error "Failed to get a valid base version number"
        exit 1
    fi
    print_message "Latest base version found: $base_version"

    local install_type_choice=""
    while true; do
        read -p "Do you want to install the IPC version of Bitcoin SV2 TP v$base_version? (y/n) [n]: " choice_input
        choice_input=${choice_input:-n} # Default to 'n'
        if [[ "$choice_input" =~ ^[Yy]$ ]]; then
            install_type_choice="ipc"
            print_message "You selected the IPC version."
            break
        elif [[ "$choice_input" =~ ^[Nn]$ ]]; then
            install_type_choice="non-ipc"
            print_message "You selected the Non-IPC version."
            break
        else
            print_warning "Invalid input. Please enter 'y' or 'n'."
        fi
    done

    local release_tag_name_prefix="sv2-tp-$base_version"
    local file_name_prefix="sv2-tp-$base_version"

    if [ "$install_type_choice" = "ipc" ]; then
        release_tag_name_prefix+="-ipc"
        file_name_prefix+="-ipc"
    fi

    print_message "Preparing to download Bitcoin SV2 Template Provider $file_name_prefix"

    # Detect system architecture
    local arch
    local machine_arch=$(uname -m)
    local platform=""

    if [ "$OS_TYPE" = "linux" ]; then
        platform="linux-gnu"
    elif [ "$OS_TYPE" = "macos" ]; then
        platform="apple-darwin"
    else
        print_error "Cannot determine platform for OS_TYPE: $OS_TYPE"
        exit 1
    fi

    case $machine_arch in
        x86_64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        armv7l|armv6l)
            arch="arm"
            if [ "$OS_TYPE" = "linux" ]; then platform="linux-gnueabihf"; else
                print_warning "ARM 32-bit on non-Linux ($OS_TYPE) is not typically supported by these binaries. Defaulting to generic ARM arch."
            fi
            ;;
        *) arch="x86_64"; print_warning "Unrecognized architecture: $machine_arch, defaulting to x86_64" ;;
    esac

    print_message "System architecture: $arch-$platform"

    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR" || { print_error "Failed to create temporary directory"; exit 1; }

    local success=false
    local BITCOIN_FILE=""

    local primary_dl_filename="bitcoin-$file_name_prefix-$arch-$platform.tar.gz"
    local primary_dl_url="https://github.com/Sjors/bitcoin/releases/download/$release_tag_name_prefix/$primary_dl_filename"

    print_message "Attempting to download from: $primary_dl_url"
    if wget --no-verbose -O "$primary_dl_filename" "$primary_dl_url"; then
        print_message "Successfully downloaded $primary_dl_filename"
        BITCOIN_FILE="$primary_dl_filename"
        success=true
    else
        print_message "Download failed for primary URL: $primary_dl_url"
    fi

    if [ "$success" = false ]; then
        print_error "Failed to download Bitcoin SV2 Template Provider ($file_name_prefix)"
        print_message "Please check release availability for your architecture ($arch-$platform) at:"
        print_message "https://github.com/Sjors/bitcoin/releases/tag/$release_tag_name_prefix"
        print_message "Or general releases: https://github.com/Sjors/bitcoin/releases"
        cd - > /dev/null || true; rm -rf "$TEMP_DIR"
        exit 1
    fi

    print_message "Extracting Bitcoin SV2 Template Provider ($BITCOIN_FILE)..."
    tar -xzf "$BITCOIN_FILE"

    print_message "Installing Bitcoin SV2 Template Provider..."
    EXTRACT_DIR=$(find . -maxdepth 1 -type d -name "bitcoin-*" -o -name "sv2-*" | head -n 1)
    if [ -z "$EXTRACT_DIR" ]; then EXTRACT_DIR="."; fi

    if [ -d "$EXTRACT_DIR/bin" ]; then
        print_message "Found bin directory, preparing to copy from $EXTRACT_DIR/bin/ to /usr/local/bin/ with -sv2tp suffix"
        for file_path in "$EXTRACT_DIR/bin/"*; do
            if [ -f "$file_path" ] && [ -x "$file_path" ]; then
                local filename
                filename=$(basename "$file_path")
                print_message "Copying $filename to /usr/local/bin/${filename}-sv2tp"
                cp "$file_path" "/usr/local/bin/${filename}-sv2tp"
            fi
        done
        print_message "Finished copying"
    else
        print_message "No bin directory found"
        local executables_found
        executables_found=$(find "$EXTRACT_DIR" -maxdepth 1 -type f -executable)

        if [ -n "$executables_found" ]; then
            echo "$executables_found" | while IFS= read -r file_path; do
                local filename
                filename=$(basename "$file_path")
                print_message "Copying $filename to /usr/local/bin/${filename}-sv2tp"
                cp "$file_path" "/usr/local/bin/${filename}-sv2tp"
            done
            print_message "Finished copying"
        else
            print_error "No executables found in the extracted archive's top level or bin directory."
            cd - > /dev/null || true; rm -rf "$TEMP_DIR"
            exit 1
        fi
    fi

    cd - > /dev/null || true
    rm -rf "$TEMP_DIR"
    print_message "Bitcoin SV2 Template Provider $file_name_prefix (base v$base_version) has been installed successfully!"
}

# Create data directory
setup_data_directory() {
    print_message "Setting up Bitcoin SV2 TP data directory..."

    if [ "$OS_TYPE" = "linux" ]; then
        BITCOIN_DATA_DIR="$USER_HOME/.bitcoin-sv2tp"
    elif [ "$OS_TYPE" = "macos" ]; then
        local base_macos_data_dir="${BITCOIN_DATA_DIR_MACOS:-$USER_HOME/Library/Application Support/Bitcoin}"
        BITCOIN_DATA_DIR="${base_macos_data_dir}-sv2tp"
    else
        print_error "Cannot determine Bitcoin data directory for OS_TYPE: $OS_TYPE"
        exit 1
    fi

    print_message "Using Bitcoin SV2 TP data directory: $BITCOIN_DATA_DIR"
    if [ ! -d "$BITCOIN_DATA_DIR" ]; then
        mkdir -p "$BITCOIN_DATA_DIR"
        if [ -n "$ACTUAL_USER" ]; then
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$BITCOIN_DATA_DIR"
        else
            print_warning "ACTUAL_USER not set, skipping chown for $BITCOIN_DATA_DIR. Permissions might be incorrect."
        fi
        chmod 750 "$BITCOIN_DATA_DIR"
        print_message "Created Bitcoin SV2 TP data directory: $BITCOIN_DATA_DIR"
    else
        print_message "Bitcoin SV2 TP data directory already exists: $BITCOIN_DATA_DIR"
    fi
}

# Create systemd service
# Create Bitcoin SV2 TP configuration file
create_bitcoin_config() {
    print_message "Creating Bitcoin SV2 TP configuration file at $BITCOIN_DATA_DIR/bitcoin.conf..."
    if [ ! -d "$BITCOIN_DATA_DIR" ]; then
        print_error "Bitcoin SV2 TP data directory $BITCOIN_DATA_DIR does not exist. Cannot create bitcoin.conf."
        exit 1
    fi

    local rpc_user="sv2rpcuser"
    local rpc_pass
    rpc_pass=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 24) # Random password

    cat > "$BITCOIN_DATA_DIR/bitcoin.conf" << EOF
# Basic Bitcoin Core settings
server=1
txindex=1

# RPC settings
rpcuser=${rpc_user}
rpcpassword=${rpc_pass}
rpcallowip=127.0.0.1
rpcport=18332

# SV2 specific settings
sv2=1
sv2port=8442
sv2bind=0.0.0.0
sv2interval=10
sv2feedelta=200000

# Network settings (mainnet by default)
# testnet=0
# regtest=0

# Connection settings
port=18333
listen=1
# maxconnections=125
EOF

    if [ -n "$ACTUAL_USER" ]; then
        chown "$ACTUAL_USER:$ACTUAL_USER" "$BITCOIN_DATA_DIR/bitcoin.conf"
    fi
    chmod 600 "$BITCOIN_DATA_DIR/bitcoin.conf"

    print_message "Bitcoin SV2 TP configuration file created: $BITCOIN_DATA_DIR/bitcoin.conf"
    print_message "RPC User: $rpc_user"
    print_message "RPC Password: $rpc_pass (SAVE THIS SECURELY!)"
}

# Create systemd service
create_systemd_service() {
    if [ "$OS_TYPE" != "linux" ]; then
        print_message "Skipping systemd service creation on $OS_TYPE."
        return
    fi
    print_message "Creating systemd service for Bitcoin SV2 TP..."

    SYSTEMD_SERVICE="/etc/systemd/system/bitcoind-sv2tp.service" # Changed service name

    cat > "$SYSTEMD_SERVICE" << EOF
[Unit]
Description=Bitcoin SV2 Template Provider Daemon (Patched)
After=network.target

[Service]
User=$ACTUAL_USER
Group=$ACTUAL_USER
Type=forking
ExecStart=/usr/local/bin/bitcoind-sv2tp -daemon -conf=$BITCOIN_DATA_DIR/bitcoin.conf -datadir=$BITCOIN_DATA_DIR
ExecStop=/usr/local/bin/bitcoin-cli-sv2tp -conf=$BITCOIN_DATA_DIR/bitcoin.conf -datadir=$BITCOIN_DATA_DIR stop
Restart=on-failure
TimeoutStartSec=infinity
TimeoutStopSec=600

# Hardening measures
PrivateTmp=true
ProtectSystem=full
NoNewPrivileges=true
PrivateDevices=true

[Install]
WantedBy=multi-user.target
EOF

    print_message "Created systemd service: $SYSTEMD_SERVICE"

    # Reload systemd
    systemctl daemon-reload

    # Enable the service to start at boot
    systemctl enable bitcoind-sv2tp.service # Changed service name

    print_message "Bitcoin SV2 TP service (bitcoind-sv2tp.service) has been enabled to start at boot"
}

# Set environment variables
setup_environment_variables() {
    print_message "Setting up environment variables for mining..."
    
    # Create a file to store environment variables
    ENV_FILE="$USER_HOME/.sv2_environment"
    
    # Ask for token
    read -p "Enter your miner TOKEN: " TOKEN
    
    # Set TP_ADDRESS if on local machine
    TP_ADDRESS="127.0.0.1:8442"
    
    # Write environment variables to file
    cat > "$ENV_FILE" << EOF
# SV2 Template Provider Environment Variables
export TOKEN="$TOKEN"
export TP_ADDRESS="$TP_ADDRESS"
EOF
    
    # Set permissions
    chown $ACTUAL_USER:$ACTUAL_USER "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    
    SHELL_CONFIG_FILES=()
    if [ -f "$USER_HOME/.bashrc" ]; then SHELL_CONFIG_FILES+=("$USER_HOME/.bashrc"); fi
    if [ -f "$USER_HOME/.zshrc" ] && [ "$OS_TYPE" = "linux" ]; then SHELL_CONFIG_FILES+=("$USER_HOME/.zshrc"); fi # Zsh on Linux
    
    if [ "$OS_TYPE" = "macos" ]; then
        if [ -f "$USER_HOME/.zshrc" ]; then SHELL_CONFIG_FILES+=("$USER_HOME/.zshrc"); fi
        if [ -f "$USER_HOME/.bash_profile" ]; then SHELL_CONFIG_FILES+=("$USER_HOME/.bash_profile"); fi
        if [ ! -f "$USER_HOME/.bash_profile" ] && [ -f "$USER_HOME/.bashrc" ]; then SHELL_CONFIG_FILES+=("$USER_HOME/.bashrc"); fi
    fi

    if [ -f "$USER_HOME/.profile" ]; then 
        is_already_covered=false
        for existing_file in "${SHELL_CONFIG_FILES[@]}"; do
            if [[ "$existing_file" == "$USER_HOME/.bash_profile" && -f "$USER_HOME/.bash_profile" ]]; then
                is_already_covered=true
                break
            fi
        done
        if ! $is_already_covered; then
             SHELL_CONFIG_FILES+=("$USER_HOME/.profile")
        fi    
    fi

    UNIQUE_SHELL_CONFIG_FILES=($(printf "%s\n" "${SHELL_CONFIG_FILES[@]}" | sort -u))

    for config_file in "${UNIQUE_SHELL_CONFIG_FILES[@]}"; do
        if [ -f "$config_file" ]; then
            if ! grep -q "source $ENV_FILE" "$config_file"; then
                print_message "Adding source command for $ENV_FILE to $config_file"
                echo -e "\n# Source SV2 environment variables\nif [ -f $ENV_FILE ]; then\n    source $ENV_FILE\nfi" >> "$config_file"
            else
                print_message "Source command for $ENV_FILE already exists in $config_file"
            fi
        else
            print_warning "Shell configuration file $config_file not found. Skipping."
        fi
    done
    
    # Source the file for the current session
    source "$ENV_FILE"
    
    print_message "Environment variables have been set:"
    print_message "TOKEN=$TOKEN"
    print_message "TP_ADDRESS=$TP_ADDRESS"
    print_message "These variables will be available in new terminal sessions"
    print_message "To use them in the current session, run: source $ENV_FILE"
}

# Main
main() {
    print_message "Starting Bitcoin SV2 Template Provider installation and setup..."
    
    # Install dependencies
    install_dependencies
    
    # Download and install Bitcoin SV2
    download_sv2_bitcoin
    
    # Setup data directory
    setup_data_directory
    
    # Create Bitcoin SV2 configuration
    create_bitcoin_config
    
    # Create systemd service (Linux) or launchd service (macOS)
    if [ "$OS_TYPE" = "linux" ]; then
        create_systemd_service
    elif [ "$OS_TYPE" = "macos" ]; then
        create_launchd_service
    fi
    
    # Set up environment variables
    setup_environment_variables
    
    print_message "Bitcoin SV2 Template Provider installation and setup completed successfully!"

    if [ "$OS_TYPE" = "linux" ]; then
        print_message "You can start the Bitcoin SV2 daemon with: sudo systemctl start bitcoind-sv2tp.service"
        print_message "Check the status with: sudo systemctl status bitcoind-sv2tp.service"
        print_message "View logs with: sudo journalctl -u bitcoind-sv2tp.service -f"
    elif [ "$OS_TYPE" = "macos" ]; then
        print_message "The launchd service file is: $LAUNCHD_SERVICE_PATH"
        print_message "To load and start the service: launchctl load -w \"$LAUNCHD_SERVICE_PATH\""
        print_message "To check status: launchctl list | grep $LAUNCHD_SERVICE_LABEL"
    fi
    
    print_message "The SV2 Template Provider is configured to:"
    print_message "- Listen for mining requests on port 8442"
    print_message "- Send a new mining template every 10 seconds if no better one appears"
    print_message "- Send a new template if fees increase by at least 200,000 satoshis"
    
    # Ask the user to start the service now
    read -p "Do you want to attempt to start Bitcoin SV2 now? (y/n): " START_NOW
    if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
        if [ "$OS_TYPE" = "linux" ]; then
            if sudo systemctl start bitcoind-sv2tp.service; then
                print_message "Bitcoin SV2 service has been started (systemd)."
                print_message "Check status with: sudo systemctl status bitcoind-sv2tp.service"
            else
                print_error "Failed to start bitcoind-sv2 service. Check logs with 'sudo journalctl -u bitcoind-sv2tp.service -f' or system status."
            fi
        elif [ "$OS_TYPE" = "macos" ]; then
            if [ ! -f "$LAUNCHD_SERVICE_PATH" ]; then
                print_error "Launchd service file $LAUNCHD_SERVICE_PATH not found. Cannot start service."
            else
                launchctl unload "$LAUNCHD_SERVICE_PATH" 2>/dev/null
                if launchctl load -w "$LAUNCHD_SERVICE_PATH"; then
                    print_message "Bitcoin SV2 service has been loaded and enabled (launchd)."
                    print_message "It should start automatically. Check status with: launchctl list | grep $LAUNCHD_SERVICE_LABEL"
                else
                    print_error "Failed to load launchd service from $LAUNCHD_SERVICE_PATH. Check for errors with launchctl or system logs."
                fi
            fi
        fi
    else
        if [ "$OS_TYPE" = "linux" ]; then
            print_message "You can start Bitcoin SV2 later with: sudo systemctl start bitcoind-sv2tp.service"
        elif [ "$OS_TYPE" = "macos" ]; then
            print_message "You can start Bitcoin SV2 later by loading the service: launchctl load -w \"$LAUNCHD_SERVICE_PATH\""
        fi
    fi
    
    print_warning "IMPORTANT: This is a development version of Bitcoin Core with SV2 Template Provider support."
    print_warning "To manually start the node with the same parameters, you can run:"
    print_warning "bitcoind -sv2 -sv2port=8442 -sv2bind=0.0.0.0 -sv2interval=10 -sv2feedelta=200000"
    
    print_message "Environment variables have been set up for mining:"
    print_message "TOKEN - Your unique miner identification token"
    print_message "TP_ADDRESS - The address of your Bitcoin node (example: 127.0.0.1:8442)"
    print_message "These variables will be available in new terminal sessions"
}

# Create LaunchAgent service for macOS
create_launchd_service() {
    if [ "$OS_TYPE" != "macos" ]; then
        print_message "Skipping launchd service creation on $OS_TYPE."
        return
    fi

    print_message "Creating launchd service for Bitcoin SV2 (macOS)..."

    # Ensure the LaunchAgents directory exists
    mkdir -p "$(dirname "$LAUNCHD_SERVICE_PATH")"

    # Determine the correct datadir for the launchd service
    # BITCOIN_DATA_DIR should be set correctly by setup_data_directory before this function is called
    local effective_bitcoin_data_dir="$BITCOIN_DATA_DIR"
    if [ -z "$effective_bitcoin_data_dir" ]; then # Fallback if somehow not set
        effective_bitcoin_data_dir="$BITCOIN_DATA_DIR_MACOS"
    fi 

    cat > "$LAUNCHD_SERVICE_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCHD_SERVICE_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/bitcoind</string>
        <string>-datadir=$effective_bitcoin_data_dir</string>
        <string>-sv2</string>
        <string>-sv2port=8442</string>
        <string>-sv2bind=0.0.0.0</string>
        <string>-sv2interval=10</string>
        <string>-sv2feedelta=200000</string>

        <!-- <string>-printtoconsole</string> --> <!-- Uncomment if you want launchd to capture stdout/stderr -->
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>$USER_HOME/Library/Logs/$LAUNCHD_SERVICE_LABEL.out.log</string>
    <key>StandardErrorPath</key>
    <string>$USER_HOME/Library/Logs/$LAUNCHD_SERVICE_LABEL.err.log</string>
    <key>WorkingDirectory</key>
    <string>$USER_HOME</string> <!-- Or $effective_bitcoin_data_dir -->
</dict>
</plist>
EOF

    chown $ACTUAL_USER "$LAUNCHD_SERVICE_PATH"
    chmod 644 "$LAUNCHD_SERVICE_PATH"

    print_message "Created launchd service file: $LAUNCHD_SERVICE_PATH"
    print_message "To manage the service, use 'launchctl load/unload -w $LAUNCHD_SERVICE_PATH'"
    print_message "Logs will be in $effective_bitcoin_data_dir/debug.log, and potentially $USER_HOME/Library/Logs/ if -printtoconsole is used or stdout/stderr are redirected."
}

# Run the main function
main
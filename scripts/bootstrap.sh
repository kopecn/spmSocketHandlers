#!/usr/bin/env bash

set -e

echo "🔧 Bootstrapping Swift development environment..."

# Detect OS
OS="$(uname)"
IS_MACOS=false
IS_UBUNTU=false

if [[ "$OS" == "Darwin" ]]; then
  IS_MACOS=true
elif [[ "$OS" == "Linux" ]]; then
  if grep -qi "ubuntu" /etc/os-release; then
    IS_UBUNTU=true
  fi
fi

if ! $IS_MACOS && ! $IS_UBUNTU; then
  echo "❌ Unsupported OS: $OS. Only macOS and Ubuntu are supported."
  exit 1
fi

# Check for conflicting swiftformat tool (Lockwood)
if command -v swiftformat >/dev/null 2>&1; then
  echo "⚠️ Warning: 'swiftformat' (Lockwood's tool) is installed."
  echo "This script installs Apple's 'swift-format' (note the dash)."
  echo "You may want to uninstall 'swiftformat' to avoid confusion."
fi

# Check Swift version >= 6.0
check_swift_version() {
  if ! command -v swift >/dev/null 2>&1; then
    echo "❌ Swift is not installed."
    return 1
  fi

  SWIFT_VERSION=$(swift --version | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
  if [[ -z "$SWIFT_VERSION" ]]; then
    echo "❌ Unable to determine Swift version."
    return 1
  fi

  # Compare versions (only major.minor)
  SWIFT_MAJOR=$(echo "$SWIFT_VERSION" | cut -d. -f1)
  SWIFT_MINOR=$(echo "$SWIFT_VERSION" | cut -d. -f2)

  if (( SWIFT_MAJOR > 6 )); then
    return 0
  elif (( SWIFT_MAJOR == 6 )) && (( SWIFT_MINOR >= 0 )); then
    return 0
  else
    echo "❌ Swift version $SWIFT_VERSION detected, but >= 6.0 required."
    return 1
  fi
}

# Install Swift
install_swift() {
  echo "📦 Installing Swift 6..."

  if $IS_MACOS; then
    SWIFT_URL="https://swift.org/builds/swift-6.0-release/macos/swift-6.0-RELEASE/swift-6.0-RELEASE-macos.tar.gz"
  elif $IS_UBUNTU; then
    SWIFT_URL="https://swift.org/builds/swift-6.0-release/ubuntu2004/swift-6.0-RELEASE/swift-6.0-RELEASE-ubuntu20.04.tar.gz"
  else
    echo "❌ Unsupported OS for Swift installation."
    exit 1
  fi

  TMP_DIR=$(mktemp -d)
  echo "📥 Downloading Swift 6 from $SWIFT_URL..."
  curl -L "$SWIFT_URL" -o "$TMP_DIR/swift.tar.gz"

  echo "📂 Extracting Swift..."
  sudo tar -xzf "$TMP_DIR/swift.tar.gz" -C /usr/local/
  
  # The extracted folder is named like swift-6.0-RELEASE-<platform>
  # Find the extracted folder:
  EXTRACTED_DIR=$(tar -tzf "$TMP_DIR/swift.tar.gz" | head -1 | cut -f1 -d"/")
  
  if [[ -z "$EXTRACTED_DIR" ]]; then
    echo "❌ Failed to find extracted Swift directory."
    exit 1
  fi

  echo "🔧 Creating symlink /usr/local/swift-6 -> /usr/local/$EXTRACTED_DIR"
  sudo ln -sfn "/usr/local/$EXTRACTED_DIR" /usr/local/swift-6

  echo "🔧 Linking swift binary to /usr/local/bin/swift"
  sudo ln -sf /usr/local/swift-6/usr/bin/swift /usr/local/bin/swift

  rm -rf "$TMP_DIR"

  echo "✅ Swift 6 installed successfully."
}

install_swift_format() {
  if command -v swift-format >/dev/null 2>&1; then
    echo "✅ swift-format already installed"
    return
  fi

  echo "📦 Installing swift-format..."

  if $IS_MACOS; then
    if ! command -v brew >/dev/null 2>&1; then
      echo "❌ Homebrew not found. Please install Homebrew first: https://brew.sh"
      exit 1
    fi
    brew install swift-format

  elif $IS_UBUNTU; then
    # swift must be installed (checked earlier)
    TMP_DIR=$(mktemp -d)
    echo "📥 Cloning swift-format repository from Apple..."
    git clone https://github.com/apple/swift-format.git "$TMP_DIR"
    cd "$TMP_DIR"

    echo "⚙️ Building swift-format..."
    swift build -c release

    echo "📦 Installing swift-format to /usr/local/bin"
    sudo cp -f .build/release/swift-format /usr/local/bin/
    sudo chmod +x /usr/local/bin/swift-format

    echo "🧹 Cleaning up..."
    cd -
    rm -rf "$TMP_DIR"
  fi
}

# Main bootstrap flow

if ! check_swift_version; then
  install_swift
fi

install_swift_format

echo "✅ Environment setup complete!"

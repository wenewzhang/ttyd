#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Extract version number
VERSION=$(grep -oP 'project\(.*VERSION \K[0-9.]+' CMakeLists.txt || echo "1.7.7")

# Determine architecture
if command -v dpkg >/dev/null 2>&1; then
    ARCH=$(dpkg --print-architecture)
else
    MACHINE=$(uname -m)
    case "$MACHINE" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="armhf" ;;
        i686)    ARCH="i386" ;;
        *)       ARCH="$MACHINE" ;;
    esac
fi

# Check required tools
for tool in cmake make dpkg-deb; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: Required tool '$tool' not found"
        if [ -f /etc/debian_version ]; then
            echo "Please run: sudo apt-get install cmake build-essential dpkg-dev"
        elif [ -f /etc/arch-release ] || [ -f /etc/manjaro-release ]; then
            echo "Please run: sudo pacman -S cmake make dpkg"
        fi
        exit 1
    fi
done

# Check build dependencies (informational only)
check_build_dep() {
    local pkg="$1"
    local deb_pkg="$2"
    local arch_pkg="$3"
    
    if ! pkg-config --exists "$pkg" 2>/dev/null; then
        if [ -f /etc/debian_version ]; then
            echo "Warning: Missing build dependency '$pkg', please run: sudo apt-get install $deb_pkg"
        else
            echo "Warning: Missing build dependency '$pkg', please run: sudo pacman -S $arch_pkg"
        fi
        MISSING_DEPS=1
    fi
}

MISSING_DEPS=0
check_build_dep "libwebsockets" "libwebsockets-dev" "libwebsockets"
check_build_dep "json-c" "libjson-c-dev" "json-c"
check_build_dep "libuv" "libuv1-dev" "libuv"
check_build_dep "zlib" "zlib1g-dev" "zlib"
check_build_dep "openssl" "libssl-dev" "openssl"

if [ "$MISSING_DEPS" -eq 1 ]; then
    echo "Please install the above dependencies and try again."
    exit 1
fi

BUILD_DIR="${SCRIPT_DIR}/build"
STAGING_DIR=$(mktemp -d)

# Clean and build
echo "==> Configuring project..."
rm -rf "${BUILD_DIR}"
cmake -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    .

echo "==> Building project..."
cmake --build "${BUILD_DIR}" -j"$(nproc)"

# Install to staging
echo "==> Installing to temporary directory..."
DESTDIR="${STAGING_DIR}" cmake --install "${BUILD_DIR}"

# Install systemd service file
mkdir -p "${STAGING_DIR}/usr/lib/systemd/system"
cp "${SCRIPT_DIR}/ttyd.service" "${STAGING_DIR}/usr/lib/systemd/system/ttyd.service"

# Create DEBIAN directory
mkdir -p "${STAGING_DIR}/DEBIAN"

# Create postinst script to enable service on install
cat > "${STAGING_DIR}/DEBIAN/postinst" << 'POSTINST_EOF'
#!/bin/bash
set -e
if [ "$1" = "configure" ] || [ "$1" = "install" ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable ttyd.service >/dev/null 2>&1 || true
fi
POSTINST_EOF
chmod 755 "${STAGING_DIR}/DEBIAN/postinst"

# Create prerm script to disable service on remove
cat > "${STAGING_DIR}/DEBIAN/prerm" << 'PRERM_EOF'
#!/bin/bash
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    systemctl disable ttyd.service >/dev/null 2>&1 || true
fi
PRERM_EOF
chmod 755 "${STAGING_DIR}/DEBIAN/prerm"

# Create postrm script to clean up on remove
cat > "${STAGING_DIR}/DEBIAN/postrm" << 'POSTRM_EOF'
#!/bin/bash
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
fi
POSTRM_EOF
chmod 755 "${STAGING_DIR}/DEBIAN/postrm"

# Try to generate dependencies using dpkg-shlibdeps
DEPENDS=""
if command -v dpkg-shlibdeps >/dev/null 2>&1; then
    echo "==> Attempting to auto-detect shared library dependencies..."
    mkdir -p "${STAGING_DIR}/debian"
    touch "${STAGING_DIR}/debian/control"
    if (cd "${STAGING_DIR}" && dpkg-shlibdeps -O "usr/bin/ttyd" > "${STAGING_DIR}/shlibs.out" 2>/dev/null); then
        DEPENDS=$(grep -oP 'shlibs:Depends=\K.*' "${STAGING_DIR}/shlibs.out" || true)
    fi
    rm -rf "${STAGING_DIR}/debian" "${STAGING_DIR}/shlibs.out"
fi

# If auto-detection fails, use ldd + mapping fallback
if [ -z "$DEPENDS" ]; then
    echo "==> Using ldd fallback to detect dependencies..."
    BINARY="${STAGING_DIR}/usr/bin/ttyd"
    if [ -f "$BINARY" ]; then
        map_lib() {
            case "$1" in
                libwebsockets*) echo "libwebsockets20 | libwebsockets19 | libwebsockets18 | libwebsockets17 | libwebsockets16 | libwebsockets15" ;;
                libjson-c*)     echo "libjson-c5 | libjson-c3" ;;
                libuv*)         echo "libuv1" ;;
                libssl*|libcrypto*) echo "libssl3 | libssl3t64 | libssl1.1" ;;
                libz*)          echo "zlib1g" ;;
                libcap*)        echo "libcap2" ;;
            esac
        }

        DEPS_ARR=()
        LIBS=$(ldd "$BINARY" 2>/dev/null | awk '{print $1}' | grep -v '^$' | grep -E '^lib' || true)
        for lib in $LIBS; do
            pkg=$(map_lib "$lib")
            if [ -n "$pkg" ]; then
                found=0
                for d in "${DEPS_ARR[@]}"; do
                    if [ "$d" = "$pkg" ]; then found=1; break; fi
                done
                if [ "$found" -eq 0 ]; then
                    DEPS_ARR+=("$pkg")
                fi
            fi
        done

        if [ ${#DEPS_ARR[@]} -gt 0 ]; then
            DEPENDS=$(IFS=', '; echo "${DEPS_ARR[*]}")
        fi
    fi
fi

if [ -n "$DEPENDS" ]; then
    echo "==> Detected runtime dependencies: ${DEPENDS}"
fi

# Calculate installed size (KB)
INSTALLED_SIZE=$(du -sk "${STAGING_DIR}" | cut -f1)

cat > "${STAGING_DIR}/DEBIAN/control" << CONTROL_EOF
Package: ttyd
Version: ${VERSION}
Section: net
Priority: optional
Architecture: ${ARCH}
Depends: ${DEPENDS}
Maintainer: ttyd <ttyd@example.com>
Description: Share your terminal over the web
 ttyd is a simple command-line tool for sharing terminal over the web.
CONTROL_EOF

DEB_NAME="ttyd_${VERSION}_${ARCH}.deb"

echo "==> Building deb package: ${DEB_NAME}"
dpkg-deb --root-owner-group --build "${STAGING_DIR}" "${DEB_NAME}"

# Cleanup
rm -rf "${STAGING_DIR}"

echo "==> Successfully generated: ${DEB_NAME}"

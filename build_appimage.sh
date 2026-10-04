#!/bin/bash
set -e

# Script to build Magic Sand AppImage compatible with Ubuntu 16.04+ using Docker
# This script creates a Dockerfile, an internal build script, and then runs Docker.

echo "Generating Dockerfile..."
cat << 'DOCKER_EOF' > Dockerfile.build
FROM ubuntu:16.04

# Avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
# We use apt-get instead of apt for better compatibility in scripts
RUN apt-get update && apt-get install -y \
    wget \
    curl \
    git \
    build-essential \
    pkg-config \
    sudo \
    fuse \
    file \
    imagemagick \
    software-properties-common \
    && rm -rf /var/lib/apt/lists/*

# Install openFrameworks 0.9.3
WORKDIR /opt
RUN wget -q https://openframeworks.cc/versions/v0.9.3/of_v0.9.3_linux64_release.tar.gz && \
    tar -xzf of_v0.9.3_linux64_release.tar.gz && \
    mv of_v0.9.3_linux64_release of && \
    rm of_v0.9.3_linux64_release.tar.gz

WORKDIR /opt/of/scripts/linux/ubuntu
RUN sudo ./install_dependencies.sh -y && \
    sudo ./install_codecs.sh -y || true

WORKDIR /opt/of/libs/openFrameworksCompiled/project
RUN make -j$(nproc)

# Download addons required by Magic Sand
WORKDIR /opt/of/addons
RUN git clone -b stable https://github.com/kylemcdonald/ofxCv.git && \
    git clone https://github.com/braitsch/ofxParagraph.git && \
    git clone https://github.com/thomwolf/ofxDatGui.git && \
    git clone https://github.com/braitsch/ofxModal.git

# Download linuxdeploy and appimagetool
WORKDIR /opt/appimage
RUN wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage && \
    chmod +x linuxdeploy-x86_64.AppImage
RUN wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage && \
    chmod +x appimagetool-x86_64.AppImage

WORKDIR /workspace

CMD ["/workspace/build_inside_docker.sh"]
DOCKER_EOF

echo "Generating internal build script..."
cat << 'DOCKER_EOF' > build_inside_docker.sh
#!/bin/bash
set -e

# Set OF_ROOT so the Makefile knows where openFrameworks is installed
export OF_ROOT=/opt/of

# Clean any stale/partial object files from previous runs
rm -rf obj

echo "Compiling Magic-Sand..."
# Explicitly set APPNAME so openFrameworks outputs bin/Magic-Sand instead of bin/workspace
make APPNAME=Magic-Sand -j$(nproc)

# Fallback check if the binary was named bin/workspace
if [ -f bin/workspace ] && [ ! -f bin/Magic-Sand ]; then
    mv bin/workspace bin/Magic-Sand
fi

echo "Preparing AppDir..."
mkdir -p AppDir/usr/bin
mkdir -p AppDir/usr/share/applications
mkdir -p AppDir/usr/share/icons/hicolor/256x256/apps

# Copy the compiled executable
cp bin/Magic-Sand AppDir/usr/bin/

# Copy the data folder to be alongside the executable in the AppDir
# openFrameworks apps look for 'data' in the current working directory relative to the executable.
# It is best to just copy bin/data to the same location as Magic-Sand in the AppDir.
cp -r bin/data AppDir/usr/bin/

# Provide an icon and a desktop entry
# We will just copy a default icon or create a dummy if there isn't a simple PNG.
# Magic Sand repo has icon.icns and icon.ico. 
# We'll create a simple desktop file and assume linuxdeploy will package it properly.
echo "[Desktop Entry]" > AppDir/usr/share/applications/magicsand.desktop
echo "Name=Magic Sand" >> AppDir/usr/share/applications/magicsand.desktop
echo "Exec=Magic-Sand" >> AppDir/usr/share/applications/magicsand.desktop
echo "Icon=magicsand" >> AppDir/usr/share/applications/magicsand.desktop
echo "Type=Application" >> AppDir/usr/share/applications/magicsand.desktop
echo "Categories=Game;Education;" >> AppDir/usr/share/applications/magicsand.desktop

# Extract 256x256 PNG icon from icon.ico (frame [5]) if available, else first frame
convert /workspace/icon.ico[5] AppDir/usr/share/icons/hicolor/256x256/apps/magicsand.png 2>/dev/null || \
convert /workspace/icon.ico[0] AppDir/usr/share/icons/hicolor/256x256/apps/magicsand.png

echo "Running linuxdeploy to gather dependencies..."
# We use APPIMAGE_EXTRACT_AND_RUN=1 because FUSE is sometimes problematic in Docker
export APPIMAGE_EXTRACT_AND_RUN=1
/opt/appimage/linuxdeploy-x86_64.AppImage --appdir AppDir -d AppDir/usr/share/applications/magicsand.desktop -i AppDir/usr/share/icons/hicolor/256x256/apps/magicsand.png -e AppDir/usr/bin/Magic-Sand

# Build compatibility shim for Wayland / XWayland
# GLFW 3.1 (used in OF 0.9.3) crashes with SIGSEGV on Wayland/XWayland because XkbGetKeyboard returns NULL.
# Intercepting XkbQueryExtension under Wayland safely enables GLFW's standard X11 keyboard fallback.
echo "Building Wayland/XWayland compatibility shim..."
cat << 'EOF' > /tmp/xwayland_fix.c
#define _GNU_SOURCE
#include <X11/Xlib.h>
#include <X11/XKBlib.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

static Bool (*real_XkbQueryExtension)(Display *, int *, int *, int *, int *, int *) = NULL;

Bool XkbQueryExtension(Display *dpy, int *opcode_rtrn, int *event_rtrn, int *error_rtrn, int *major_in_out, int *minor_in_out) {
    const char *wayland_display = getenv("WAYLAND_DISPLAY");
    const char *session_type = getenv("XDG_SESSION_TYPE");
    if (wayland_display || (session_type && strcmp(session_type, "wayland") == 0)) {
        return False;
    }
    if (!real_XkbQueryExtension) {
        real_XkbQueryExtension = dlsym(RTLD_NEXT, "XkbQueryExtension");
    }
    if (real_XkbQueryExtension) {
        return real_XkbQueryExtension(dpy, opcode_rtrn, event_rtrn, error_rtrn, major_in_out, minor_in_out);
    }
    return False;
}
EOF
gcc -shared -fPIC -O2 -o AppDir/usr/lib/libxwayland_fix.so /tmp/xwayland_fix.c -ldl
rm -f /tmp/xwayland_fix.c

# Create custom AppRun script to ensure correct LD_LIBRARY_PATH, data folder working directory, and preload
rm -f AppDir/AppRun
cat << 'APPRUN_EOF' > AppDir/AppRun
#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"
export APPDIR="$HERE"
export PATH="$HERE/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HERE/usr/lib:$LD_LIBRARY_PATH"

if [ -f "$HERE/usr/lib/libxwayland_fix.so" ]; then
    export LD_PRELOAD="$HERE/usr/lib/libxwayland_fix.so${LD_PRELOAD:+:$LD_PRELOAD}"
fi

cd "$HERE/usr/bin"
exec "$HERE/usr/bin/Magic-Sand" "$@"
APPRUN_EOF
chmod +x AppDir/AppRun

echo "Running appimagetool to create the final AppImage..."
export APPIMAGE_EXTRACT_AND_RUN=1
/opt/appimage/appimagetool-x86_64.AppImage AppDir Magic-Sand-x86_64.AppImage
mv Magic-Sand-x86_64.AppImage /workspace/
chmod 777 /workspace/Magic-Sand-x86_64.AppImage

echo "AppImage created successfully!"
DOCKER_EOF
chmod +x build_inside_docker.sh

echo "Building Docker image (this will take a while)..."
docker build -t magic-sand-appimage-builder -f Dockerfile.build .

echo "Running Docker container to build AppImage..."
# We mount the current directory and run the build script.
# --privileged is used to allow AppImage execution inside Docker if needed.
docker run --rm -v "$(pwd):/workspace" --privileged magic-sand-appimage-builder

echo "Cleaning up build scripts..."
rm Dockerfile.build build_inside_docker.sh

echo "Build process finished. You should find Magic-Sand-x86_64.AppImage in your current directory."

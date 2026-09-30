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
RUN git clone https://github.com/kylemcdonald/ofxCv.git && \
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

echo "Compiling Magic-Sand..."
make -j$(nproc)

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

# Create a dummy icon since we don't have a PNG readily available.
touch AppDir/usr/share/icons/hicolor/256x256/apps/magicsand.png

echo "Running linuxdeploy to gather dependencies..."
# We use APPIMAGE_EXTRACT_AND_RUN=1 because FUSE is sometimes problematic in Docker
export APPIMAGE_EXTRACT_AND_RUN=1
/opt/appimage/linuxdeploy-x86_64.AppImage --appdir AppDir -d AppDir/usr/share/applications/magicsand.desktop -i AppDir/usr/share/icons/hicolor/256x256/apps/magicsand.png -e AppDir/usr/bin/Magic-Sand

echo "Running appimagetool to create the final AppImage..."
export APPIMAGE_EXTRACT_AND_RUN=1
/opt/appimage/appimagetool-x86_64.AppImage AppDir Magic-Sand-x86_64.AppImage
mv Magic-Sand-x86_64.AppImage /workspace/

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

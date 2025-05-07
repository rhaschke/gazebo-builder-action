#!/bin/bash -e

docker build --progress=plain -t gazebo-builder-action .
docker run --privileged -e DEB_DIR="$(pwd)/deb" -v "$(pwd)/deb:$(pwd)/deb" --rm -it gazebo-builder-action

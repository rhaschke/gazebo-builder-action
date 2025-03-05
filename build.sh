#!/bin/bash -e

export DEBIAN_FRONTEND=noninteractive

BUILD_PARALLEL_JOBS="${BUILD_PARALLEL_JOBS:-$(nproc)}"
THIS_DIR="$(builtin cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
SRC_DIR="${THIS_DIR}/src"
DEB_DIR="${DEB_DIR:-${THIS_DIR}/deb}"
REPOS_FILE="${REPOS_FILE:-${THIS_DIR}/gazebo-$(lsb_release -rs).repos}"
CCACHE_DIR="${CCACHE_DIR:-.ccache}"

. "${THIS_DIR}/utils.sh"

install_apt_dependencies() {
  ici_cmd ici_asroot apt-get update -qq
  ici_cmd ici_asroot apt-get install -y -qq --no-install-recommends \
          build-essential \
          ccache \
          cmake \
          cppzmq-dev \
          curl \
          debhelper \
          doxygen \
          git \
          libavcodec-dev \
          libavdevice-dev \
          libavfilter-dev \
          libavformat-dev \
          libavutil-dev \
          libboost-all-dev \
          libbullet-dev \
          libccd-dev \
          libeigen3-dev \
          libfreeimage-dev \
          libgoogle-perftools-dev \
          libgts-dev \
          libhdf5-dev \
          libjsoncpp-dev \
          libogre-1.9-dev \
          libopenal-dev \
          libpostproc-dev \
          libprotobuf-dev \
          libprotoc-dev \
          libqt5opengl5-dev \
          libqwt-headers \
          libswresample-dev \
          libswscale-dev \
          libtar-dev \
          libtbb-dev \
          libtinyxml-dev \
          libtinyxml2-dev \
          libusb-dev \
          libzip-dev \
          lsb-release \
          ninja-build \
          protobuf-compiler \
          pybind11-dev \
          python3-full \
          python3-psutil \
          qtbase5-dev \
          ssh \
          uuid-dev
}

install_python_dependencies() {
  ici_cmd ici_asroot pip3 install --no-cache-dir \
          vcstool
}

configure_ccache() {
  local ccache_dir="$(readlink -f $1)"
  ici_cmd mkdir -p "${ccache_dir}"
  ici_cmd ccache -o cache_dir="${ccache_dir}"
  ici_cmd ccache -sv
}

import_repos() {
  local repos_file="$(readlink -f $1)"
  local src_dir="$(readlink -f $2)"
  if [ ! -e "${repos_file}" ]; then
    gha_error "${repos_file} does not exist" 1
  fi
  mkdir "${src_dir}"
  ici_cmd vcs import --shallow --recursive --force --input "${repos_file}" "${src_dir}"
}

build_install_repo() {
  local project_dir="$(readlink -f $1)"
  local deb_dir="$(readlink -f $2)"
  local build_parallel_jobs="$3"
  local install="$4"
  cd "${project_dir}"
  rm -rf build && mkdir build && cd build
  ici_cmd cmake \
          -G Ninja \
          -DBUILD_DOCS=OFF \
          -DBUILD_TESTING=OFF \
          -DCMAKE_INSTALL_PREFIX=/usr \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
          -DCMAKE_C_COMPILER_LAUNCHER=ccache \
          ..
  ici_cmd cmake --build . -j "${build_parallel_jobs}"
  ici_cmd cpack -G DEB
  local deb_files="$(find . -maxdepth 1 -type f -name '*.deb')"
  mkdir -p "${deb_dir}"
  ici_cmd cp -f ${deb_files} "${deb_dir}/"
  if [ "${install}" = "true" ]; then
    ici_cmd ici_asroot apt install -y -qq ${deb_files}
  fi
}

main() {
  ici_timed "$(ici_colorize CYAN BOLD "Installing Apt dependencies")" install_apt_dependencies

  ici_timed "$(ici_colorize CYAN BOLD "Install Python dependencies")" install_python_dependencies

  ici_timed "$(ici_colorize CYAN BOLD "Importing repositories")" import_repos "${REPOS_FILE}" "${SRC_DIR}"

  BUILD_REPOS="$(yq '.repositories | keys | .[]' "${REPOS_FILE}")"

  ici_timed "$(ici_colorize CYAN BOLD "Configure ccache")" configure_ccache "${CCACHE_DIR}"

  ici_log "Building repositories: ${BUILD_REPOS}"

  for repo in ${BUILD_REPOS}; do
    local install=true
    if [ "${repo}" = "gazebo" ]; then
      install=false
    fi
    ici_timed "$(ici_colorize CYAN BOLD "Building ${repo}")" build_install_repo "${SRC_DIR}/${repo}" "${DEB_DIR}" "${BUILD_PARALLEL_JOBS}" "${install}"
  done
}

main "$@"

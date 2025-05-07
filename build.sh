#!/bin/bash -e

export DEBIAN_FRONTEND=noninteractive

OS_DISTRO="${OS_DISTRO:-$(lsb_release -cs)}"
BUILD_PARALLEL_JOBS="${BUILD_PARALLEL_JOBS:-$(nproc --ignore 2)}"
THIS_DIR="$(builtin cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
SRC_DIR="${THIS_DIR}/src"
DEB_DIR="${DEB_DIR:-${THIS_DIR}/deb}"
_REPOS_FILE="${REPOS_FILE:-${THIS_DIR}/gazebo-${OS_DISTRO}.repos}"
REPOS_FILE="$(readlink -f "${_REPOS_FILE}")"
_CCACHE_DIR="${CCACHE_DIR:-${THIS_DIR}/.ccache}"
CCACHE_DIR="$(readlink -f "${_CCACHE_DIR}")"
APT_CACHE_PORT="${APT_CACHE_PORT:-3142}"

. "${THIS_DIR}/utils.sh"

install_apt_dependencies() {
  ici_cmd ici_asroot apt-get update -qq
  ici_cmd "${APT_QUIET[@]}" ici_apt_install \
          ccache \
          curl \
          distro-info-data \
          git \
          mmdebstrap \
          netcat-openbsd \
          python3-full \
          python3-pip \
          sbuild \
          schroot \
          squid-deb-proxy \
          sudo \
          which
}

install_python_dependencies() {
  ici_cmd ici_asroot pip3 install --no-cache-dir \
          vcstool
}

install_yq() {
  # Download yq binary
  ici_cmd ici_asroot curl -o /usr/local/bin/yq -sSfL "https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_$(dpkg --print-architecture)"
  ici_cmd ici_asroot chmod +x /usr/local/bin/yq
  ici_cmd yq --version
}

start_apt_cache_proxy_server() {
  if [ ! -e /etc/init.d/squid-deb-proxy ]; then
    ici_log "squid-deb-proxy is not installed"
    return
  fi

  # Allow caching any apt repository
  ici_asroot sed -i 's/^[^#]*http_access deny !to_archive_mirrors/http_access allow !to_archive_mirrors/g' /etc/squid-deb-proxy/squid-deb-proxy.conf
  ici_asroot sed -i 's/^[^#]*cache deny !to_archive_mirrors/cache allow !to_archive_mirrors/g' /etc/squid-deb-proxy/squid-deb-proxy.conf
  ici_asroot sed -i "s/^[^#]*http_port .*$/http_port ${APT_CACHE_PORT}/g" /etc/squid-deb-proxy/squid-deb-proxy.conf


  for _ in $(seq 1 5); do
    ici_cmd ici_asroot /etc/init.d/squid-deb-proxy start
    ici_log "Waiting for apt cache proxy server"
    sleep 5
    if nc -w1 -z localhost "${APT_CACHE_PORT}"; then
      ici_log "Detected apt cache proxy server"
      break
    fi
    ici_cmd ici_asroot /etc/init.d/squid-deb-proxy stop
  done
}

create_chroot() {
  if [ -d /var/cache/sbuild-chroot ] && [ -f /etc/schroot/chroot.d/sbuild ]; then
    echo "chroot already exists"
    return
  fi

  local chroot_tar_file="/var/cache/sbuild-chroot.tar"

  local mmdebstrap_options=(
    '--verbose'
    '--variant=buildd'
    '--aptopt=Acquire::Retries "10"'
    '--components=main,universe'
    '--include=apt,ca-certificates,ccache,eatmydata'
    '--customize-hook=rm -f $1/etc/resolv.conf'
    '--customize-hook=echo localhost > $1/etc/hostname'
    '--customize-hook=echo 127.0.0.1 localhost >> $1/etc/hosts'
    '--customize-hook=chroot "$1" update-ccache-symlinks'
  )

  if nc -w1 -z localhost "${APT_CACHE_PORT}"; then
    ici_log "Detected apt cache proxy server"
    mmdebstrap_options+=(
      '--aptopt=Acquire::http::Proxy "http://127.0.0.1:'"${APT_CACHE_PORT}"'"'
    )
  fi

  # shellcheck disable=SC2016
  ici_cmd ici_asroot mmdebstrap \
          "${mmdebstrap_options[@]}" \
          "${OS_DISTRO}" \
          "$chroot_tar_file"
  ici_log
  ici_color_output BOLD "Write schroot config"
  local sbuild_chroot_name="${OS_DISTRO}-$(dpkg --print-architecture)-sbuild"
  cat <<- EOF | ici_asroot tee "/etc/schroot/chroot.d/${sbuild_chroot_name}"
[${sbuild_chroot_name}]
groups=root,sbuild
root-groups=root,sbuild
profile=sbuild
type=file
file=${chroot_tar_file}
command-prefix=eatmydata
EOF

  ici_log
  ici_color_output BOLD "Add mount points to sbuild's fstab"
  cat <<- EOF | ici_asroot tee -a /etc/schroot/sbuild/fstab
$CCACHE_DIR  /build/ccache   none    rw,bind         0       0
EOF
}

configure_sbuildrc() {
  if [ "$EUID" -ne 0 ]; then
    ici_cmd ici_asroot usermod -a -G sbuild "$USER"
    ici_cmd ici_asroot newgrp sbuild
  fi
  # https://wiki.ubuntu.com/SimpleSbuild
  cat << EOF | tee "$HOME/.sbuildrc"
\$build_environment = { 'CCACHE_DIR' => '/build/ccache' };
\$chroot_mode = 'schroot';
\$clean_source = 0;
\$path = '/usr/lib/ccache:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games';
\$dsc_dir = "package";
\$verbose = 1;
\$dpkg_source_opts = ["-Zgzip", "-z1", "--format=1.0", "-sn"];
\$run_autopkgtest = 0;
\$run_lintian = 0;
\$extra_packages = ["${DEB_DIR}"];
EOF
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
  cd "${project_dir}"

  # Check release repositories
  local repo_name="$(basename ${project_dir})"
  local release_repo="$(yq ".release_repositories.${repo_name} | {\"repositories\": {\"release\": .}}" "${REPOS_FILE}")"
  if [ -n "${release_repo}" ]; then
    ici_log "Found release repository: ${release_repo}"
    echo "${release_repo}" | ici_cmd vcs import
    if [ -d "release/${OS_DISTRO}/debian" ]; then
      ici_cmd cp -r --dereference "release/${OS_DISTRO}/debian" debian
    fi
  fi

  local sbuild_options="--build-dir ${deb_dir} --jobs ${build_parallel_jobs}"
  if [ "$EUID" -ne 0 ]; then
    ici_label "${SBUILD_QUIET[@]}" ici_asroot -E -H -u "$USER" bash -lc "sbuild ${sbuild_options}"  || return 1
  else
    ici_label "${SBUILD_QUIET[@]}" sbuild "${sbuild_options}" || return 1
  fi
}

main() {
  ici_setup_vars "${VERBOSE:-}" "${DEFAULT_QUIET_CONFIG[@]}"

  ici_start_fold "Variables"
  cat <<EOF
OS_DISTRO=${OS_DISTRO}
REPOS_FILE=${REPOS_FILE}
SRC_DIR=${SRC_DIR}
DEB_DIR=${DEB_DIR}
BUILD_PARALLEL_JOBS=${BUILD_PARALLEL_JOBS}
APT_CACHE_PORT=${APT_CACHE_PORT}
EOF
  ici_end_fold

  ici_timed "$(ici_colorize CYAN BOLD "Installing Apt dependencies")" install_apt_dependencies

  ici_timed "$(ici_colorize CYAN BOLD "Install Python dependencies")" install_python_dependencies

  ici_timed "$(ici_colorize CYAN BOLD "Install yq")" install_yq

  ici_timed "$(ici_colorize CYAN BOLD "Importing repositories")" import_repos "${REPOS_FILE}" "${SRC_DIR}"

  BUILD_REPOS="$(yq -r '.repositories | keys | .[]' "${REPOS_FILE}")"

  ici_timed "$(ici_colorize CYAN BOLD "Configure ccache")" configure_ccache "${CCACHE_DIR}"

  ici_timed "$(ici_colorize CYAN BOLD "Start apt cache proxy server")" start_apt_cache_proxy_server

  ici_timed "$(ici_colorize CYAN BOLD "Configure ~/.sbuildrc")" configure_sbuildrc
  ici_timed "$(ici_colorize CYAN BOLD "Create sbuild chroot")" create_chroot

  ici_log "Creating DEB_DIR"
  ici_cmd mkdir -p "${DEB_DIR}"

  ici_log "Building repositories: ${BUILD_REPOS}"

  for repo in ${BUILD_REPOS}; do
    ici_timed "$(ici_colorize CYAN BOLD "Building ${repo}")" build_install_repo "${SRC_DIR}/${repo}" "${DEB_DIR}" "${BUILD_PARALLEL_JOBS}" || return 1
  done
}

main "$@"


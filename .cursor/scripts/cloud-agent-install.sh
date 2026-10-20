#!/usr/bin/env bash
set -euo pipefail

# Prepare kernel headers and build tooling for NVIDIA open GPU kernel modules.
# Cloud Agent VMs use a custom 6.12.x kernel without distro header packages.

KERNEL_SOURCE_VERSION="${KERNEL_SOURCE_VERSION:-6.12.94}"
KERNEL_SOURCE_DIR="/usr/src/linux-${KERNEL_SOURCE_VERSION}"
KERNEL_TARBALL_URL="https://codeload.github.com/gregkh/linux/tar.gz/refs/tags/v${KERNEL_SOURCE_VERSION}"
KREL="$(uname -r)"
MODULE_BUILD_LINK="/lib/modules/${KREL}/build"

export DEBIAN_FRONTEND=noninteractive

apt_packages=(
  build-essential
  bc
  bison
  flex
  libssl-dev
  libelf-dev
  dwarves
  curl
  ca-certificates
)

need_apt=0
for pkg in "${apt_packages[@]}"; do
  if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
    need_apt=1
    break
  fi
done
if [[ "${need_apt}" -eq 1 ]]; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq "${apt_packages[@]}"
fi

if [[ ! -f "${KERNEL_SOURCE_DIR}/Makefile" ]]; then
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT
  curl -fsSL -o "${tmpdir}/linux.tar.gz" "${KERNEL_TARBALL_URL}"
  tar xzf "${tmpdir}/linux.tar.gz" -C "${tmpdir}"
  extracted="$(find "${tmpdir}" -maxdepth 1 -type d -name 'linux-*' | head -1)"
  sudo rm -rf "${KERNEL_SOURCE_DIR}"
  sudo mv "${extracted}" "${KERNEL_SOURCE_DIR}"
fi

if [[ ! -f "${KERNEL_SOURCE_DIR}/.config" ]]; then
  if [[ ! -f /proc/config.gz ]]; then
    echo "cloud-agent-install: /proc/config.gz is required to match the running kernel" >&2
    exit 1
  fi
  zcat /proc/config.gz | sudo tee "${KERNEL_SOURCE_DIR}/.config" >/dev/null
  sudo make -C "${KERNEL_SOURCE_DIR}" olddefconfig
fi

if [[ ! -f "${KERNEL_SOURCE_DIR}/include/generated/utsrelease.h" ]]; then
  sudo make -C "${KERNEL_SOURCE_DIR}" modules_prepare -j"$(nproc)"
fi

symvers_ok() {
  [[ -f "${KERNEL_SOURCE_DIR}/Module.symvers" ]] &&
    grep -qE $'\tEXPORT_SYMBOL\t' "${KERNEL_SOURCE_DIR}/Module.symvers"
}

if ! symvers_ok; then
  sudo make -C "${KERNEL_SOURCE_DIR}" modules -j"$(nproc)"
fi

sudo mkdir -p "/lib/modules/${KREL}"
sudo ln -sfn "${KERNEL_SOURCE_DIR}" "${MODULE_BUILD_LINK}"

if [[ -f /workspace/Makefile ]]; then
  make -C /workspace modules -j"$(nproc)"
fi

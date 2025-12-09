
#!/usr/bin/env bash
set -euo pipefail

# Build a Debian package from a SystemRescue ISO kernel + modules.
# Tested on Debian Trixie (amd64).
#
# Usage:
#   sudo ./sysresccd-kernel-to-deb.sh /path/to/systemrescue-*.iso [OUTPUT_DIR]
#
# Result:
#   OUTPUT_DIR/linux-image-<kver>-sysrescue_1~local_<arch>.deb
#
# Requirements: sudo, mount (iso9660 + squashfs), dpkg-deb, coreutils, kmod,
#               initramfs-tools, update-grub. For squashfs mount, ensure the
#               kernel has squashfs support (module or built-in).
#
# Notes:
# - We copy the kernel image to /boot/vmlinuz-<kver>-sysrescue.
# - We copy the modules to /lib/modules/<kver> and run depmod.
# - We generate a Debian initramfs via update-initramfs.
# - We update GRUB so you can boot the new kernel.
# - Secure Boot: this kernel is not signed; disable Secure Boot or sign it.

ISO="${1:-}"
OUT="${2:-$PWD}"

if [[ -z "${ISO}" || ! -f "${ISO}" ]]; then
  echo "Usage: sudo $0 /path/to/systemrescue-*.iso [OUTPUT_DIR]" >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

ARCH="$(dpkg --print-architecture)"           # e.g. amd64
HOST_MACH="$(uname -m)"                       # e.g. x86_64
WORK="$(mktemp -d)"
MNT_ISO="${WORK}/mnt_iso"
MNT_SFS="${WORK}/mnt_sfs"
PKGROOT="${WORK}/pkg"
DEBCTRL="${PKGROOT}/DEBIAN"

mkdir -p "${MNT_ISO}" "${MNT_SFS}" "${DEBCTRL}"

cleanup() {
  set +e
  mountpoint -q "${MNT_SFS}" && umount "${MNT_SFS}"
  mountpoint -q "${MNT_ISO}" && umount "${MNT_ISO}"
  rm -rf "${WORK}"
}
trap cleanup EXIT

echo "[+] Mounting ISO: ${ISO}"
mount -o loop -t iso9660 "${ISO}" "${MNT_ISO}"

# Locate vmlinuz and airootfs.sfs inside the ISO.
# SystemRescue layout examples:
#   ISO/sysresccd/boot/x86_64/vmlinuz
#   ISO/sysresccd/boot/i686/vmlinuz
#   ISO/sysresccd/x86_64/airootfs.sfs
#   ISO/sysresccd/i686/airootfs.sfs
# We prefer matching host architecture (x86_64 for amd64).
VMLINUZ_PATH="$(find "${MNT_ISO}" -type f -iname vmlinuz | grep -E 'sysresccd/boot' | head -n1 || true)"
AIROOTFS_PATH="$(find "${MNT_ISO}" -type f -iname airootfs.sfs | grep -E 'sysresccd/(x86_64|i686)' | head -n1 || true)"

if [[ -z "${VMLINUZ_PATH}" ]]; then
  echo "[-] Could not locate vmlinuz inside ISO (expected under sysresccd/boot/*)." >&2
  exit 1
fi
if [[ -z "${AIROOTFS_PATH}" ]]; then
  echo "[-] Could not locate airootfs.sfs inside ISO (expected under sysresccd/*)." >&2
  exit 1
fi

echo "[+] Found kernel: ${VMLINUZ_PATH}"
echo "[+] Found rootfs SFS: ${AIROOTFS_PATH}"

echo "[+] Mounting airootfs.sfs (squashfs)"
# mount needs squashfs support; if missing, apt install squashfs-tools and fallback to unsquashfs.
mount -o loop -t squashfs "${AIROOTFS_PATH}" "${MNT_SFS}" || {
  echo "[-] squashfs mount failed; ensure squashfs is available in your kernel." >&2
  exit 1
}

# Determine kernel version by inspecting modules directory inside the rootfs.
# On Arch/SystemRescue, modules are typically under /usr/lib/modules/<version>.
KVER=""
if [[ -d "${MNT_SFS}/usr/lib/modules" ]]; then
  KVER="$(basename "$(ls -1d "${MNT_SFS}/usr/lib/modules/"* | head -n1)")"
elif [[ -d "${MNT_SFS}/lib/modules" ]]; then
  KVER="$(basename "$(ls -1d "${MNT_SFS}/lib/modules/"* | head -n1)")"
fi

if [[ -z "${KVER}" ]]; then
  echo "[-] Could not determine kernel version from modules directory." >&2
  exit 1
fi
echo "[+] Kernel version: ${KVER}"

# Prepare package filesystem
BOOT_DIR="${PKGROOT}/boot"
MOD_DIR="${PKGROOT}/lib/modules/${KVER}"
mkdir -p "${BOOT_DIR}" "${PKGROOT}/lib/modules"

# Copy kernel image into /boot
cp -a "${VMLINUZ_PATH}" "${BOOT_DIR}/vmlinuz-${KVER}-sysrescue"

# Copy modules tree (from /usr/lib/modules or /lib/modules in the SFS)
if [[ -d "${MNT_SFS}/usr/lib/modules/${KVER}" ]]; then
  cp -a "${MNT_SFS}/usr/lib/modules/${KVER}" "${MOD_DIR}"
elif [[ -d "${MNT_SFS}/lib/modules/${KVER}" ]]; then
  cp -a "${MNT_SFS}/lib/modules/${KVER}" "${MOD_DIR}"
else
  echo "[-] Modules for ${KVER} not found in airootfs." >&2
  exit 1
fi

# Debian control files
PKGNAME="linux-image-${KVER}-sysrescue"
VERSION="${KVER}-1~local"
cat > "${DEBCTRL}/control" <<EOF
Package: ${PKGNAME}
Version: ${VERSION}
Section: kernel
Priority: optional
Architecture: ${ARCH}
Depends: kmod, initramfs-tools (>= 0.140), grub-pc | grub-efi-amd64
Maintainer: local <root@localhost>
Description: Linux kernel extracted from SystemRescue ISO (with modules)
 This package installs /boot/vmlinuz-${KVER}-sysrescue and the matching modules
 under /lib/modules/${KVER}, runs depmod, generates a Debian initramfs, and
 updates GRUB so you can boot it on Debian Trixie.
EOF

# Post-install: depmod, initramfs, update-grub
install -m 0755 /dev/null "${DEBCTRL}/postinst"
cat > "${DEBCTRL}/postinst" <<'EOF'
#!/bin/sh -e
PKGNAME="$(dpkg -s "$DPKG_MAINTSCRIPT_PACKAGE" 2>/dev/null | awk -F': ' '/Package:/ {print $2}')"

# Extract kernel version suffix from package name (linux-image-<kver>-sysrescue)
KVER="$(echo "$PKGNAME" | sed -E 's/^linux-image-(.+)-sysrescue$/\1/')"

echo "Running depmod for ${KVER} ..."
depmod -a "${KVER}" || true

echo "Generating initramfs for ${KVER} ..."
update-initramfs -c -k "${KVER}" || true

# Optional convenience symlinks (like Debian kernel packages do)
ln -sf "/boot/vmlinuz-${KVER}-sysrescue" /vmlinuz || true
ln -sf "/boot/initrd.img-${KVER}"        /initrd.img || true

echo "Updating GRUB ..."
if command -v update-grub >/dev/null 2>&1; then
  update-grub || true
elif command -v grub-mkconfig >/dev/null 2>&1; then
  grub-mkconfig -o /boot/grub/grub.cfg || true
fi

exit 0
EOF

# Post-removal: update-grub
install -m 0755 /dev/null "${DEBCTRL}/postrm"
cat > "${DEBCTRL}/postrm" <<'EOF'
#!/bin/sh -e
echo "Updating GRUB after removal ..."
if command -v update-grub >/dev/null 2>&1; then
  update-grub || true
elif command -v grub-mkconfig >/dev/null 2>&1; then
  grub-mkconfig -o /boot/grub/grub.cfg || true
fi
exit 0
EOF

# Build the package
mkdir -p "${OUT}"
DEB_PATH="${OUT}/${PKGNAME}_1~local_${ARCH}.deb"
echo "[+] Building ${DEB_PATH}"
dpkg-deb --build "${PKGROOT}" "${DEB_PATH}"

echo "[+] Done."
echo "Install with:   sudo dpkg -i '${DEB_PATH}'"
echo "Then verify:    ls -l /boot/vmlinuz-${KVER}-sysrescue /lib/modules/${KVER}"
echo "                grep -E \"^menuentry\" /boot/grub/grub.cfg | sed -n '1,5p'"


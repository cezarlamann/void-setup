#!/usr/bin/env bash
set -euo pipefail

### ====== EDIT ME (DISKS & BASICS) ==========================================
# Root (NVMe) disk -> ESP + LUKS1 for root btrfs
ROOT_DISK="/dev/nvme0n1"
# Data (SATA/SSD) disk -> LUKS1 for data btrfs
DATA_DISK="/dev/sda"

# Partition sizes
ESP_SIZE="1024MiB"   # EFI System Partition size on ROOT_DISK

# change to your desired computer name
HOSTNAME="localhost"

# change to your desired user name
USERNAME="user"
USER_SHELL="/bin/bash"
TZ="Europe/Madrid" # set your timezone here
KEYMAP="br-abnt2" # set your keymap here.
LOCALE="pt_BR.UTF-8 UTF-8" #set your locale here

SWAP_SIZE="40G" # should be RAM * 1.5 for Hibernation

# XBPS repo & arch
REPO="https://repo-fastly.voidlinux.org/current/"
ARCH="x86_64"

### ====== LIVE ISO PREFLIGHT (tools needed before installation) ==============
echo "==> Ensuring required live-ISO tools are present..."
need() { command -v "$1" >/dev/null 2>&1 || xbps-install -Sy "$2"; }

# For downloading and partitioning
need curl curl
need sgdisk gptfdisk
need partprobe parted

# Helper: re-read partition table safely
reread_pt() {
  local disk="$1"
  if command -v partprobe >/dev/null 2>&1; then
    partprobe "$disk" || true
  else
    blockdev --rereadpt "$disk" || true
    command -v udevadm >/dev/null 2>&1 && udevadm settle || true
    sleep 1
  fi
}

### ====== NO EDITS BELOW UNLESS YOU KNOW WHAT YOU'RE DOING ===================

echo "==> Validating disks..."
[[ -b "$ROOT_DISK" ]] || { echo "Root disk not found: $ROOT_DISK"; exit 1; }
[[ -b "$DATA_DISK" ]] || { echo "Data disk not found: $DATA_DISK"; exit 1; }

echo "==> Wiping old signatures..."
wipefs -a "$ROOT_DISK"
wipefs -a "$DATA_DISK"

echo "==> Partitioning $ROOT_DISK (GPT: ESP + root LUKS)..."
sgdisk --zap-all "$ROOT_DISK"
# ESP
sgdisk -n 1:0:+"$ESP_SIZE" -t 1:ef00 -c 1:"EFI System Partition" "$ROOT_DISK"
# root LUKS
sgdisk -n 2:0:0            -t 2:8300 -c 2:"cryptroot"           "$ROOT_DISK"
reread_pt "$ROOT_DISK"

echo "==> Partitioning $DATA_DISK (GPT: data LUKS)..."
sgdisk --zap-all "$DATA_DISK"
sgdisk -n 1:0:0 -t 1:8300 -c 1:"crypthome" "$DATA_DISK"
reread_pt "$DATA_DISK"

ESP_PART="${ROOT_DISK}p1"
ROOT_PART="${ROOT_DISK}p2"
DATA_PART="${DATA_DISK}1"
# Handle non-NVMe naming (e.g., /dev/sda1 already ends with 1)
[[ -b "$ESP_PART" ]]  || ESP_PART="${ROOT_DISK}1"
[[ -b "$ROOT_PART" ]] || ROOT_PART="${ROOT_DISK}2"

echo "==> Creating LUKS1 containers..."
cryptsetup luksFormat --type luks1 -y "$ROOT_PART"
cryptsetup luksFormat --type luks1 -y "$DATA_PART"

echo "==> Opening LUKS containers..."
cryptsetup open "$ROOT_PART" cryptroot
cryptsetup open "$DATA_PART" cryptdata

echo "==> Creating filesystems..."
mkfs.vfat -F32 -n EFI "$ESP_PART"
mkfs.btrfs -L void_root -m single /dev/mapper/cryptroot
mkfs.btrfs -L void_data -m single /dev/mapper/cryptdata

echo "==> Creating Btrfs subvolumes..."
# Root FS: mount top-level, create subvols, unmount
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@opt
btrfs subvolume create /mnt/@usr_local
btrfs subvolume create /mnt/@root
umount /mnt

# Data FS: mount top-level, create subvols, unmount
mount /dev/mapper/cryptdata /mnt
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_lib
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_cache
btrfs subvolume create /mnt/@var_tmp
btrfs subvolume create /mnt/@var_swap

umount /mnt

echo "==> Mounting subvolumes..."
BTRFS_OPTS="rw,noatime,ssd,compress=zstd,space_cache=v2"
DATA_MAPPER="/dev/mapper/cryptdata"   # <- ensure this matches your 'cryptsetup open' name

# Root (drive #1)
mount -o "$BTRFS_OPTS",subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{opt,usr/local,root,home,snapshots}
mkdir -p /mnt/var /mnt/var/{lib,log,cache,tmp,swap}

mount -o "$BTRFS_OPTS",subvol=@opt        /dev/mapper/cryptroot /mnt/opt
mount -o "$BTRFS_OPTS",subvol=@usr_local  /dev/mapper/cryptroot /mnt/usr/local
mount -o "$BTRFS_OPTS",subvol=@root       /dev/mapper/cryptroot /mnt/root

# Data (drive #2)
mount -o "$BTRFS_OPTS",subvol=@home       "$DATA_MAPPER" /mnt/home
mount -o "$BTRFS_OPTS",subvol=@snapshots  "$DATA_MAPPER" /mnt/snapshots

# /var subtree mounts (order matters)
mount -o "$BTRFS_OPTS",subvol=@var_lib    "$DATA_MAPPER" /mnt/var/lib
mount -o "$BTRFS_OPTS",subvol=@var_log    "$DATA_MAPPER" /mnt/var/log
mount -o "$BTRFS_OPTS",subvol=@var_cache  "$DATA_MAPPER" /mnt/var/cache
mount -o "$BTRFS_OPTS",subvol=@var_tmp    "$DATA_MAPPER" /mnt/var/tmp
mount -o "$BTRFS_OPTS",subvol=@var_swap   "$DATA_MAPPER" /mnt/var/swap

# ESP
mkdir -p /mnt/boot/efi
mount -o rw,noatime "$ESP_PART" /mnt/boot/efi

echo "==> Disabling CoW where needed (var heavy dirs + swap dir)..."

# NOCOW helper: apply to the directory and any existing regular files
set_nocow_dir() {
  local d="$1"
  # make sure it exists
  mkdir -p "$d"
  # set +C on the directory
  chattr +C "$d" 2>/dev/null || true
  # also set +C on existing files so they won’t be COW-compressed until rewritten
  find "$d" -xdev -type f -print0 2>/dev/null | xargs -0r chattr +C 2>/dev/null || true
}

set_nocow_dir /mnt/var/lib
set_nocow_dir /mnt/var/log
set_nocow_dir /mnt/var/cache
set_nocow_dir /mnt/var/tmp
set_nocow_dir /mnt/var/swap

echo "==> Bootstrapping base system..."
REPO="${REPO}" ARCH="${ARCH}"
XBPS_ARCH="$ARCH" xbps-install -Sy -R "$REPO" -r /mnt \
  base-system linux-mainline linux-mainline-headers \
  btrfs-progs cryptsetup grub-x86_64-efi efibootmgr dracut \
  dbus-elogind dbus-elogind-libs dbus-elogind-x11 elogind \
  NetworkManager iwd openresolv cronie util-linux \
  glibc-locales linux-firmware-amd \
  nano bash-completion

echo "==> Preparing chroot..."
for d in dev proc sys run; do
  mount --rbind "/$d" "/mnt/$d"
  mount --make-rslave "/mnt/$d"
done
cp /etc/resolv.conf /mnt/etc/

echo "==> Entering chroot to configure system..."
cat > /mnt/root/inside-chroot.sh <<'CHROOT_EOF'
set -euo pipefail

# Basic system config
echo "==> Setting timezone, hostname, keymap, locales..."
ln -sf "/usr/share/zoneinfo/__TZ__" /etc/localtime
echo "__HOSTNAME__" > /etc/hostname

# rc.conf (minimal essentials)
sed -i 's|^#\?KEYMAP=.*|KEYMAP="__KEYMAP__"|' /etc/rc.conf || echo 'KEYMAP="__KEYMAP__"' >> /etc/rc.conf
sed -i 's|^#\?HARDWARECLOCK=.*|HARDWARECLOCK="UTC"|' /etc/rc.conf || echo 'HARDWARECLOCK="UTC"' >> /etc/rc.conf

# glibc locales (ensure presence, then generate)
if ! grep -q '^__LOCALE__$' /etc/default/libc-locales 2>/dev/null; then
  printf '%s\n' '__LOCALE__' >> /etc/default/libc-locales
fi
xbps-reconfigure -f glibc-locales || true

# Users & sudo
echo "==> Setting root password (prompt)..."
passwd
chsh -s __USER_SHELL__ root
echo "==> Creating user..."
useradd -m -G wheel,audio,video,kvm,storage,dialout,plugdev,xbuilder,lp,scanner __USERNAME__
passwd __USERNAME__
chsh -s __USER_SHELL__ __USERNAME__

# sudoers (wheel)
if command -v visudo >/dev/null 2>&1; then
  EDITOR=sed visudo -f /etc/sudoers -c >/dev/null 2>&1 || true
  sed -i 's|^# %wheel ALL=(ALL) ALL|%wheel ALL=(ALL) ALL|' /etc/sudoers
fi

# NetworkManager: let it own resolv.conf and use iwd
rm -f /etc/resolv.conf
ln -s /run/NetworkManager/resolv.conf /etc/resolv.conf
mkdir -p /etc/NetworkManager/conf.d
cat >/etc/NetworkManager/conf.d/wifi_backend.conf <<'EOF'
[device]
wifi.backend=iwd
wifi.iwd.autoconnect=yes
EOF

echo "==> Enabling runit services..."
ln -sf /etc/sv/dbus            /var/service/
ln -sf /etc/sv/elogind         /var/service/
ln -sf /etc/sv/iwd             /var/service/
ln -sf /etc/sv/NetworkManager  /var/service/
ln -sf /etc/sv/cronie          /var/service/

echo "==> Writing fstab..."
EFI_UUID=$(blkid -s UUID -o value __ESP_PART__)
ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)
DATA_UUID=$(blkid -s UUID -o value /dev/mapper/cryptdata)
cat > /etc/fstab <<EOF
# Root and ESP
UUID=${ROOT_UUID}   /           btrfs  rw,noatime,ssd,compress=zstd,space_cache=v2,subvol=@           0 1
UUID=${EFI_UUID}    /boot/efi   vfat   defaults,noatime                                                 0 2

# Excluded-from-root-snapshots (on drive #1)
UUID=${ROOT_UUID}   /opt        btrfs  rw,noatime,ssd,compress=zstd,space_cache=v2,subvol=@opt         0 2
UUID=${ROOT_UUID}   /usr/local  btrfs  rw,noatime,ssd,compress=zstd,space_cache=v2,subvol=@usr_local   0 2
UUID=${ROOT_UUID}   /root       btrfs  rw,noatime,ssd,compress=zstd,space_cache=v2,subvol=@root        0 2

# Second (bigger) disk mounts
UUID=${DATA_UUID}   /home       btrfs  rw,noatime,ssd,compress=zstd,space_cache=v2,subvol=@home        0 2
UUID=${DATA_UUID}   /snapshots  btrfs  rw,noatime,ssd,compress=zstd,space_cache=v2,subvol=@snapshots   0 2

# Heavy /var subtrees on second disk
UUID=${DATA_UUID}   /var/lib    btrfs  rw,noatime,ssd,compress=zstd,space_cache=v2,subvol=@var_lib     0 2
UUID=${DATA_UUID}   /var/log    btrfs  rw,noatime,ssd,compress=zstd,space_cache=v2,subvol=@var_log     0 2
UUID=${DATA_UUID}   /var/cache  btrfs  rw,noatime,ssd,compress=zstd,space_cache=v2,subvol=@var_cache   0 2
UUID=${DATA_UUID}   /var/tmp    btrfs  rw,noatime,ssd,compress=zstd,space_cache=v2,subvol=@var_tmp     0 2
UUID=${DATA_UUID}   /var/swap   btrfs  rw,noatime,ssd,compress=zstd,space_cache=v2,subvol=@var_swap    0 2

# tmp as tmpfs
tmpfs               /tmp        tmpfs  defaults,nosuid,nodev,mode=1777                                  0 0

# Swapfile (added below after creation)
/var/swap/swapfile none swap sw 0 0
EOF

echo "==> Creating 40G swapfile with NOCOW..."
# Ensure swap dir has NOCOW & no compression
chattr +C /var/swap || true

truncate -s 0 /var/swap/swapfile
chattr +C /var/swap/swapfile || true
fallocate -l __SWAP_SIZE__ /var/swap/swapfile
chmod 600 /var/swap/swapfile
mkswap /var/swap/swapfile
swapon /var/swap/swapfile

echo "==> Creating LUKS keyfile (for single-entry passphrase at boot)..."
dd if=/dev/urandom of=/boot/keyfile.bin bs=512 count=4 status=none
chmod 000 /boot/keyfile.bin
chmod -R go-rwx /boot

echo "==> Adding keyfile to LUKS keyslots..."
cryptsetup -v luksAddKey __ROOT_PART__ /boot/keyfile.bin
cryptsetup -v luksAddKey __DATA_PART__ /boot/keyfile.bin

echo "==> Writing /etc/crypttab with discard for weekly fstrim..."
LUKS_ROOT_UUID=$(blkid -s UUID -o value __ROOT_PART__)
LUKS_DATA_UUID=$(blkid -s UUID -o value __DATA_PART__)
cat > /etc/crypttab <<EOF
cryptroot UUID=${LUKS_ROOT_UUID} /boot/keyfile.bin luks,discard
cryptdata  UUID=${LUKS_DATA_UUID} /boot/keyfile.bin luks,discard
EOF

echo '==> Dracut: include keyfile and crypttab in initramfs...'
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/10-crypt.conf <<EOF
install_items+=" /boot/keyfile.bin /etc/crypttab "
EOF

echo "==> Hibernation: computing resume offset..."
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /var/swap/swapfile)

echo "==> Configuring GRUB..."
# - resume points to FS that holds swapfile (DATA_UUID) + resume_offset
# - allow LUKS discards
# - add rd.auto=1 for good measure; page_poison=1 and loglevel=4 as requested
echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
sed -i '/^GRUB_CMDLINE_LINUX=/d' /etc/default/grub
echo "GRUB_CMDLINE_LINUX=\"resume=UUID=${DATA_UUID} resume_offset=${RESUME_OFFSET} rd.luks.allow-discards rd.auto=1 \"" >> /etc/default/grub

echo "==> Installing GRUB..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Void"

echo "==> Rebuilding initramfs and GRUB config..."
xbps-reconfigure -fa
grub-mkconfig -o /boot/grub/grub.cfg

echo '==> Weekly fstrim via cron...'
cat >/etc/cron.weekly/fstrim <<'EOF'
#!/bin/sh
/usr/sbin/fstrim -av
EOF
chmod +x /etc/cron.weekly/fstrim

echo "==> Done inside chroot."
CHROOT_EOF

# Fill placeholders
sed -i "s|__TZ__|$TZ|g"                                    /mnt/root/inside-chroot.sh
sed -i "s|__HOSTNAME__|$HOSTNAME|g"                        /mnt/root/inside-chroot.sh
sed -i "s|__KEYMAP__|$KEYMAP|g"                            /mnt/root/inside-chroot.sh
sed -i "s|__LOCALE__|$LOCALE|g"                            /mnt/root/inside-chroot.sh
sed -i "s|__USERNAME__|$USERNAME|g"                        /mnt/root/inside-chroot.sh
sed -i "s|__USER_SHELL__|$USER_SHELL|g"                    /mnt/root/inside-chroot.sh
sed -i "s|__SWAP_SIZE__|$SWAP_SIZE|g"                      /mnt/root/inside-chroot.sh
sed -i "s|__ESP_PART__|$ESP_PART|g"                        /mnt/root/inside-chroot.sh
sed -i "s|__ROOT_PART__|$ROOT_PART|g"                      /mnt/root/inside-chroot.sh
sed -i "s|__DATA_PART__|$DATA_PART|g"                      /mnt/root/inside-chroot.sh

chmod +x /mnt/root/inside-chroot.sh

echo "==> Chrooting to run configuration..."
chroot /mnt /usr/bin/env bash -c "/root/inside-chroot.sh"

echo "==> Unmounting filesystems..."
swapoff /mnt/var/swap/swapfile || true
umount -R /mnt/boot/efi || true
umount -R /mnt

echo "==> Closing LUKS mappings..."
cryptsetup close cryptdata || true
cryptsetup close cryptroot || true

echo "==> Installation complete. Reboot when ready."

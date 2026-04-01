#!/usr/bin/env bash
set -euo pipefail

### ====== EDIT ME (DISK & BASICS) ============================================
# change to /dev/sda if a sata disk or something else
# that fits your setup
ROOT_DISK="/dev/nvme0n1"
ESP_SIZE="1024MiB"

# change to your desired computer name
HOSTNAME="localhost"

# change to your desired user name
USERNAME="user"
USER_SHELL="/bin/bash"
TZ="Europe/Madrid" # set your timezone here
KEYMAP="br-abnt2" # set your keymap here.
LOCALE="pt_BR.UTF-8 UTF-8" #set your locale here

SWAP_SIZE="40G" # should be RAM * 1.5 for Hibernation

REPO="https://repo-fastly.voidlinux.org/current/"
ARCH="x86_64"

### ====== LIVE ISO PREFLIGHT ==================================================
echo "==> Ensuring required live-ISO tools are present..."
need() { command -v "$1" >/dev/null 2>&1 || xbps-install -Sy "$2"; }

need curl curl
need sgdisk gptfdisk
need partprobe parted

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

### ====== NO EDITS BELOW ======================================================

echo "==> Validating disk..."
[[ -b "$ROOT_DISK" ]] || { echo "Root disk not found: $ROOT_DISK"; exit 1; }

echo "==> Wiping old signatures..."
wipefs -a "$ROOT_DISK"

echo "==> Partitioning $ROOT_DISK (GPT: ESP + root LUKS)..."
sgdisk --zap-all "$ROOT_DISK"
sgdisk -n 1:0:+"$ESP_SIZE" -t 1:ef00 -c 1:"EFI System Partition" "$ROOT_DISK"
sgdisk -n 2:0:0            -t 2:8300 -c 2:"cryptroot"           "$ROOT_DISK"
reread_pt "$ROOT_DISK"

ESP_PART="${ROOT_DISK}p1"
ROOT_PART="${ROOT_DISK}p2"
[[ -b "$ESP_PART" ]]  || ESP_PART="${ROOT_DISK}1"
[[ -b "$ROOT_PART" ]] || ROOT_PART="${ROOT_DISK}2"

echo "==> Creating LUKS1 container..."
cryptsetup luksFormat --type luks1 -y "$ROOT_PART"

echo "==> Opening LUKS container..."
cryptsetup open "$ROOT_PART" cryptroot

echo "==> Creating filesystems..."
mkfs.vfat -F32 -n EFI "$ESP_PART"
mkfs.btrfs -L void_root -m single /dev/mapper/cryptroot

echo "==> Creating Btrfs subvolumes..."
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@opt
btrfs subvolume create /mnt/@usr_local
btrfs subvolume create /mnt/@root
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@timeshift
btrfs subvolume create /mnt/@var_lib
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_cache
btrfs subvolume create /mnt/@var_tmp
btrfs subvolume create /mnt/@var_swap
umount /mnt

echo "==> Mounting subvolumes..."
BTRFS_OPTS="rw,noatime,ssd,compress=zstd:3,space_cache=v2,discard=async"

mount -o "$BTRFS_OPTS",subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{opt,usr/local,root,home,timeshift-btrfs}
mkdir -p /mnt/var /mnt/var/{lib,log,cache,tmp,swap}

mount -o "$BTRFS_OPTS",subvol=@opt        /dev/mapper/cryptroot /mnt/opt
mount -o "$BTRFS_OPTS",subvol=@usr_local  /dev/mapper/cryptroot /mnt/usr/local
mount -o "$BTRFS_OPTS",subvol=@root       /dev/mapper/cryptroot /mnt/root
mount -o "$BTRFS_OPTS",subvol=@home       /dev/mapper/cryptroot /mnt/home
mount -o "$BTRFS_OPTS",subvol=@timeshift  /dev/mapper/cryptroot /mnt/timeshift-btrfs
mount -o "$BTRFS_OPTS",subvol=@var_lib    /dev/mapper/cryptroot /mnt/var/lib
mount -o "$BTRFS_OPTS",subvol=@var_log    /dev/mapper/cryptroot /mnt/var/log
mount -o "$BTRFS_OPTS",subvol=@var_cache  /dev/mapper/cryptroot /mnt/var/cache
mount -o "$BTRFS_OPTS",subvol=@var_tmp    /dev/mapper/cryptroot /mnt/var/tmp
mount -o "$BTRFS_OPTS",subvol=@var_swap   /dev/mapper/cryptroot /mnt/var/swap

mkdir -p /mnt/boot/efi
mount -o rw,noatime "$ESP_PART" /mnt/boot/efi

echo "==> Disabling CoW where needed (var heavy dirs)..."
set_nocow_dir() {
  local d="$1"
  mkdir -p "$d"
  chattr +C "$d" 2>/dev/null || true
  find "$d" -xdev -type f -print0 2>/dev/null | xargs -0r chattr +C 2>/dev/null || true
}

set_nocow_dir /mnt/var/lib
set_nocow_dir /mnt/var/log
set_nocow_dir /mnt/var/cache
set_nocow_dir /mnt/var/tmp
set_nocow_dir /mnt/var/swap

mkdir -p /mnt/var/lib/docker
mkdir -p /mnt/var/cache/xbps
chattr +C /mnt/var/lib/docker 2>/dev/null || true
chattr +C /mnt/var/cache/xbps 2>/dev/null || true

echo "==> Bootstrapping base system..."
REPO="${REPO}" ARCH="${ARCH}"
XBPS_ARCH="$ARCH" xbps-install -Sy -R "$REPO" -r /mnt \
  base-system linux-mainline linux-mainline-headers \
  btrfs-progs cryptsetup grub-x86_64-efi efibootmgr dracut \
  dbus elogind polkit \
  NetworkManager iwd openresolv cronie chrony util-linux acpid \
  socklog-void \
  apparmor \
  libvirt qemu \
  timeshift grub-btrfs inotify-tools \
  glibc-locales linux-firmware-amd \
  nano bash-completion sudo

echo "==> Preparing chroot..."
for d in dev proc sys run; do
  mount --rbind "/$d" "/mnt/$d"
  mount --make-rslave "/mnt/$d"
done
cp /etc/resolv.conf /mnt/etc/

echo "==> Entering chroot to configure system..."
cat > /mnt/root/inside-chroot.sh <<'CHROOT_EOF'
set -euo pipefail

echo "==> Setting timezone, hostname, keymap, locales..."
ln -sf "/usr/share/zoneinfo/__TZ__" /etc/localtime
echo "__HOSTNAME__" > /etc/hostname

sed -i 's|^#\?KEYMAP=.*|KEYMAP="__KEYMAP__"|' /etc/rc.conf || echo 'KEYMAP="__KEYMAP__"' >> /etc/rc.conf
sed -i 's|^#\?HARDWARECLOCK=.*|HARDWARECLOCK="UTC"|' /etc/rc.conf || echo 'HARDWARECLOCK="UTC"' >> /etc/rc.conf

if ! grep -q '^__LOCALE__$' /etc/default/libc-locales 2>/dev/null; then
  printf '%s\n' '__LOCALE__' >> /etc/default/libc-locales
fi
xbps-reconfigure -f glibc-locales || true

echo "==> Setting root password (prompt)..."
passwd
chsh -s __USER_SHELL__ root

echo "==> Creating user..."
useradd -m -G wheel,audio,video,kvm,storage,dialout,plugdev,xbuilder,lp,scanner,tty,tape,cdrom,optical,network,input,libvirt __USERNAME__
passwd __USERNAME__
chsh -s __USER_SHELL__ __USERNAME__

echo "==> Enabling sudo for wheel..."
if command -v visudo >/dev/null 2>&1; then
  cp /etc/sudoers /etc/sudoers.bak
  sed -Ei 's|^[[:space:]]*#?[[:space:]]*(%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL)|\1|' /etc/sudoers
  visudo -c
fi

echo "==> NetworkManager: let it own resolv.conf and use iwd..."
rm -f /etc/resolv.conf
ln -s /run/NetworkManager/resolv.conf /etc/resolv.conf
mkdir -p /etc/NetworkManager/conf.d
cat >/etc/NetworkManager/conf.d/wifi_backend.conf <<'EOF'
[device]
wifi.backend=iwd
wifi.iwd.autoconnect=yes
EOF

echo "==> Configuring elogind to ignore ACPI events so acpid handles them..."
mkdir -p /etc/elogind/logind.conf.d
cat >/etc/elogind/logind.conf.d/99-acpi-ignore.conf <<'EOF'
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=ignore
HandleRebootKey=ignore
HandleRebootKeyLongPress=ignore
HandleSuspendKey=ignore
HandleSuspendKeyLongPress=ignore
HandleHibernateKey=ignore
HandleHibernateKeyLongPress=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF

echo "==> Configuring polkit rules for libvirt and NetworkManager..."
mkdir -p /etc/polkit-1/rules.d
cat >/etc/polkit-1/rules.d/49-void-local.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if (!(subject.active && subject.local)) {
        return polkit.Result.NOT_HANDLED;
    }

    if ((subject.isInGroup("wheel") || subject.isInGroup("libvirt")) &&
        (action.id == "org.libvirt.unix.manage" ||
         action.id == "org.libvirt.unix.monitor")) {
        return polkit.Result.YES;
    }

    if (subject.isInGroup("wheel") &&
        action.id.indexOf("org.freedesktop.NetworkManager.") == 0) {
        return polkit.Result.YES;
    }

    return polkit.Result.NOT_HANDLED;
});
EOF

echo "==> Enabling runit services..."
ln -sf /etc/sv/dbus            /var/service/
ln -sf /etc/sv/elogind         /var/service/
ln -sf /etc/sv/acpid           /var/service/
ln -sf /etc/sv/iwd             /var/service/
ln -sf /etc/sv/NetworkManager  /var/service/
ln -sf /etc/sv/cronie          /var/service/
ln -sf /etc/sv/chronyd         /var/service/
ln -sf /etc/sv/socklog-unix    /var/service/
ln -sf /etc/sv/nanoklogd       /var/service/
ln -sf /etc/sv/libvirtd        /var/service/
ln -sf /etc/sv/virtlockd       /var/service/
ln -sf /etc/sv/virtlogd        /var/service/
ln -sf /etc/sv/grub-btrfs      /var/service/

# Avoid conflicts with NetworkManager
rm -f /var/service/dhcpcd /var/service/wpa_supplicant /var/service/wicd 2>/dev/null || true

echo "==> Writing fstab..."
EFI_UUID=$(blkid -s UUID -o value __ESP_PART__)
ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)

cat > /etc/fstab <<EOF
UUID=${ROOT_UUID}   /                btrfs  rw,noatime,ssd,compress=zstd:3,space_cache=v2,discard=async,subvol=@            0 1
UUID=${EFI_UUID}    /boot/efi        vfat   defaults,noatime                                                                  0 2

UUID=${ROOT_UUID}   /opt             btrfs  rw,noatime,ssd,compress=zstd:3,space_cache=v2,discard=async,subvol=@opt          0 2
UUID=${ROOT_UUID}   /usr/local       btrfs  rw,noatime,ssd,compress=zstd:3,space_cache=v2,discard=async,subvol=@usr_local    0 2
UUID=${ROOT_UUID}   /root            btrfs  rw,noatime,ssd,compress=zstd:3,space_cache=v2,discard=async,subvol=@root         0 2
UUID=${ROOT_UUID}   /home            btrfs  rw,noatime,ssd,compress=zstd:3,space_cache=v2,discard=async,subvol=@home         0 2
UUID=${ROOT_UUID}   /timeshift-btrfs btrfs  rw,noatime,ssd,compress=zstd:3,space_cache=v2,discard=async,subvol=@timeshift    0 2

UUID=${ROOT_UUID}   /var/lib         btrfs  rw,noatime,ssd,compress=zstd:3,space_cache=v2,discard=async,subvol=@var_lib      0 2
UUID=${ROOT_UUID}   /var/log         btrfs  rw,noatime,ssd,compress=zstd:3,space_cache=v2,discard=async,subvol=@var_log      0 2
UUID=${ROOT_UUID}   /var/cache       btrfs  rw,noatime,ssd,compress=zstd:3,space_cache=v2,discard=async,subvol=@var_cache    0 2
UUID=${ROOT_UUID}   /var/tmp         btrfs  rw,noatime,ssd,compress=zstd:3,space_cache=v2,discard=async,subvol=@var_tmp      0 2
UUID=${ROOT_UUID}   /var/swap        btrfs  rw,noatime,ssd,compress=zstd:3,space_cache=v2,discard=async,subvol=@var_swap     0 2

tmpfs               /tmp             tmpfs  defaults,nosuid,nodev,mode=1777                                                   0 0
/var/swap/swapfile  none             swap   defaults                                                                          0 0
EOF

echo "==> Configuring Timeshift..."
mkdir -p /etc/timeshift
cat > /etc/timeshift/timeshift.json <<EOF
{
  "backup_device_uuid" : "${ROOT_UUID}",
  "parent_device_uuid" : "",
  "do_first_run" : "false",
  "btrfs_mode" : "true",
  "include_btrfs_home_for_backup" : "false",
  "include_btrfs_home_for_restore" : "false",
  "stop_cron_emails" : "true",
  "btrfs_use_qgroup" : "true",
  "schedule_monthly" : "true",
  "schedule_weekly" : "true",
  "schedule_daily" : "true",
  "schedule_hourly" : "false",
  "schedule_boot" : "true",
  "count_monthly" : "3",
  "count_weekly" : "4",
  "count_daily" : "7",
  "count_hourly" : "0",
  "count_boot" : "5",
  "snapshot_size" : "0",
  "snapshot_count" : "0"
}
EOF

mkdir -p /etc/cron.hourly
cat > /etc/cron.hourly/timeshift-check <<'EOF'
#!/bin/sh
exec /usr/bin/timeshift --check
EOF
chmod +x /etc/cron.hourly/timeshift-check

cat > /usr/local/sbin/timeshift-manual-snapshot <<'EOF'
#!/bin/sh
exec /usr/bin/timeshift --create --comments "${1:-Manual snapshot}" --tags O
EOF
chmod +x /usr/local/sbin/timeshift-manual-snapshot

echo "==> Configuring grub-btrfs..."
mkdir -p /etc/default/grub-btrfs
cat > /etc/default/grub-btrfs/config <<'EOF'
GRUB_BTRFS_MKCONFIG=/usr/bin/grub-mkconfig
GRUB_BTRFS_GRUB_DIRNAME="/boot/grub"
GRUB_BTRFS_SCRIPT_CHECK=grub-script-check
GRUB_BTRFS_ENABLE_CRYPTODISK=false
EOF

cat > /etc/sv/grub-btrfs/conf <<'EOF'
GRUB_BTRFSD_OPTS="--timeshift-auto --syslog"
EOF

echo "==> Creating swapfile..."
mkdir -p /var/swap
chmod 700 /var/swap

if btrfs filesystem mkswapfile --help >/dev/null 2>&1; then
  btrfs filesystem mkswapfile --size __SWAP_SIZE__ /var/swap/swapfile
else
  truncate -s 0 /var/swap/swapfile
  chattr +C /var/swap/swapfile
  fallocate -l __SWAP_SIZE__ /var/swap/swapfile
  chmod 600 /var/swap/swapfile
  mkswap /var/swap/swapfile
fi

chmod 600 /var/swap/swapfile
swapon /var/swap/swapfile

echo "==> Creating LUKS keyfile..."
dd if=/dev/urandom of=/boot/keyfile.bin bs=512 count=4 status=none
chmod 000 /boot/keyfile.bin
chmod -R go-rwx /boot

echo "==> Adding keyfile to LUKS keyslot..."
cryptsetup -v luksAddKey __ROOT_PART__ /boot/keyfile.bin

echo "==> Writing /etc/crypttab..."
LUKS_ROOT_UUID=$(blkid -s UUID -o value __ROOT_PART__)
cat > /etc/crypttab <<EOF
cryptroot UUID=${LUKS_ROOT_UUID} /boot/keyfile.bin luks,discard
EOF

echo "==> Dracut: include keyfile and crypttab..."
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/10-crypt.conf <<EOF
install_items+=" /boot/keyfile.bin /etc/crypttab "
EOF

echo "==> Hibernation: computing resume offset..."
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /var/swap/swapfile)

echo "==> Detecting CPU vendor for IOMMU kernel args..."
IOMMU_ARGS=""
if grep -qi 'AuthenticAMD' /proc/cpuinfo; then
  IOMMU_ARGS="amd_iommu=on iommu=pt"
elif grep -qi 'GenuineIntel' /proc/cpuinfo; then
  IOMMU_ARGS="intel_iommu=on iommu=pt"
fi

echo "==> Configuring GRUB..."
grep -q '^GRUB_ENABLE_CRYPTODISK=' /etc/default/grub \
  && sed -i 's/^GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub \
  || echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub

grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub \
  && sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=7"/' /etc/default/grub \
  || echo 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=7"' >> /etc/default/grub

sed -i '/^GRUB_CMDLINE_LINUX=/d' /etc/default/grub
echo "GRUB_CMDLINE_LINUX=\"resume=UUID=${ROOT_UUID} resume_offset=${RESUME_OFFSET} rd.luks.allow-discards rd.auto=1 apparmor=1 security=apparmor ${IOMMU_ARGS}\"" >> /etc/default/grub

echo "==> Priming grub-btrfs menu generator..."
/etc/grub.d/41_snapshots-btrfs >/dev/null 2>&1 || true

echo "==> Installing GRUB..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Void"

echo "==> Rebuilding initramfs..."
xbps-reconfigure -fa

echo "==> Writing GRUB config explicitly..."
rm -f /boot/grub/grub.cfg
grub-mkconfig -o /boot/grub/grub.cfg

echo "==> Verifying GRUB config..."
if [ ! -s /boot/grub/grub.cfg ]; then
  if [ -s /boot/grub/grub.cfg.new ]; then
    echo "==> grub.cfg missing but grub.cfg.new exists; promoting it..."
    cp -a /boot/grub/grub.cfg.new /boot/grub/grub.cfg
  fi
fi

if [ ! -s /boot/grub/grub.cfg ]; then
  echo "ERROR: /boot/grub/grub.cfg was not created correctly." >&2
  ls -la /boot/grub >&2 || true
  exit 1
fi

echo "==> Weekly fstrim via cron..."
cat >/etc/cron.weekly/fstrim <<'EOF'
#!/bin/sh
/usr/sbin/fstrim -av
EOF
chmod +x /etc/cron.weekly/fstrim

echo "==> Writing first-boot Timeshift helper..."
cat >/root/init-timeshift-first-snapshot.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
timeshift --create --comments "Initial clean install" --tags O
/etc/grub.d/41_snapshots-btrfs >/dev/null 2>&1 || true
grub-mkconfig -o /boot/grub/grub.cfg
if [ ! -s /boot/grub/grub.cfg ] && [ -s /boot/grub/grub.cfg.new ]; then
  cp -a /boot/grub/grub.cfg.new /boot/grub/grub.cfg
fi
echo "Initial Timeshift snapshot created and GRUB menu updated."
EOF
chmod +x /root/init-timeshift-first-snapshot.sh

echo "==> Writing post-boot validation script..."
cat >/root/post-install-checks.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "==> Service status"
sv status dbus elogind NetworkManager chronyd socklog-unix nanoklogd libvirtd virtlockd virtlogd acpid grub-btrfs || true
echo

echo "==> virsh system connection"
virsh -c qemu:///system list --all || true
echo

echo "==> Kernel command line AppArmor/IOMMU check"
cat /proc/cmdline | grep -E 'apparmor|security=apparmor|iommu=pt|intel_iommu=on|amd_iommu=on' || true
echo

echo "==> Active swap"
swapon --show || true
echo

echo "==> Btrfs resume offset"
btrfs inspect-internal map-swapfile -r /var/swap/swapfile || true
echo

echo "==> NetworkManager polkit view"
nmcli general permissions || true
echo

echo "==> Timeshift snapshots"
timeshift --list || true
echo

echo "==> grub-btrfs config"
test -f /boot/grub/grub-btrfs.cfg && ls -l /boot/grub/grub-btrfs.cfg || true
echo

echo "==> Main GRUB config"
ls -l /boot/grub/grub.cfg /boot/grub/grub.cfg.new 2>/dev/null || true
echo
EOF
chmod +x /root/post-install-checks.sh

echo "==> Done inside chroot."
CHROOT_EOF

sed -i "s|__TZ__|$TZ|g"                                    /mnt/root/inside-chroot.sh
sed -i "s|__HOSTNAME__|$HOSTNAME|g"                        /mnt/root/inside-chroot.sh
sed -i "s|__KEYMAP__|$KEYMAP|g"                            /mnt/root/inside-chroot.sh
sed -i "s|__LOCALE__|$LOCALE|g"                            /mnt/root/inside-chroot.sh
sed -i "s|__USERNAME__|$USERNAME|g"                        /mnt/root/inside-chroot.sh
sed -i "s|__USER_SHELL__|$USER_SHELL|g"                    /mnt/root/inside-chroot.sh
sed -i "s|__SWAP_SIZE__|$SWAP_SIZE|g"                      /mnt/root/inside-chroot.sh
sed -i "s|__ESP_PART__|$ESP_PART|g"                        /mnt/root/inside-chroot.sh
sed -i "s|__ROOT_PART__|$ROOT_PART|g"                      /mnt/root/inside-chroot.sh

chmod +x /mnt/root/inside-chroot.sh

echo "==> Chrooting to run configuration..."
chroot /mnt /usr/bin/env bash -c "/root/inside-chroot.sh"

echo "==> Unmounting filesystems..."
swapoff /mnt/var/swap/swapfile || true
umount -R /mnt/boot/efi || true
umount -R /mnt || true

echo "==> Closing LUKS mappings..."
cryptsetup close cryptroot || true

echo "==> Installation complete. Reboot when ready."
echo "==> After first boot, run as root: /root/init-timeshift-first-snapshot.sh"
echo "==> Then validate with: /root/post-install-checks.sh"

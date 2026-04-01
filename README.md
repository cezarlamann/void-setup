# void-setup
Local Machine Setup for Void Linux (glibc)

### Your computer will be Void! Welcome to the Void!

Please look into https://docs.voidlinux.org/ for further documentation

These setup scripts are made for using the "base glibc live image" of Void linux + installation via chroot. This set of scripts sets up your machine with a fully functional text setup, so you can customise it later with any desktop environment you'd like.

This setup uses the `glibc` image to focus on compatibility with other software (mainly interesting to developers like me who don't want to fiddle with glibc/musl compatibility issues). It might work fine with the `musl` image, but I haven't tested these scripts with the `musl` image.

This setup has two ways of setting up a machine according to your hardware: Single disk or two disks (one for system root + one for data (home folder, etc.), where the first disk is an NVMe and the second is a regular SATA drive. This can be adjusted in the script itself)

The scripts have two sections: one for you to edit with your personal settings, and the second containing the actual commands

### It sets up your computer with the following services and things:
- Uses Mainline kernel
- GRUB + BTRFS + Full disk encryption (LUKS1) + Snapshots with automatic key setup for decrypting partitions automatically after first boot decryption
- Swap as a file, encrypted, inside the root partition (Windows-like setup, no external partition for swap) with "resume/offset" configuration
- AppArmor + polkit
- Subvolumes for /var/{lib,log,cache,tmp}, excluded from snapshots (with noCoW for some of the subvolumes)
- Sets your user automatically into `wheel, audio, video, kvm, storage, dialout, plugdev, xbuilder, lp, scanner, tty, tape, cdrom, optical, network, input, libvirt` groups
- DBus
- Elogind + ACPId (`elogind` with disabled hardware event handlers, these are handled by `acpid`)
- NetworkManager + iwd for handling wireless connections
- Cronie for CRON handling
- Chrony for NTP/Time handling
- Socklog for logging
- Libvirtd for handling virtualisation tasks + automatic setup for IOMMU (detects AMD/Intel and sets up the flags accordingly, either amd_iommu or intel_iommu)
- GRUB-BTRFS for handling snapshots with Timeshift
- Weekly `fstrim` CRON job

### Setup how-to:
- **These scripts are not suitable for dual-boot. THEY WILL WIPE YOUR ENTIRE DISKS. BE WARNED!**
- Boot up Void base image
- Check if you have internet connectivity by running `ping 1.1.1.1`.
- Wireless setup:
  - Please note that if your wifi password has special characters (e.g. "!") they need to be "escaped" (written like this: "\!")
  - Check your wifi interface with the command `ip a`. It should be something like `wlp2s0` or `wlan0`
  - Replace the placeholders in the commands below (including the parenthesis) with your info (e.g. `(your network interface)` with `wlp2s0`)
  - Run the following commands:
  
    ```
    #> bash
    #> sv stop wpa_supplicant
    #> wpa_passphrase (your network name/SSID) (your password) > /etc/wpa_supplicant/wpa_supplicant.conf
    #> wpa_supplicant -B -i (your network interface) -c /etc/wpa_supplicant/wpa_supplicant.conf
    ```
  - Wait for a bit and then re-check if you got an IP address with the command `ip -a` again
  - Check internet connectivity again with `ping 1.1.1.1`
- Upgrade your xbps utility with `xbps-install -Suy xbps`
- Install required packages with `xbps-install -Suy git parted gptfdisk curl wget openssl`
- Install `nano` (optional) with `xbps-install -Suy nano`
- Clone the repository with `git clone https://github.com/cezarlamann/void-setup.git`
- `cd` into the folder with `cd void-setup`
- Choose if you want a single disk or dual disk setup by entering the folders `cd single-disk` or `cd dual-disk`
- Edit your settings, locale, etc with a text editor (`vi` or `nano`)
- Make the installation script executable with `chmod +x install.sh`
- Run the script and follow the instructions.
- The script will ask you for your disk encryption several times.
- At the end, the script will tell you to run a couple of check-up scripts after rebooting. Follow the instructions!
- Reboot
- After rebooting, log-in with the root user, cd into root with `cd /root` and execute the `init-timeshift-first-snapshot.sh` and `post-install-checks.sh`


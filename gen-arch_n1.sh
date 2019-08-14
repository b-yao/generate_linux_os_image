#!/bin/sh
#genetate archlinux arm phicomm n1 image: chmod +x gen-arch_n1.sh && sudo ./gen-arch_n1.sh
#depends: arch-install-scripts, vim(xxd)

set -xe

die() {
	printf '\033[1;31mERROR:\033[0m %s\n' "$@" >&2  # bold red
	exit 1
}

if [ "$(id -u)" -ne 0 ]; then
	die 'This script must be run as root!'
fi

which xxd >/dev/null || exit

BUILD_DATE="$(date +%Y-%m-%d)"

usage() {
	cat <<EOF
	Usage: gen-arch_n1.sh [options]
	Valid options are:
		-g HTTP_PROXY_GENERIC   Generic HTTP proxy
		                        (default is http://10.82.1.123:1080).
		-a HTTP_PROXY_ARCH      HTTP proxy for the ARCH_MIRROR
		                        (default is http://10.69.130.182:8080).
		-m ARCH_MIRROR          URI of the mirror to fetch packages from
		                        (default is https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm).
		-o OUTPUT_IMG           Output img file
		                        (default is BUILD_DATE-arch-n1-xfce4-mods.img).
		-h                      Show this help message and exit.
EOF
}

while getopts 'g:a:m:o:h' OPTION; do
	case "$OPTION" in
		g) HTTP_PROXY_GENERIC="$OPTARG";;
		a) HTTP_PROXY_ARCH="$OPTARG";;
		m) ARCH_MIRROR="$OPTARG";;
		o) OUTPUT="$OPTARG";;
		h) usage; exit 0;;
	esac
done

: ${HTTP_PROXY_GENERIC:="http://10.82.1.123:1080"}
: ${HTTP_PROXY_ARCH:="http://10.69.130.182:8080"}
: ${ARCH_MIRROR:="https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm"}
: ${OUTPUT_IMG:="${BUILD_DATE}-arch-n1-xfce4-mods.img"}

#=======================  F u n c t i o n s  =======================#

set_system_date(){
	pacman --needed -S --noconfirm curl
	ln -sf /usr/share/zoneinfo/Asia/Chongqing /etc/localtime
	# set clock by referring google
	date -s "$(curl -H'Cache-Control:no-cache' -sI google.com | grep '^Date:' | cut -d' ' -f3-6)Z"
}

gen_image() {
	fallocate -l $(( 5600 * 1024 *1024 )) "$OUTPUT_IMG"
cat > fdisk.cmd <<-EOF
	o
	n
	p
	1

	+100MB
	t
	c
	n
	p
	2


	w
EOF
fdisk "$OUTPUT_IMG" < fdisk.cmd
rm -f fdisk.cmd
}

do_format() {
	mkfs.fat -F32 "$BOOT_DEV"
	mkfs.ext4 "$ROOT_DEV"
	mkdir -p mnt
	mount "$ROOT_DEV" mnt
	mkdir -p mnt/boot
	mount "$BOOT_DEV" mnt/boot
}

setup_mirrors() {
	sed -i "1i Server = ${ARCH_MIRROR}/\$arch/\$repo" /etc/pacman.d/mirrorlist
}

delete_mirrors() {
	sed -i '1d' /etc/pacman.d/mirrorlist
}

do_pacstrap() {
	export http_proxy=${HTTP_PROXY_ARCH}
	export https_proxy=${HTTP_PROXY_ARCH}
	pacstrap mnt base base-devel
}

gen_resize2fs_once_service() {
	cat > /etc/systemd/system/resize2fs-once.service <<'EOF'
[Unit]
Description=Resize the root filesystem to fill partition
DefaultDependencies=no
Conflicts=shutdown.target
After=systemd-remount-fs.service
Before=systemd-sysusers.service sysinit.target shutdown.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/resize2fs_once
StandardOutput=tty
StandardInput=tty
StandardError=tty
[Install]
WantedBy=sysinit.target
EOF

	cat > /usr/local/bin/resize2fs_once <<'EOF'
#!/bin/sh
set -xe
ROOT_DEV=$(findmnt / -o source -n)
ROOT_START=$(fdisk -l $(echo "$ROOT_DEV" | sed -E 's/p?2$//') | grep "$ROOT_DEV" | awk '{ print $2 }')
cat > /tmp/fdisk.cmd <<-EOF
	d
	2

	n
	p
	2
	${ROOT_START}

	w
	EOF
fdisk "$(echo "$ROOT_DEV" | sed -E 's/p?2$//')" < /tmp/fdisk.cmd
rm -f /tmp/fdisk.cmd
partprobe
resize2fs "$ROOT_DEV"
systemctl disable resize2fs-once
EOF

chmod +x /usr/local/bin/resize2fs_once
systemctl enable resize2fs-once
}

gen_fstabs() {
	echo "# Static information about the filesystems.
# See fstab(5) for details.

# <file system> <dir> <type> <options> <dump> <pass>
UUID=${BOOT_UUID}  /boot   vfat    defaults        0       0
"
}

gen_env() {
	echo "LOOP_DEV=${LOOP_DEV}
	ROOT_UUID=${ROOT_UUID}"
}

gen_uEnv_ini() {
	cat > /boot/uEnv.ini <<'EOF'
dtb_name=/dtbs/amlogic/meson-gxl-s905d-phicomm-n1.dtb
bootargs=root=/dev/sda2 rootflags=data=writeback rw console=ttyAML0,115200n8 console=tty0 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0
EOF

sed -i "s|root=/dev/sda2|root=UUID=${ROOT_UUID}|" /boot/uEnv.ini
}

gen_s905_autoscript() {
	cat > /boot/s905_autoscript.cmd <<'EOF'
setenv env_addr    "0x10400000"
setenv kernel_addr "0x11000000"
setenv initrd_addr "0x13000000"
setenv boot_start booti ${kernel_addr} ${initrd_addr} ${dtb_mem_addr}
if fatload usb 0 ${kernel_addr} Image; then if fatload usb 0 ${initrd_addr} uInitrd; then if fatload usb 0 ${env_addr} uEnv.ini; then env import -t ${env_addr} ${filesize};run cmdline_keys;fi; if fatload usb 0 ${dtb_mem_addr} ${dtb_name}; then run boot_start; else store dtb read ${dtb_mem_addr}; run boot_start;fi;fi;fi;
if fatload usb 1 ${kernel_addr} Image; then if fatload usb 1 ${initrd_addr} uInitrd; then if fatload usb 1 ${env_addr} uEnv.ini; then env import -t ${env_addr} ${filesize};run cmdline_keys;fi; if fatload usb 1 ${dtb_mem_addr} ${dtb_name}; then run boot_start; else store dtb read ${dtb_mem_addr}; run boot_start;fi;fi;fi;
if fatload mmc 1:a ${kernel_addr} Image; then if fatload mmc 1:a ${initrd_addr} uInitrd; then if fatload mmc 1:a ${env_addr} uEnv.ini; then env import -t ${env_addr} ${filesize};run cmdline_keys;fi; if fatload mmc 1:a ${dtb_mem_addr} ${dtb_name}; then run boot_start; else store dtb read ${dtb_mem_addr}; run boot_start;fi;fi;fi;
EOF
}

install_bootloader() {
	gen_uEnv_ini
	gen_s905_autoscript

	pacman --needed -S --noconfirm uboot-tools
	mkimage -C none -A arm -T script -d /boot/s905_autoscript.cmd /boot/s905_autoscript
	mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd -d /boot/initramfs-linux.img /boot/uInitrd
}

add_sudo_user() {
	useradd -m -G wheel -s /bin/bash alarm
	echo "alarm:alarm" | chpasswd
	echo "alarm ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
	pacman --needed -S --noconfirm polkit
}

install_kernel() {
	local url="https://github.com/yangxuan8282/phicomm-n1/releases/download/arch_kernel/linux-amlogic-4.19.2-0-aarch64.pkg.tar.xz"
	curl -LO $url
	pacman --needed -U --noconfirm *.pkg.tar.xz
	rm -f *.pkg.tar.xz
}

enable_systemd_timesyncd() {
	systemctl enable systemd-timesyncd.service
}

install_packer() {
        su alarm sh -c 'cd /tmp && \
        curl -LO https://github.com/archlinuxarm/PKGBUILDs/raw/a1ad4045699093b1cf4911b93cbf8830ee972639/aur/packer/PKGBUILD && \
        makepkg -si --noconfirm'
}

aur_install_packages() {
	su alarm <<-EOF
	packer -S --noconfirm $@
	EOF
}

install_roboto_mono() {
	# the correct way to install Roboto Mono in 2019
	pacman --needed -S --noconfirm curl unzip
	curl -Lo /tmp/RobotoMono.zip https://fonts.google.com/download?family=Roboto%20Mono
	unzip -od /usr/share/fonts/RobotoMono /tmp/RobotoMono.zip
	rm -f /tmp/RobotoMono.zip
}

install_drivers() {
	pacman --needed -S --noconfirm xf86-video-fbdev firmware-raspberrypi haveged
	systemctl enable haveged
	systemctl disable bluetooth.target
}

install_sddm() {
	pacman --needed -S --noconfirm sddm
	sddm --example-config > /etc/sddm.conf
	sed -i "s/^User=/User=alarm/" /etc/sddm.conf
	sed -i "s/^Session=/Session=xfce.desktop/" /etc/sddm.conf
	systemctl enable sddm.service
}

install_network_manager() {
	pacman --needed -S --noconfirm networkmanager crda wireless_tools net-tools
	systemctl enable NetworkManager.service
}

install_ssh_server() {
	pacman --needed -S --noconfirm openssh
	systemctl enable sshd
}

install_browser() {
	pacman --needed -S --noconfirm chromium
}

install_xfce4() {
	pacman --needed -S --noconfirm git xorg-server xorg-xrefresh xfce4 xfce4-goodies \
					xarchiver gvfs gvfs-smb sshfs \
					ttf-roboto arc-gtk-theme \
					pavucontrol \
					network-manager-applet gnome-keyring
	systemctl disable dhcpcd
	install_network_manager
	install_sddm
}

install_xfce4_mods() {
	install_xfce4
	install_roboto_mono
	pacman --needed -S --noconfirm curl
	curl -LO https://github.com/yangxuan8282/PKGBUILDs/raw/master/pkgs/paper-icon-theme-1.5.0-2-any.pkg.tar.xz
	pacman --needed -U --noconfirm paper-icon-theme-1.5.0-2-any.pkg.tar.xz && rm -f paper-icon-theme-1.5.0-2-any.pkg.tar.xz
	mkdir -p /usr/share/wallpapers
	curl https://img2.goodfon.com/original/2048x1820/3/b6/android-5-0-lollipop-material-5355.jpg \
					--output /usr/share/wallpapers/android-5-0-lollipop-material-5355.jpg
	su alarm sh -c 'mkdir -p /home/alarm/.config && \
	curl -Lo- https://github.com/yangxuan8282/dotfiles/archive/master.tar.gz | \
		tar -C /home/alarm/.config -xzf - --strip=2 dotfiles-master/config'
}

install_termite() {
	pacman --needed -S --noconfirm termite
	mkdir -p /home/alarm/.config/termite
	cp /etc/xdg/termite/config /home/alarm/.config/termite/config
	sed -i 's/font = Monospace 9/font = RobotoMono 11/g' /home/alarm/.config/termite/config
	chown -R alarm:alarm /home/alarm/.config
}

install_docker() {
	pacman --needed -S --noconfirm docker docker-compose
	gpasswd -a alarm docker
	systemctl enable docker
}

setup_miscs() {
	ln -sf /usr/share/zoneinfo/Asia/Chongqing /etc/localtime
	echo "en_US.UTF-8 UTF-8" | tee --append /etc/locale.gen
	locale-gen
	echo LANG=en_US.UTF-8 > /etc/locale.conf
	echo alarm > /etc/hostname
	echo "127.0.1.1    alarm.localdomain    alarm" | tee --append /etc/hosts
}

setup_chroot() {
	arch-chroot mnt /bin/bash <<-EOF
		set -xe
		source /root/env_file
		source /root/functions
		rm -f /root/functions /root/env_file
		export http_proxy=${HTTP_PROXY_ARCH}
		export https_proxy=${HTTP_PROXY_ARCH}
		pacman -Syu --noconfirm
		pacman-key --init
		pacman-key --populate archlinuxarm
		echo "root:toor" | chpasswd
		export http_proxy=${HTTP_PROXY_GENERIC}
		export https_proxy=${HTTP_PROXY_GENERIC}
		install_kernel
		setup_miscs
		gen_resize2fs_once_service
		export http_proxy=${HTTP_PROXY_ARCH}
		export https_proxy=${HTTP_PROXY_ARCH}
		install_docker
		enable_systemd_timesyncd
		install_drivers
		install_ssh_server
		install_termite
		install_xfce4_mods
		install_browser
		install_bootloader
EOF
}

umounts() {
	umount mnt/boot
	umount mnt
	losetup -d "$LOOP_DEV"
}

#=======================  F u n c t i o n s  =======================#

pass_function() {
	sed -nE '/^#===.*F u n c t i o n s.*===#/,/^#===.*F u n c t i o n s.*===#/p' "$0"
}


df -h | grep loop | grep mnt
if [[ $? -eq 0 ]]; then
	LOOP_DEV=$(df -h | grep -o '/dev/loop[0,9]' | tail -n1)
	BOOT_DEV="$LOOP_DEV"p1
	ROOT_DEV="$LOOP_DEV"p2
else
	set_system_date
	gen_image
	LOOP_DEV=$(losetup --partscan --show --find "${OUTPUT_IMG}")
	BOOT_DEV="$LOOP_DEV"p1
	ROOT_DEV="$LOOP_DEV"p2
	do_format
fi

setup_mirrors
do_pacstrap
delete_mirrors

IMGID="$(dd if="${OUTPUT_IMG}" skip=440 bs=1 count=4 2>/dev/null | xxd -e | cut -f 2 -d' ')"

BOOT_UUID=$(blkid ${BOOT_DEV} | cut -f 2 -d '"')
ROOT_UUID=$(blkid ${ROOT_DEV} | cut -f 2 -d '"')

gen_fstabs > mnt/etc/fstab

gen_env > mnt/root/env_file

pass_function > mnt/root/functions

setup_chroot

umounts

cat >&2 <<-EOF
	---
	Installation is complete
	Flash to usb disk with: dd if=${OUTPUT_IMG} of=/dev/TARGET_DEV bs=4M status=progress

EOF

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

pacman --needed -S --noconfirm curl
curl -L https://u.nu/cdate | bash
BUILD_DATE="$(date +%Y%m%d)"

usage() {
	cat <<EOF
	Usage: gen-arch-server_n1.sh [options]
	Valid options are:
		-g HTTP_PROXY_GENERIC   Generic HTTP proxy
		                        (default is http://10.82.1.123:1080).
		-a HTTP_PROXY_ARCH      HTTP proxy for the ARCH_MIRROR
		                        (default is http://10.69.130.182:8080).
		-m ARCH_MIRROR          URI of the mirror to fetch packages from
		                        (default is https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm).
		-o OUTPUT_IMG           Output img file
		                        (default is arch-server-n1-BUILD_DATE.img).
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
: ${OUTPUT_IMG:="arch-server-n1-${BUILD_DATE}.img"}

#=======================  F u n c t i o n s  =======================#

gen_image() {
	fallocate -l $(( 3 * 1024 * 1024 *1024 )) "$OUTPUT_IMG"
	cat > fdisk.cmd <<- EOF
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

insert_mirror() {
	sed -i "1i Server = ${ARCH_MIRROR}/\$arch/\$repo" /etc/pacman.d/mirrorlist
}

remove_mirror() {
	sed -i '1d' /etc/pacman.d/mirrorlist
}

do_pacstrap() {
	export http_proxy=${HTTP_PROXY_ARCH}
	export https_proxy=${HTTP_PROXY_ARCH}
	pacstrap mnt base base-devel
}

gen_resize2fs_once_service() {
	cat > /etc/systemd/system/resize2fs-once.service <<- 'EOF'
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

	cat > /usr/local/bin/resize2fs_once <<- 'EOF'
	#!/bin/sh
	set -xe
	ROOT_DEV=$(findmnt / -o source -n)
	ROOT_START=$(fdisk -l $(echo "$ROOT_DEV" | sed -E 's/p?2$//') | grep "$ROOT_DEV" | awk '{ print $2 }')
	cat > /tmp/fdisk.cmd <<- ENDOFCMDS
		d
		2

		n
		p
		2
		${ROOT_START}

		w
	ENDOFCMDS
	fdisk "$(echo "$ROOT_DEV" | sed -E 's/p?2$//')" < /tmp/fdisk.cmd
	rm -f /tmp/fdisk.cmd
	partprobe
	resize2fs "$ROOT_DEV"
	systemctl disable resize2fs-once
	EOF

	chmod +x /usr/local/bin/resize2fs_once
	systemctl enable resize2fs-once
}

gen_extra_ip_service() {
	cat > /etc/systemd/system/extra-ip.service <<- EOF
		[Unit]
		Description=Add an extra IP for eth0
		After=network-online.target sshd.service

		[Service]
		Type=oneshot
		RemainAfterExit=true
		ExecStart=/usr/bin/ip addr add dev eth0 10.69.144.100/24

		[Install]
		WantedBy=multi-user.target
	EOF
	systemctl enable extra-ip.service
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
	cat > /boot/uEnv.ini <<- 'EOF'
		dtb_name=/dtbs/amlogic/meson-gxl-s905d-phicomm-n1.dtb
		bootargs=root=/dev/sda2 rootflags=data=writeback rw console=ttyAML0,115200n8 console=tty0 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0
	EOF

sed -i "s|root=/dev/sda2|root=UUID=${ROOT_UUID}|" /boot/uEnv.ini
}

gen_s905_autoscript() {
	cat > /boot/s905_autoscript.cmd <<- 'EOF'
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

install_kernel() {
	local url="https://github.com/yangxuan8282/phicomm-n1/releases/download/arch_kernel/linux-amlogic-4.19.2-0-aarch64.pkg.tar.xz"
	curl -LO $url
	pacman --needed -U --noconfirm *.pkg.tar.xz
	rm -f *.pkg.tar.xz
}

enable_systemd_timesyncd() {
	systemctl enable systemd-timesyncd.service
}

install_drivers() {
	pacman --needed -S --noconfirm xf86-video-fbdev firmware-raspberrypi haveged
	systemctl enable haveged
	systemctl disable bluetooth.target
}

install_network_manager() {
	pacman --needed -S --noconfirm networkmanager crda wireless_tools net-tools
	systemctl enable NetworkManager.service
}

install_ssh_server() {
	pacman --needed -S --noconfirm openssh
	systemctl enable sshd
	ssh-keygen -t rsa -N '' -f ~/.ssh/for_n1_rsa
	cat > ~/.ssh/authorized_keys <<< "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC792G3BGf1JVCKRc+ZJYx2YolaL3TrVetC6phNF1sYCYubB9zlffJukGNlbWLNFVtQmpWtGLHOJc6L4YgcwOcGkSX6d8s8pFC/5sO8DEffTZDX/PSO+AlwToGBo6daFvhk5T8eO6HL/soyUc5chKqXcytyyxVEnyVPnmDEVR6GRq4yhrgi4E9lnKYxY326WyDBw6tVq+7LlGhGd846EoHIlrEy2qHDqiFvQATvg+pKkbtHWozOQ0Sid4KJ4CJzX/Il2vb9vW5NZznbxt8JrKj27RLOElFirGGgWmbp2L5dpYSHJkz1vbceeLGqzjkgWzblBvDH+y1Yc8Mp0XL/vCvhbiIcBFZjkd+xMY5TvZ2S35aNEqIOHD6pF3+AELwGuSDpETSz5Sw2OmwR/5K4Spcg89aLKqhq4TOASq/7SFKGweFMF8GENeh6wA2pgqG2Fq3qtRcKbfO1Cm0iIAjtI4xkVGqRu9jeaB5sL73D8aph4ibuX2Q0aTnIdj1pTM1DIk8= root"
}

enable_dhcpcd() {
	systemctl enable dhcpcd@eth0.service
	systemctl enable dhcpcd@wlan0.service
}

setup_miscs() {
	ln -sf /usr/share/zoneinfo/Asia/Chongqing /etc/localtime
	echo "en_US.UTF-8 UTF-8" | tee --append /etc/locale.gen
	locale-gen
	echo LANG=en_US.UTF-8 > /etc/locale.conf
	echo n1 > /etc/hostname
	echo "127.0.1.1	n1.localdomain n1" | tee --append /etc/hosts
	pacman --needed -S --noconfirm vim
	tee --append /etc/profile <<- EOF
		stty stop undef
		export EDITOR=vim
		export http_proxy=${http_proxy}
		export http_proxy=${http_proxy}
	EOF
}

chroot_then_setup() {
	arch-chroot mnt /bin/bash <<- EOF
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
		gen_extra_ip_service
		export http_proxy=${HTTP_PROXY_ARCH}
		export https_proxy=${HTTP_PROXY_ARCH}
		enable_systemd_timesyncd
		install_drivers
		install_network_manager
		install_ssh_server
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
	sed -nE '/^#==.*F u n c t i o n s.*==#/,/^#==.*F u n c t i o n s.*==#/p' "$0"
}

LO_COUNT=$(blkid | grep loop | wc -l)
if [[ ${LO_COUNT} -eq 0 ]]; then
	gen_image
	LOOP_DEV=$(losetup --partscan --show --find "${OUTPUT_IMG}")
	BOOT_DEV="$LOOP_DEV"p1
	ROOT_DEV="$LOOP_DEV"p2
	do_format
else
	LOOP_DEV=$(df -h | grep -o '/dev/loop[0,9]' | tail -n1)
	BOOT_DEV="$LOOP_DEV"p1
	ROOT_DEV="$LOOP_DEV"p2
fi

insert_mirror
do_pacstrap
remove_mirror
IMGID="$(dd if="${OUTPUT_IMG}" skip=440 bs=1 count=4 2>/dev/null | xxd -e | cut -f 2 -d' ')"
BOOT_UUID=$(blkid ${BOOT_DEV} | cut -f 2 -d '"')
ROOT_UUID=$(blkid ${ROOT_DEV} | cut -f 2 -d '"')
gen_fstabs > mnt/etc/fstab
gen_env > mnt/root/env_file
pass_function > mnt/root/functions
chroot_then_setup
umounts

cat >&2 <<- EOF
	---
	Installation is complete
	Flash to usb disk with: dd if=${OUTPUT_IMG} of=/dev/TARGET_DEV bs=4M status=progress
	---
EOF

#!/bin/sh

# Author:       Ahmed Elhori <dev@elhori.com>
# License:      GNU GPLv3
# Description:  Arch install script

# ENV
KEYBOARD_LAYOUT=
WANT_CLEAN_DRIVE=
WANT_ENCRYPTION=
DRIVE_NAME=
BOOT_SIZE=
SWAP_SIZE=
TIMEZONE_REGION=
TIMEZONE_CITY=
LOCALE='en_US.UTF-8'
HOSTNAME=
EXTRA_PACKAGES=

# Configs
set -e
SCRIPT_NAME="$(basename "$0")"
PACKAGE_LIST='base linux linux-firmware vim networkmanager grub bash-completion'

print_error(){
	message="$1"
	echo "${SCRIPT_NAME} - Error: ${message}" >&2
}

ask_yes_no(){
	answer="$1"
	question="$2"
	while ! printf '%s' "$answer" | grep -q '^\([Yy]\(es\)\?\|[Nn]\(o\)\?\)$'; do
		printf '%s' "${question} [Y]es/[N]o: "
		read -r answer
	done

	if printf '%s' "$answer" | grep -q '^[Nn]\(o\)\?$'; then
		return 1
	fi
}

check_root(){
	if [ "$(id -u)" -ne '0' ]; then
		print_error 'This script needs root privileges.'
		exit 1
	fi
}

set_keyboard_layout(){
	if [ -z "$KEYBOARD_LAYOUT" ]; then
		printf 'Enter the keyboard layout name, or press enter for the default layout (us): '
		read -r KEYBOARD_LAYOUT
	fi

	if [ -z "$KEYBOARD_LAYOUT" ]; then
		KEYBOARD_LAYOUT='us'
	fi

	if ls /usr/share/kbd/keymaps/**/*"$KEYBOARD_LAYOUT"*.map.gz >/dev/null 2>&1; then
		loadkeys "$KEYBOARD_LAYOUT"
	else
		print_error "Keyboard layout not found"
		KEYBOARD_LAYOUT=
		set_keyboard_layout
	fi
}

verify_boot_mode(){
	if [ -d /sys/firmware/efi/efivars ]; then
		boot_mode='uefi'
	else
		boot_mode='bios'
	fi
}

update_system_clock(){
	timedatectl set-ntp true >/dev/null 2>&1
}

get_drive_name(){
	drive_list="$(lsblk -d | tail +2 | sed -n 's/^\(\S*\).*$/\1/p' | nl)"
	if [ -z "$DRIVE_NAME" ]; then
		drive_number=
		while [ -z "$drive_number" ]; do
			printf "$drive_list\n"
			printf 'Enter the number of the desired drive to be affected: '
			read -r drive_number
			DRIVE_NAME="$(printf "$drive_list" | sed -n 's/^\s*'"$drive_number"'\s*\(.*\)$/\1/p')"
		done
	fi

	if ! [ -b /dev/"$DRIVE_NAME" ]; then
		print_error "Drive \"${DRIVE_NAME}\" not found."
		DRIVE_NAME=
		get_drive_name
	fi
}

get_partition_path(){
	boot_path="$(blkid | grep "/dev/${DRIVE_NAME}.*1" | sed -n 's/^\(\/dev\/'"$DRIVE_NAME"'.*1\):\s\+.*$/\1/p')"
	swap_path="$(blkid | grep "/dev/${DRIVE_NAME}.*2" | sed -n 's/^\(\/dev\/'"$DRIVE_NAME"'.*2\):\s\+.*$/\1/p')"
	root_path="$(blkid | grep "/dev/${DRIVE_NAME}.*3" | sed -n 's/^\(\/dev\/'"$DRIVE_NAME"'.*3\):\s\+.*$/\1/p')"
}

get_partition_uuid(){
	root_uuid="$(blkid | grep "$root_path" | sed -n 's/^.*\s\+UUID="\(\S*\)".*$/\1/p')"
	swap_uuid="$(blkid | grep "$swap_path" | sed -n 's/^.*\s\+UUID="\(\S*\)".*$/\1/p')"
}

clean_drive(){
	set +e
	dd if=/dev/urandom > /dev/"$DRIVE_NAME" bs=4096 status=progress
	set -e
}

encrypt_drive(){
	set +e
	cryptsetup -y -v -q luksFormat "$root_path"
	if [ "$?" -eq 0 ]; then
		cryptsetup open "$root_path" croot
	else
		encrypt_drive
	fi
	set -e
}

partion_disk(){
	get_drive_name

	if	ask_yes_no "$WANT_CLEAN_DRIVE" 'Do you want to clean the drive? This may take a long time.'; then
		WANT_CLEAN_DRIVE='yes'
		clean_drive
	else
		WANT_CLEAN_DRIVE='no'
	fi

	while ! [ "$BOOT_SIZE" -ge 0 ] 2> /dev/null; do
		printf 'Enter boot partition size in MiB (e.g. 512): '
		read -r BOOT_SIZE
	done

	while ! [ "$SWAP_SIZE" -ge 0 ] 2> /dev/null; do
		printf 'Enter swap partition size in MiB (e.g. 4096): '
		read -r SWAP_SIZE
	done

	if [ "$boot_mode" = 'uefi' ]; then
		sfdisk -W always /dev/"$DRIVE_NAME" <<- EOF
			label: gpt
			size=${BOOT_SIZE}MiB, type=uefi, bootable
			size=${SWAP_SIZE}MiB, type=swap
			type=linux
		EOF
	else
		sfdisk -W always /dev/"$DRIVE_NAME" <<- EOF
			label: dos
			size=${BOOT_SIZE}MiB, type=linux, bootable
			size=${SWAP_SIZE}MiB, type=swap
			type=linux
		EOF
	fi

	get_partition_path

	if ask_yes_no "$WANT_ENCRYPTION" 'Do you want encryption?'; then
		WANT_ENCRYPTION='yes'
		encrypt_drive
	else
		WANT_ENCRYPTION='no'
	fi
}

format_partition(){
	if ask_yes_no "$WANT_ENCRYPTION"; then
		mkfs.ext4 /dev/mapper/croot
		mkfs.ext2 -L cswap "$swap_path" 1M
	else
		mkfs.ext4 "$root_path"
		mkswap "$swap_path"
	fi

	if [ "$boot_mode" = 'uefi' ]; then
		mkfs.fat -F32 "$boot_path"
	else
		mkfs.ext4 "$boot_path"
	fi
}

mount_file_system(){
	if ask_yes_no "$WANT_ENCRYPTION"; then
		mount /dev/mapper/croot /mnt
	else
		mount "$root_path" /mnt
		swapon "$swap_path"
	fi
	mkdir /mnt/boot
	mount "$boot_path" /mnt/boot
}

install_essential_packages(){
	pacstrap /mnt $PACKAGE_LIST
}

generate_fstab(){
	genfstab -U /mnt >> /mnt/etc/fstab
	if ask_yes_no "$WANT_ENCRYPTION"; then
		echo '/dev/mapper/swap        none            swap            defaults   0   0' >> /mnt/etc/fstab
	fi
}

copy_script_to_chroot(){
	cp "$0" /mnt/root/script.sh
	cat <<-EOF > /mnt/root/env.sh
	export KEYBOARD_LAYOUT=${KEYBOARD_LAYOUT}
	export boot_mode=${boot_mode}
	export DRIVE_NAME=${DRIVE_NAME}
	export BOOT_SIZE=${BOOT_SIZE}
	export SWAP_SIZE=${SWAP_SIZE}
	export TIMEZONE_REGION=${TIMEZONE_REGION}
	export TIMEZONE_CITY=${TIMEZONE_CITY}
	export LOCALE=${LOCALE}
	export HOSTNAME=${HOSTNAME}
	export WANT_ENCRYPTION=${WANT_ENCRYPTION}
	EOF
	chmod 700 /mnt/root/script.sh
}

run_arch_chroot(){
	arch-chroot /mnt /bin/sh -c '/root/script.sh 'part2''
}

finish_and_reboot(){
	umount -R /mnt
	echo 'Rebooting in 5Sec'
	sleep 5
	reboot
}

source_env(){
	. /root/env.sh
}

set_time_zone(){
	while [ -z "$TIMEZONE_REGION" ] || [ -z "$TIMEZONE_CITY" ]; do
		printf 'Enter the name of your Region (e.g., Europe): '
		read -r TIMEZONE_REGION
		printf 'Enter the timezone name of your city (e.g., Berlin): '
		read -r TIMEZONE_CITY
	done

	if [ -f /usr/share/zoneinfo/"$TIMEZONE_REGION"/"$TIMEZONE_CITY" ]; then
		ln -sf /usr/share/zoneinfo/"$TIMEZONE_REGION"/"$TIMEZONE_CITY" /etc/localtime
	else
		print_error "The specified Region, and/or city were not found."
		TIMEZONE_REGION=
		TIMEZONE_CITY=
		set_time_zone
	fi
}

set_hardware_clock(){
	hwclock --systohc
}

set_locale(){
	sed -i '0,/^\s*#\+\s*\('"$LOCALE"'.*\)$/ s/^\s*#\+\s*\('"$LOCALE"'.*\)$/\1/' /etc/locale.gen
	locale-gen
	echo "LANG=${LOCALE}" > /etc/locale.conf
}

set_vconsole(){
	echo "KEYMAP=${KEYBOARD_LAYOUT}" > /etc/vconsole.conf
}

configure_network(){
	while [ -z "$HOSTNAME" ]; do
		printf 'Enter hostname: '
		read -r HOSTNAME
	done

	echo "$HOSTNAME" > /etc/hostname

	cat <<- EOF > /etc/hosts
	127.0.0.1	localhost
	::1		localhost
	127.0.1.1	"${HOSTNAME}".localdomain	"${HOSTNAME}"
	EOF
}

install_boot_loader(){
	if [ "$boot_mode" = 'uefi' ]; then
		# grub-install --target=x86_64-efi --efi-directory=/boot/EFI --bootloader-id=GRUB
		bootctl install
		cp /usr/share/systemd/bootctl/arch.conf /boot/loader/entries/
		echo 'default arch.conf' > /boot/loader/loader.conf
		sed -i 's/^\s*options.*$/options root=UUID='"$root_uuid"' rw/' /boot/loader/entries/arch.conf
	else
		grub-install --target=i386-pc /dev/"$DRIVE_NAME"
		grub-mkconfig -o /boot/grub/grub.cfg
	fi
}

configure_boot_loader(){
	if ask_yes_no "$WANT_ENCRYPTION"; then
		echo "swap      UUID=${swap_uuid}    /dev/urandom swap,offset=2048,cipher=aes-xts-plain64,size=512" >> /etc/crypttab
		if [ "$boot_mode" = 'uefi' ]; then
			sed -i 's/^\s*HOOKS=.*$/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
			sed -i 's/^\s*options.*$/options rd\.luks\.name='"$root_uuid"'=croot root=\/dev\/mapper\/croot/' /boot/loader/entries/arch.conf
		else
			sed -i 's/^\s*HOOKS=.*$/HOOKS=(base udev autodetect keyboard keymap consolefont modconf block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
			sed -i 's/^\s*GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/GRUB_CMDLINE_LINUX_DEFAULT="\1 cryptdevice=UUID='"$root_uuid"':croot root=\/dev\/mapper\/croot"/' /etc/default/grub
			grub-mkconfig -o /boot/grub/grub.cfg
		fi
	fi
}

setup_initramfs(){
	mkinitcpio -P
}

change_root_password(){
	set +e
	echo 'Change root password..'
	passwd
	set -e
}

run_part2(){
	source_env
	set_time_zone
	set_hardware_clock
	set_locale
	set_vconsole
	configure_network
	get_partition_path
	get_partition_uuid
	install_boot_loader
	configure_boot_loader
	setup_initramfs
	change_root_password
	set +e; final_commands; set -e
	exit
}

run_part1(){
	check_root
	set_keyboard_layout
	verify_boot_mode
	update_system_clock
	partion_disk
	format_partition
	mount_file_system
	install_essential_packages
	generate_fstab
	copy_script_to_chroot
	run_arch_chroot
	finish_and_reboot
}

main(){
	if [ "$1" = 'part2' ];then
		run_part2 "$@"
	else
		run_part1 "$@"
	fi
}

main "$@"

#!/bin/sh

# Author:       Ahmed Elhori <dev@elhori.com>
# License:      GNU GPLv3
# Description:  Arch install script

# ENV
set -e
NAME="$(basename "$0")"

keyboard_layout=
want_clean_drive=
want_encryption=
drive_name=

print_error(){
	message="$1"
	echo "${NAME} - Error: ${message}" >&2
}

ask_yes_no(){
	answer="$1"
	question="$2"
	while ! printf "$answer" | grep -q '^\([Yy]\(es\)\?\|[Nn]\(o\)\?\)$'
	do
		printf "${question} [Y]es/[N]o: "
		read answer
	done

	if printf "$answer" | grep -q '^[Nn]\(o\)\?$'; then
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
	printf 'Enter the keyboard layout name, or press enter for the default layout (us): '
	read keyboard_layout

	if [ -z "$keyboard_layout" ]; then
		keyboard_layout='us'
	fi

	if ! ls /usr/share/kbd/keymaps/**/*"$keyboard_layout"*.map.gz; then
		print_error "Keyboard layout not found"
		keyboard_layout=''
		set_keyboard_layout
	else
		loadkeys "$keyboard_layout"
	fi
}

verify_boot_mode(){
	if ls /sys/firmware/efi/efivars >/dev/null 2>&1; then
		boot_mode='uefi'
	else
		boot_mode='bios'
	fi
}

update_system_clock(){
	timedatectl set-ntp true
}

clean_dirve(){
	return
}

encrypt_drive(){
	return
}

get_drive_name(){
	lsblk
	printf "Enter the name of the desired drive to be affected (e.g., sda): "
	read drive_name
}

partion_disk(){
	while [ -z "$drive_name" ]; do
		get_drive_name
		while ! ls /dev/"$drive_name" 2>&1 >/dev/null; do
			print_error "Drive \"${drive_name}\" not found."
			get_drive_name
		done
	done

	if ask_yes_no "$want_encryption" 'Do you want to encryption?'; then
		if	ask_yes_no "$want_clean_drive" 'Do you want to clean the drive? This may take a long time.'; then
			clean_dirve
		fi
		encrypt_drive
	fi

	if [ "$boot_mode" = 'uefi' ]; then
		sfdisk -W /dev/"$drive_name" <<- EOF
			label: gpt
			size=512MiB, type=uefi, bootable
			size=4GiB, type=swap
			type=linux
		EOF
	else
		sfdisk -W /dev/"$drive_name" <<- EOF
			label: dos
			size=512MiB, type=linux, bootable
			size=4GiB, type=swap
			type=linux
		EOF
	fi
}

get_partition_path(){
	boot_path="$(blkid | grep "/dev/${drive_name}.*1" | sed -n 's/^\(\/dev\/'"${drive_name}"'.*1\):\s\+.*$/\1/p')"
	swap_path="$(blkid | grep "/dev/${drive_name}.*2" | sed -n 's/^\(\/dev\/'"${drive_name}"'.*2\):\s\+.*$/\1/p')"
	root_path="$(blkid | grep "/dev/${drive_name}.*3" | sed -n 's/^\(\/dev\/'"${drive_name}"'.*3\):\s\+.*$/\1/p')"
}

format_partition(){
	if [ "$boot_mode" = 'uefi' ]; then
		mkfs.fat -F32 "$boot_path"
		mkswap "$swap_path"
		mkfs.ext4 "$root_path"
	else
		mkfs.ext4 "$boot_path"
		mkswap "$swap_path"
		mkfs.ext4 "$root_path"
	fi
}

mount_file_system(){
	mount "$root_path" /mnt
	mkdir /mnt/boot
	mount "$boot_path" /mnt/boot
	swapon "$swap_path"
}

install_essential_packages(){
	pacstrap /mnt base linux linux-firmware vim networkmanager
}

generate_fstab(){
	genfstab -U /mnt >> /mnt/etc/fstab
}

run_arch_chroot(){
	arch-chroot /mnt
}

main(){
	check_root
	set_keyboard_layout
	verify_boot_mode
	update_system_clock
	partion_disk
	get_partition_path
	format_partition
	mount_file_system
	install_essential_packages
	generate_fstab
	run_arch_chroot
}

main "$@"

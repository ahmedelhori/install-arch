#!/bin/bash

# Author:       Ahmed Elhori <dev@elhori.com>
# License:      GNU GPLv3
# Description:  Arch install script

# ENV
set -e
NAME="$(basename "$0")"
package_list='base linux linux-firmware vim networkmanager intel-ucode grub bash-completion'
keyboard_layout=
want_clean_drive=
want_encryption=
drive_name=
timezone_region=
timezone_city=
locale=en_US.UTF-8
hostname=

print_error(){
	message="$1"
	echo "${NAME} - Error: ${message}" >&2
}

ask_yes_no(){
	answer="$1"
	question="$2"
	while ! printf "$answer" | grep -q '^\([Yy]\(es\)\?\|[Nn]\(o\)\?\)$'; do
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
	if [ -z "$keyboard_layout" ]; then
		printf 'Enter the keyboard layout name, or press enter for the default layout (us): '
		read keyboard_layout

		if [ -z "$keyboard_layout" ]; then
			keyboard_layout='us'
		fi
	fi

	if ls /usr/share/kbd/keymaps/**/*"$keyboard_layout"*.map.gz >/dev/null 2>&1; then
		loadkeys "$keyboard_layout"
	else
		print_error "Keyboard layout not found"
		keyboard_layout=
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
	while [ -z "$drive_name" ]; do
		lsblk
		printf "Enter the name of the desired drive to be affected (e.g., sda): "
		read drive_name
	done

	if ! [ -b /dev/"$drive_name" ]; then
		print_error "Drive \"${drive_name}\" not found."
		drive_name=
		get_drive_name
	fi
}

get_partition_path(){
	boot_path="$(blkid | grep "/dev/${drive_name}.*1" | sed -n 's/^\(\/dev\/'"$drive_name"'.*1\):\s\+.*$/\1/p')"
	swap_path="$(blkid | grep "/dev/${drive_name}.*2" | sed -n 's/^\(\/dev\/'"$drive_name"'.*2\):\s\+.*$/\1/p')"
	root_path="$(blkid | grep "/dev/${drive_name}.*3" | sed -n 's/^\(\/dev\/'"$drive_name"'.*3\):\s\+.*$/\1/p')"
}

clean_dirve(){
	set +e
	dd if=/dev/urandom > /dev/"$drive_name" bs=4096 status=progress
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

	if	ask_yes_no "$want_clean_drive" 'Do you want to clean the drive? This may take a long time.'; then
		want_clean_drive='yes'
		clean_dirve
	else
		want_clean_drive='no'
	fi

	if [ "$boot_mode" = 'uefi' ]; then
		sfdisk -W always /dev/"$drive_name" <<- EOF
			label: gpt
			size=512MiB, type=uefi, bootable
			size=4GiB, type=swap
			type=linux
		EOF
	else
		sfdisk -W always /dev/"$drive_name" <<- EOF
			label: dos
			size=512MiB, type=linux, bootable
			size=4GiB, type=swap
			type=linux
		EOF
	fi

	get_partition_path

	if ask_yes_no "$want_encryption" 'Do you want encryption?'; then
		want_encryption='yes'
		encrypt_drive
	else
		want_encryption='no'
	fi
}

format_partition(){
	if ask_yes_no "$want_encryption"; then
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
	if ask_yes_no "$want_encryption"; then
		mount /dev/mapper/croot /mnt
	else
		mount "$root_path" /mnt
		swapon "$swap_path"
	fi
	mkdir /mnt/boot
	mount "$boot_path" /mnt/boot
}

install_essential_packages(){
	pacstrap /mnt $package_list
}

generate_fstab(){
	genfstab -U /mnt >> /mnt/etc/fstab
	if ask_yes_no "$want_encryption"; then
		echo '/dev/mapper/swap        none            swap            defaults   0   0' >> /mnt/etc/fstab
	fi
}

copy_script_to_chroot(){
	cp "$0" /mnt/root/script.sh
	cat <<-EOF > /mnt/root/env.sh
	export keyboard_layout=${keyboard_layout}
	export boot_mode=${boot_mode}
	export drive_name=${drive_name}
	export timezone_region=${timezone_region}
	export timezone_city=${timezone_city}
	export locale=${locale}
	export hostname=${hostname}
	export want_encryption=${want_encryption}
	export boot_path=${boot_path}
	export swap_path=${swap_path}
	export root_path=${root_path}
	EOF
}

run_arch_chroot(){
	arch-chroot /mnt /bin/bash -c 'source /root/env.sh; bash /root/script.sh part2'
}

finish_and_reboot(){
	umount -R /mnt
	echo 'Rebooting in 5Sec'
	sleep 5
	reboot
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

set_time_zone(){
	while [ -z "$timezone_region" ] || [ -z "$timezone_city" ]; do
		printf 'Enter the name of your Region (e.g., Europe): '
		read timezone_region
		printf 'Enter the timezone name of your city (e.g., Berlin): '
		read timezone_city
	done

	if [ -f /usr/share/zoneinfo/"$timezone_region"/"$timezone_city" ]; then
		ln -sf /usr/share/zoneinfo/"$timezone_region"/"$timezone_city" /etc/localtime
	else
		print_error "The specified Region, and/or city were not found."
		timezone_region=
		timezone_city=
		set_time_zone
	fi
}

set_hardware_clock(){
	hwclock --systohc
}

set_locale(){
	sed -i '0,/^\s*#\+\s*\('"$locale"'.*\)$/ s/^\s*#\+\s*\('"$locale"'.*\)$/\1/' /etc/locale.gen
	locale-gen
	echo "LANG=${locale}" > /etc/locale.conf
}

set_vconsole(){
	echo "KEYMAP=${keyboard_layout}" > /etc/vconsole.conf
}

configure_network(){
	while [ -z "$hostname" ]; do
		printf 'Enter hostname: '
		read hostname
	done

	echo "$hostname" > /etc/hostname

	cat <<- EOF > /etc/hosts
	127.0.0.1	localhost
	::1		localhost
	127.0.1.1	"${hostname}".localdomain	"${hostname}"
	EOF
}

install_boot_loader(){
	if [ "$boot_mode" = 'uefi' ]; then
		# grub-install --target=x86_64-efi --efi-directory=/boot/EFI --bootloader-id=GRUB
		bootctl install
		cp /usr/share/systemd/bootctl/arch.conf /boot/loader/entries/
	else
		grub-install --target=i386-pc /dev/"$drive_name"
		grub-mkconfig -o /boot/grub/grub.cfg
	fi
}

configure_boot_loader(){
	if ask_yes_no "$want_encryption"; then
		root_uuid="$(blkid | grep "$root_path" | sed -n 's/^.*\s\+UUID="\(\S*\)".*$/\1/p')"
		swap_uuid="$(blkid | grep "$swap_path" | sed -n 's/^.*\s\+UUID="\(\S*\)".*$/\1/p')"
		echo "swap      UUID=${swap_uuid}    /dev/urandom swap,offset=2048,cipher=aes-xts-plain64,size=512" >> /etc/crypttab
		if [ "$boot_mode" = 'uefi' ]; then
			sed -i 's/^\s*HOOKS=.*$/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
			sed -i 's/^\s*\(options\).*$/\1 rd\.luks\.name='"$root_uuid"'=croot root=\/dev\/mapper\/croot/' /boot/loader/entries/arch.conf
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
	passwd
	set -e
}

run_part2(){
	set_time_zone
	set_hardware_clock
	set_locale
	set_vconsole
	configure_network
	install_boot_loader
	configure_boot_loader
	setup_initramfs
	change_root_password
	exit
}

main(){
	if [ "$1" = 'part2' ];then
		run_part2 "$@"
	else
		run_part1 "$@"
	fi
}

main "$@"

#!/bin/sh

# Author:       Ahmed Elhori <dev@elhori.com>
# License:      GNU GPLv3
# Description:  Arch install script

set -e
SCRIPT_NAME="$(basename "$0")"
SCRIPT_PATH="$(dirname "$0")"
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

source_env(){
	if [ -f "${SCRIPT_PATH}/.env" ]; then
		source "${SCRIPT_PATH}/.env"
	fi
}

install_warning(){
	if ! ask_yes_no "$AGREE_INSTALL_WARNING" 'Warning! This script should only be run inside an Archlinux bootable usb environment as it can/will format your drive. Continue?'; then
		exit 1
	fi
}

get_user_input(){
	get_drive_name
	get_parition_sizes
	ask_want_clean_drive
	ask_want_encryption
	get_keyboard_layout
	get_time_zone
	get_locale
	get_hostname
}

get_drive_name(){
	drive_list="$(lsblk -d | tail +2 | nl)"
	if [ -z "$DRIVE_NAME" ]; then
		drive_number=
		while [ -z "$drive_number" ]; do
			printf "$drive_list\n"
			printf 'Enter the number of the desired drive to be affected: '
			read -r drive_number
			DRIVE_NAME="$(printf "$drive_list" | sed -n 's/^\s*'"$drive_number"'\s\+\(\S*\).*$/\1/p')"
		done
	fi

	if ! [ -b /dev/"$DRIVE_NAME" ]; then
		print_error "Drive \"${DRIVE_NAME}\" not found."
		DRIVE_NAME=
		get_drive_name
	fi
}

get_parition_sizes(){
	while ! [ "$BOOT_SIZE" -ge 0 ] 2> /dev/null; do
		printf 'Enter boot partition size in MiB (e.g. 512): '
		read -r BOOT_SIZE
	done

	while ! [ "$SWAP_SIZE" -ge 0 ] 2> /dev/null; do
		printf 'Enter swap partition size in MiB (e.g. 4096): '
		read -r SWAP_SIZE
	done
}

ask_want_clean_drive(){
	if	ask_yes_no "$WANT_CLEAN_DRIVE" 'Do you want to clean the drive? This may take very a long time.'; then
		WANT_CLEAN_DRIVE='yes'
	else
		WANT_CLEAN_DRIVE='no'
	fi
}

ask_want_encryption(){
	if ask_yes_no "$WANT_ENCRYPTION" 'Do you want encryption?'; then
		WANT_ENCRYPTION='yes'
	else
		WANT_ENCRYPTION='no'
	fi
}

get_keyboard_layout(){
	if [ -z "$KEYBOARD_LAYOUT" ]; then
		printf 'Enter the keyboard layout name, or press enter for the default layout (us): '
		read -r KEYBOARD_LAYOUT
	fi

	if [ -z "$KEYBOARD_LAYOUT" ]; then
		KEYBOARD_LAYOUT='us'
	fi

	if ! ls /usr/share/kbd/keymaps/**/*"$KEYBOARD_LAYOUT"*.map.gz >/dev/null 2>&1; then
		print_error "Keyboard layout not found"
		KEYBOARD_LAYOUT=
		set_keyboard_layout
	fi
}

get_time_zone(){
	while [ -z "$TIMEZONE_REGION" ] || [ -z "$TIMEZONE_CITY" ]; do
		printf 'Enter the name of your Region (e.g., Europe): '
		read -r TIMEZONE_REGION
		printf 'Enter the timezone name of your city (e.g., Berlin): '
		read -r TIMEZONE_CITY
	done

	if ! [ -f /usr/share/zoneinfo/"$TIMEZONE_REGION"/"$TIMEZONE_CITY" ]; then
		print_error "The specified Region, and/or city were not found."
		TIMEZONE_REGION=
		TIMEZONE_CITY=
		get_time_zone
	fi
}

get_locale(){
	if [ -z "$LOCALE" ]; then
		printf 'Enter the desired locale, or press enter for the default locale (en_US.UTF-8): '
		read -r LOCALE
	fi

	if [ -z "$LOCALE" ]; then
		LOCALE='en_US.UTF-8'
	fi

	if ! grep -q "^#\?${LOCALE}.*\$" /etc/locale.gen; then
		print_error "Locale \"${LOCALE}\" not found."
		LOCALE=
		get_locale
	fi
}

get_hostname(){
	while [ -z "$HOSTNAME" ]; do
		printf 'Enter hostname: '
		read -r HOSTNAME
	done
}

update_system_clock(){
	timedatectl set-ntp true >/dev/null 2>&1
}

set_keyboard_layout(){
	loadkeys "$KEYBOARD_LAYOUT"
}

unmount_mnt(){
	set +e
	umount -R /mnt
	set -e
}

verify_boot_mode(){
	if [ -d /sys/firmware/efi/efivars ]; then
		boot_mode='uefi'
	else
		boot_mode='bios'
	fi
}

clean_drive(){
	if	ask_yes_no "$WANT_CLEAN_DRIVE"; then
		set +e
		dd if=/dev/urandom > /dev/"$DRIVE_NAME" bs=4096 status=progress
		set -e
	fi
}

partion_disk(){
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
}

encrypt_drive(){
	if ask_yes_no "$WANT_ENCRYPTION"; then
		set +e
		cryptsetup -y -v -q luksFormat "$root_path"
		if [ "$?" -eq 0 ]; then
			cryptsetup open "$root_path" croot
		else
			encrypt_drive
		fi
		set -e
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
	cp "$0" "/mnt/root/${SCRIPT_NAME}"
	cat <<-EOF > /mnt/root/.env
	KEYBOARD_LAYOUT=${KEYBOARD_LAYOUT}
	boot_mode=${boot_mode}
	DRIVE_NAME=${DRIVE_NAME}
	BOOT_SIZE=${BOOT_SIZE}
	SWAP_SIZE=${SWAP_SIZE}
	TIMEZONE_REGION=${TIMEZONE_REGION}
	TIMEZONE_CITY=${TIMEZONE_CITY}
	LOCALE=${LOCALE}
	HOSTNAME=${HOSTNAME}
	WANT_ENCRYPTION=${WANT_ENCRYPTION}
	EOF
	chmod 700 "/mnt/root/${SCRIPT_NAME}"
}

run_arch_chroot(){
	arch-chroot /mnt /bin/sh -c "/mnt/root/${SCRIPT_NAME} 'part2'"
}

reboot_system(){
	echo 'Rebooting in 5Sec'
	sleep 5
	reboot
}

set_time_zone(){
		ln -sf /usr/share/zoneinfo/"$TIMEZONE_REGION"/"$TIMEZONE_CITY" /etc/localtime
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
	exit
}

run_part1(){
	check_root
	source_env
	install_warning
	get_user_input
	update_system_clock
	set_keyboard_layout
	unmount_mnt
	verify_boot_mode
	clean_drive
	partion_disk
	get_partition_path
	get_partition_uuid
	encrypt_drive
	format_partition
	mount_file_system
	install_essential_packages
	generate_fstab
	copy_script_to_chroot
	run_arch_chroot
	unmount_mnt
	reboot_system
}

main(){
	if [ "$1" = 'part2' ];then
		run_part2 "$@"
	else
		run_part1 "$@"
	fi
}

main "$@"

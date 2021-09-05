# install-arch
A script to automate arch linux installation

# Caution
It's not fool proof! yet...

# Usage
## After you've booted into the Arch Linux live environment:

You could either run this script directly with the following command:
```
sh install-arch.sh
```
Or fill the Empty variable fields before running the script.

# Example
`install-arch.sh`
```
..
...
# ENV
set -e
NAME="$(basename "$0")"
package_list='base linux linux-firmware vim networkmanager intel-ucode grub bash-completion'
keyboard_layout=de
want_clean_drive=n
want_encryption=y
drive_name=sda
timezone_region=Europe
timezone_city=Berlin
locale=en_US.UTF-8
hostname=mypc
...
..
```

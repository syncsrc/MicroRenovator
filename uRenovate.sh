#!/bin/bash

set -euo pipefail
#set -x

edk2_dir="$(pwd)/edk2/"

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root" 
   exit 1
fi

## Install intel microcode tool
if [ -e /etc/redhat-release ]; then
    dnf -y install iucode-tool
elif [ -e /etc/debian_version ]; then
    apt -y install iucode-tool
fi

## find appropriate microcode file for this system
## TODO: add use of --date-after=YYYY-MM-DD switch?
bundle=$(iucode_tool -S -l /lib/firmware/intel-ucode/ | tail -n 1 | sed 's#^  0\(.*\)/...: sig.*#\1#')
ucode=$(iucode_tool -l /lib/firmware/intel-ucode/ | grep "microcode bundle $bundle" | cut -d " " -f 4)
if [ -e $ucode ]; then
    echo "Found microcode file for this system at: $ucode"
else
    echo "ERROR: Could not find microcode for this system"
    exit 1
fi

## try to find EFI boot partition
guesses=$(lsblk -i -o NAME,SIZE,TYPE,FSTYPE | grep "part.*fat" | wc -l)
if [ $guesses -eq 1 ]; then
    part=$(lsblk -i -o NAME,SIZE,TYPE,FSTYPE | grep "part.*fat" | cut -d " " -f 1 | sed 's/|-//')
    echo "Found an EFI partition: $part"
elif [ $guesses -eq 0 ]; then
    echo "Could not find an EFI partition, exiting."
    exit 1
else
    echo "Support for multiple EFI partitions not implemented yet."
    exit 1
fi

## mount EFI boot partition so we can modify it
if [ -e /mnt/efi ]; then
    if [ -d /mnt/efi ]; then
	echo "Unmounting whatever was on /mnt/efi/"
	set +e
	umount /mnt/efi
	set -e
    else
	echo "Cound not create mount point"
	exit 1
    fi
else
    mkdir -p /mnt/efi
fi
echo "Mounting EFI partition at /mnt/efi/"
mount /dev/vda1 /mnt/efi/

## Build list of bootloader files from EFI boot variables and defaults
bootloader=""
bootloaders=""
set +e
testboot=$(efivar -l | grep -o Boot0...)
for boot in $testboot; do
    bootloaders="$bootloaders $(efibootdump $boot | grep -o "File.*efi" | awk -F'\' '{print $NF}')"
done
set -e
bootloaders=$(echo "$bootloaders bootx64.efi bootia32.efi" | sed 's/^ //')

## Look for bootloader files in EFI partition
for entry in $bootloaders; do
    echo "looking for $entry"
    bootloader=$(find /mnt/efi/ -iname "$entry")
    if [ "$bootloader" != "" ]; then
	echo "Bootloader found at: $bootloader"
	bootpath=$(dirname "${bootloader}")
	shortbootpath=$(echo "$bootpath" | sed 's#^/mnt/efi##' | tr '/' '\\')
	if [ ! -d /mnt/efi/EFI/BOOT/ ]; then
	    echo "ERROR: couldn't find /EFI/BOOT/ directory"
	    exit 1
	fi
	bootname=$(basename "${bootloader}")
	if cmp --quiet $bootloader $edk2_dir/Build/Shell/RELEASE_GCC5/X64/Shell.efi; then
	    echo "Bootloader application is already Shell.efi"
	else
	    mv $bootloader $bootpath/origboot.efi	    
	    cp $edk2_dir/Build/Shell/RELEASE_GCC5/X64/Shell.efi $bootloader
	fi
	cp $edk2_dir/Build/Uload/RELEASE_GCC5/X64/Uload.efi /mnt/efi/EFI/BOOT/
	cp $ucode /mnt/efi/EFI/BOOT/ucode.pdb
	cat <<EOF > $bootpath/startup.nsh
echo -off
Uload.efi
$shortbootpath\origboot.efi
EOF
	#cat $bootpath/startup.nsh
	echo " "
	echo "--------------------------------------------"
	echo "Microcode Renovation complete. To undo, run:"
	echo "mv $bootpath/origboot.efi $bootloader"
	echo "--------------------------------------------"
	echo " "
	break
    fi
done

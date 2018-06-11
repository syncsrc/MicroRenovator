#!/bin/bash

set -euo pipefail
#set -x

warning="This application is designed to modify the EFI partition and \
bootloader of your system. Running this program can result in \
corruption of the operating system and loss of data. \
Are you sure you want to continue? (yes/no): "

read -p "$warning" -r
echo
if [[ ! $REPLY =~ ^[Yy] ]]
then
    exit 1
fi

edk2_dir="$(pwd)/edk2/"   # Default location to look for EFI binaries
offline="false"           # Set to true by kickstart script for offline use
install="true"            # Default action is to install
demo="false"              # Enable extra breakpoints during demonstrations

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root"
   exit 1
fi

## Install microcode tools and latest firmware
if [ $offline == "false" ]; then
    if [ -e /etc/redhat-release ]; then
        yum -y install iucode-tool efivar microcode_ctl
    elif [ -e /etc/debian_version ]; then
	apt update
        apt -y install iucode-tool efivar intel-microcode amd64-microcode
    else
        echo "Unsupported distro"
        exit 1
    fi
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
set +e
guesses=$(lsblk -i -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE | grep "part.*fat" | grep -v "initramfs.live" | wc -l)
set -e
if [ $guesses -eq 1 ]; then
    part=$(lsblk -i -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE | grep "part.*fat" | grep -v "initramfs.live" | cut -d " " -f 1 | sed 's/|-//')
    echo "Found an EFI partition: $part"
elif [ $guesses -eq 0 ]; then
    echo "Could not find an EFI partition, exiting."
    exit 1
else
    echo "Support for multiple EFI partitions not implemented."
    exit 1
fi

## mount EFI boot partition so it can be modified
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
mount $(find /dev -name $part) /mnt/efi/

## Build list of bootloader files from EFI boot variables and defaults
bootloader=""
bootloaders=""
set +e
testboot=$(efivar -l | grep -o Boot0...)
for boot in $testboot; do
    echo "Checking EFI entry $boot"
    newbootloader=$(efibootdump $boot | grep -io "File.*efi" | awk -F'\' '{print $NF}')
    if [ "$newbootloader" != "" ]; then
	bootloaders="$bootloaders $newbootloader"
	echo "    Found $newbootloader"
    fi
done
set -e
bootloaders=$(echo "$bootloaders bootx64.efi bootia32.efi" | sed 's/^ //')

## Look for bootloader files in EFI partition
for entry in $bootloaders; do
    echo "Looking for $entry"
    bootloader=$(find /mnt/efi/ -iname "$entry")
    if [ "$bootloader" != "" ]; then
	echo "Bootloader found at: $bootloader"
	bootpath=$(dirname "${bootloader}")
	shortbootpath=$(echo "$bootpath" | sed 's#^/mnt/efi##' | tr '/' '\\')
	bootname=$(basename "${bootloader}")
	break
    fi
done

## Exit if no EFI bootloader was found
if [ "$bootloader" == "" ]; then
    echo "ERROR: Could not find an EFI bootloader."
    exit 1
fi

## Uload needs to run from the default EFI boot directory
## Exit if it's not found
if [ ! -d /mnt/efi/EFI/BOOT/ ]; then
    echo "ERROR: couldn't find /EFI/BOOT/ directory"
    exit 1
fi

## Check for previous installation of Micro Renovator
if cmp --quiet $bootloader $edk2_dir/Build/Shell/RELEASE_GCC5/X64/Shell.efi; then
    echo "WARNING: Bootloader application is already Shell.efi, canceling instalation."
    install="false"
elif [ -e $bootpath/origboot.efi ]; then
    echo "WARNING: Old bootloader already exists at $bootpath/origboot.efi, canceling instalation."
    install="false"
elif [ -e /mnt/efi/EFI/BOOT/Uload.efi ]; then
    echo "ERROR: found /mnt/efi/EFI/BOOT/Uload.efi but no backup of original bootloader."
    echo "ERROR: Previous installion corrupted. Manual cleanup needed before proceeding."
    exit 1
elif [ -e /mnt/efi/EFI/BOOT/ucode.pdb ]; then
    echo "ERROR: found /mnt/efi/EFI/BOOT/ucode.pdb without Uload.efi updater."
    echo "ERROR: Previous installion corrupted. Manual cleanup needed before proceeding."
    exit 1
fi

## Install/Uninstall Uload.efi
if [ "$install" == "true" ]; then
    echo "Installing MicroRenovator"
    mv $bootloader $bootpath/origboot.efi
    cp $edk2_dir/Build/Shell/RELEASE_GCC5/X64/Shell.efi $bootloader
    cp $edk2_dir/Build/Uload/RELEASE_GCC5/X64/Uload.efi /mnt/efi/EFI/BOOT/
    cp $ucode /mnt/efi/EFI/BOOT/ucode.pdb
    if [ "$demo" == "true" ]; then
	cat <<EOF > $bootpath/startup.nsh
echo -off
Uload.efi
cd $shortbootpath
EOF
    else
	cat <<EOF > $bootpath/startup.nsh
echo -off
Uload.efi
$shortbootpath\origboot.efi
EOF
    fi
    echo
    echo "-------------------------------------"
    echo "|   Microcode Renovation complete   |"
    echo "|  To uninstall, rerun uRenovate.sh |"
    echo "-------------------------------------"
else
    echo "Uninstalling MicroRenovator"
    mv $bootpath/origboot.efi $bootloader
    if [ -e /mnt/efi/EFI/BOOT/Uload.efi ]; then
	rm /mnt/efi/EFI/BOOT/Uload.efi
    else
	echo "WARNING: Uload.efi not found, unable to remove."
    fi
    if [ -e /mnt/efi/EFI/BOOT/ucode.pdb ]; then
	rm /mnt/efi/EFI/BOOT/ucode.pdb
    else
	echo "WARNING: ucode.pdb not found, unable to remove."
    fi
    if [ -e $bootpath/startup.nsh ]; then
	rm $bootpath/startup.nsh
    else
	echo "WARNING: startup.nsh not found, unable to remove."
    fi
    echo
    echo "-----------------------------------------"
    echo "|     Microcode Renovation complete     |"
    echo "| Microcode loader has been uninstalled |"
    echo "-----------------------------------------"
fi

#!/bin/bash

set -euo pipefail
#set -x

warning="This application is designed to modify the EFI partition and \
bootloader of your system. Running this program can result in \
corruption of the operating system and loss of data. \
Are you sure you want to continue? (yes/no): "

edk2_dir="$(pwd)/edk2/"   # Default location to look for EFI binaries
install="true"            # Default action is to install
uninstall="false"
offline="false"           # Set to true by kickstart script for offline use
demo="false"              # Enable auto-uninstall and extra breakpoints

## check command line options
while getopts ":u" o; do
    case "${o}" in
        u)  uninstall="true"
	    install="false"
            ;;
        *)  echo 'This script will install a microcode update program to the EFI boot partition.'
            echo
            echo 'usage'
            echo 'uRenovate.sh [-u]'
            exit 0
            ;;
    esac
done
shift $((OPTIND-1))

## Display warning, get confirmation
read -p "$warning" -r
echo
if [[ ! $REPLY =~ ^[Yy] ]]
then
    exit 0
fi

## You're letting this script modify your bootloader
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
## Can only handle standard EFI boot configuration, so exit if it's not found
if [ ! -d /mnt/efi/EFI/BOOT/ ]; then
    echo "ERROR: couldn't find /EFI/BOOT/ directory"
    exit 1
fi

## Check for previous installation of Micro Renovator
if cmp --quiet $bootloader $edk2_dir/Build/Shell/RELEASE_GCC5/X64/Shell.efi; then
    if [ "$install" == "true" ]; then
	echo "WARNING: Bootloader application is already Shell.efi, canceling instalation."
    fi
    install="false"
elif [ -e $bootpath/origboot.efi ]; then
    if [ "$install" == "true" ]; then
	echo "WARNING: Old bootloader already exists at $bootpath/origboot.efi, canceling instalation."
    fi
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
    echo "Backing up original bootloader to $bootpath/origboot.efi"
    mv $bootloader $bootpath/origboot.efi
    echo "Installing UEFI shell."
    cp $edk2_dir/Build/Shell/RELEASE_GCC5/X64/Shell.efi $bootloader
    echo "Installing microcode loader."
    cp $edk2_dir/Build/Uload/RELEASE_GCC5/X64/Uload.efi /mnt/efi/EFI/BOOT/
    cp $ucode /mnt/efi/EFI/BOOT/ucode.pdb
    if [ "$demo" == "true" ]; then
	cat <<EOF > $bootpath/startup.nsh
echo -off
Uload.efi
pause
$shortbootpath\origboot.efi
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
    echo "| To uninstall, run uRenovate.sh -u |"
    echo "-------------------------------------"
elif [ "$uninstall" == "true" ] || [ "$demo" == "true" ]; then
    if [ -e $bootpath/origboot.efi ]; then
	echo "Restoring original bootloader from $bootpath/origboot.efi"
	mv $bootpath/origboot.efi $bootloader
    else
	echo "ERROR: Could not find original bootloader to restore. Uninstall Failed."
	exit 1
    fi
    echo "Removing microcode loader."
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
else
    echo "Microcode loader already installed on this system. No action taken."
fi

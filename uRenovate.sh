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
offline="false"           # Run in offline mode. Set to true by kickstart script
demo="false"              # Enable auto-uninstall and extra breakpoints

## check command line options
while getopts ":uo" o; do
    case "${o}" in
        u)  uninstall="true"
	    install="false"
            ;;
	o)  offline="true"
	    ;;
        *)  echo 'This script will install a microcode update program to the EFI boot partition.'
            echo
            echo 'usage'
            echo 'uRenovate.sh [-o] [-u]'
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

## find a microcode file for this system to fix Spectre
set +e
bundle=$(iucode_tool --date-after=2017-11-15 -S -l /lib/firmware/intel-ucode/ | grep sig | sed 's#^  0\(.*\)/...: sig.*#\1#')
set -e
if [ "$bundle" == "" ]; then
    echo "ERROR: Could not find a microcode patch for this system that fixes Spectre."
    if [ "$offline" == "true" ]; then
	echo "       Try running in online mode to download the latest updates."
    fi
    exit 1
fi

## Get the location of the microcode patch file to copy to the EFI partition
set +e
ucode=$(iucode_tool -l /lib/firmware/intel-ucode/ | grep "microcode bundle $bundle" | cut -d " " -f 4)
set -e
if [ -e $ucode ]; then
    echo "Found microcode file for this system at: $ucode"
else
    echo "ERROR: Could not find file for microcode bundle $bundle"
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
drive=$(echo $part | grep -o "[[:alpha:]]*")
partnum=$(echo $part | grep -o "[[:digit:]]*$")
echo "Mounting EFI partition on $drive (partition number $partnum) at /mnt/efi/"
mount $(find /dev -name $part) /mnt/efi/


set +e
testboot=$(efibootmgr | grep -i "MicroRenovator")
set -e
if [ "$testboot" != "" ]; then
    echo "WARNING: Microrenovator has already been installed, canceling instalation."
    install="false"
fi

## Look for Windows bootloader entry in EFI boot options
set +e
testboot=$(efibootmgr -v | grep -i "Boot.*Windows" | grep -io "File.*efi" | awk -F'\' '{print $NF}')
set -e
if [ "$testboot" == "" ]; then
    echo "ERROR: No Windows bootloader found in EFI boot options."
    exit 1
fi

## Look for bootloader file in EFI partition
bootloader=$(find /mnt/efi/ -iname "$testboot")
if [ "$bootloader" != "" ]; then
    echo "Bootloader found at: $bootloader"
    bootpath=$(dirname "${bootloader}")
    shortbootpath=$(echo "$bootpath" | sed 's#^/mnt/efi##' | tr '/' '\\')
    bootname=$(basename "${bootloader}")
else
    echo "ERROR: Could not find Windows EFI bootloader file. "
    exit 1
fi

## Uload needs to run from the default EFI boot directory
## Can only handle standard EFI boot configuration, so exit if it's not found
if [ ! -d /mnt/efi/EFI/BOOT/ ]; then
    echo "ERROR: couldn't find /EFI/BOOT/ directory"
    exit 1
fi

## Check for previous installation of Micro Renovator
if [ -e /mnt/efi/EFI/BOOT/Shell.efi ]; then
    if [ "$install" == "true" ]; then
	echo "WARNING: Shell.efi has already been installed, canceling instalation."
    fi
    install="false"
elif [ -e /mnt/efi/EFI/BOOT/Uload.efi ]; then
    echo "ERROR: found /mnt/efi/EFI/BOOT/Uload.efi on system without MicroRenovator boot entry."
    echo "ERROR: Previous installion corrupted. Manual cleanup needed before proceeding."
    exit 1
elif [ -e /mnt/efi/EFI/BOOT/ucode.pdb ]; then
    echo "ERROR: found /mnt/efi/EFI/BOOT/ucode.pdb without Uload.efi updater."
    echo "ERROR: Previous installion corrupted. Manual cleanup needed before proceeding."
    exit 1
fi

## Install/Uninstall Uload.efi
if [ "$install" == "true" ]; then
    echo "Installing UEFI shell."
    cp $edk2_dir/Build/Shell/RELEASE_GCC5/X64/Shell.efi /mnt/efi/EFI/BOOT/
    echo "Installing microcode loader."
    cp $edk2_dir/Build/Uload/RELEASE_GCC5/X64/Uload.efi /mnt/efi/EFI/BOOT/
    cp $ucode /mnt/efi/EFI/BOOT/ucode.pdb
    if [ "$demo" == "true" ]; then
	cat <<EOF > /mnt/efi/EFI/BOOT/startup.nsh
echo -off
echo "To skip microcode load, (q)uit script and run $shortbootpath\\$bootname manually."
pause
Uload.efi
pause
$shortbootpath\\$bootname
EOF
    else
	cat <<EOF > /mnt/efi/EFI/BOOT/startup.nsh
echo -off
Uload.efi
$shortbootpath\\$bootname
EOF
    fi
    efibootmgr -c -d /dev/$drive -p $partnum -L MicroRenovator -l "\EFI\BOOT\Shell.efi"
    echo
    echo "-------------------------------------"
    echo "|   Microcode Renovation complete   |"
    echo "| To uninstall, run uRenovate.sh -u |"
    echo "-------------------------------------"
elif [ "$uninstall" == "true" ] || [ "$demo" == "true" ]; then
    set +e
    testboot=$(efibootmgr | grep -i "MicroRenovator" | grep -io "Boot0...")
    set -e
    if [ "$testboot" == "" ]; then
	echo "WARNING: Can't find Microrenovator EFI Boot entry to remove."
    else
	efibootmgr -b $(echo $testboot | sed 's/Boot0*//') -B
    fi
    if [ -e /mnt/efi/EFI/BOOT/Shell.efi ]; then
	echo "Removing Shell.efi"
	rm /mnt/efi/EFI/BOOT/Shell.efi
    else
	echo "WARNING: Shell.efi not found, unable to remove."
    fi
    if [ -e /mnt/efi/EFI/BOOT/Uload.efi ]; then
	echo "Removing microcode loader."
	rm /mnt/efi/EFI/BOOT/Uload.efi
    else
	echo "WARNING: Uload.efi not found, unable to remove."
    fi
    if [ -e /mnt/efi/EFI/BOOT/ucode.pdb ]; then
	echo "Removing microcode patch file."
	rm /mnt/efi/EFI/BOOT/ucode.pdb
    else
	echo "WARNING: ucode.pdb not found, unable to remove."
    fi
    if [ -e /mnt/efi/EFI/BOOT/startup.nsh ]; then
	echo "Removing EFI startup script."
	rm /mnt/efi/EFI/BOOT/startup.nsh
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

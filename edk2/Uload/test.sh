#!/bin/bash

#############
# script to help testing of an EFI application in libvirt
# 
# creates and copies .efi files to a floppy image that can
# be attached to a VM and accessed from UEFI shell in OVMF
#############

## use EDK2 target config to figure out what to copy
proj=$(grep ^ACTIVE_PLATFORM $CONF_PATH/target.txt | cut -d "=" -f 2 | cut -d "/" -f 1 | tr -d '[[:space:]]')
target=$(grep ^TARGET[[:space:]] $CONF_PATH/target.txt | cut -d "=" -f 2 | tr -d '[[:space:]]')
tool=$(grep ^TOOL_CHAIN_TAG $CONF_PATH/target.txt | cut -d "=" -f 2 | tr -d '[[:space:]]')
arch=$(grep ^TARGET_ARCH $CONF_PATH/target.txt | cut -d "=" -f 2 | tr -d '[[:space:]]')
cpfile=$WORKSPACE/Build/$proj/${target}_$tool/$arch/*.efi

## default location for libvirt storage files
floppy="/var/lib/libvirt/images/duettest.img"

## temporary directory for mounting floppy image
mntdir="/mnt/tmp/"

## ucode file
ucodefile="/lib/firmware/intel-ucode/06-45-01.initramfs"

## make a floppy disk image file if it doesn't exist
if [ ! -e $floppy ]; then
    set -x
    sudo mkfs.msdos -C $floppy 1440
    set +x
else
    ## file exists, confirm it's a FAT-formatted floppy disk image
    imgcheck=$(sudo file $floppy)
    if echo $imgcheck | grep -q "DOS/MBR boot sector.* sectors 2880 .* FAT"; then
	echo "Using existing floppy image: $floppy"
    else
	echo "ERROR: file $floppy is not a suitable floppy disk image file."
	exit 1
    fi
fi

## create tempory dir for mounting floppy image if necessary
if [ ! -d $mntdir ]; then
    set -x
    mkdir -p $mntdir
    set +x
fi

set -x
sudo mount $floppy $mntdir
sudo cp $cpfile $mntdir
sudo cp $ucodefile $mntdir/ucode.pdb
sudo umount $mntdir

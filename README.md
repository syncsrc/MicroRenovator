## MicroRenovator
Pre-OS microcode updater

# WARNING

This application is designed to modify the EFI partition and bootloader of
your system. Users acknowledge that running this program can result 
in corruption of the operating system and loss of data.


## Usage

Boot the target system using a linux LiveCD or USB. Clone this
repository, and run uRenovate.sh to install the microcode updater.
The installer will perform the following actions:
1. find appropriate microcode for the current system
2. attempt to locate an EFI partition
3. find the bootloader on that partition
4. copy the included microcode updater to the EFI partition
5. add a startup script to run the microcode updater prior to the OS bootloader

Tested using Fedora-Workstation-Live-x86_64-27-1.6.iso


## Building

Building the EFI applications requires an EDK2 environment:
https://github.com/tianocore/tianocore.github.io/wiki/Common-instructions

Copy the Uload directory into the edk2/ folder, and run the following:
```
build -a X64 -p ShellPkg/ShellPkg.dsc -b RELEASE
build -a X64 -p Uload/Uload.dsc -b RELEASE
```

To use the resulting files instead of the provided .efi binaries, change the "edk2_dir" in uRenovate.sh


## ToDo
* install latest microcode_ctl package
* howto verify microcode in LiveCD /lib/firmware/intel-ucode/ folder is good? (add "--date-after" switch to iucode_tool usage?)
* add run-time warnings
* add uninstaller
* verify on windows installs (\EFI\Microsoft\Boot\bootmgfw.efi)
* error handling in Uload.c
* handle Uload.efi errors in startup.nsh
* S3 callback?


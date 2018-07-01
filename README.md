## MicroRenovator
Pre-OS microcode updater

# WARNING

_This application is designed to modify the EFI partition and bootloader of
your system. Users acknowledge that running this program can result 
in corruption of the operating system and loss of data._


## Background

Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt 
ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation 
ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in 
reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur 
sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id 
est laborum.


## Usage

Boot the target system using a linux LiveCD or USB, such as [Fedora](https://getfedora.org/) 
or [Ubuntu](https://www.ubuntu.com/download)

Clone this repository
```
git clone https://github.com/syncsrc/MicroRenovator.git
```
Then run uRenovate.sh to install the microcode updater
```
./uRenovate.sh
```
The installer will perform the following actions:
1. find appropriate microcode for the current system
2. attempt to locate an EFI partition
3. find the bootloader on that partition
4. copy the included microcode updater to the EFI partition
5. add a startup script to run the microcode updater prior to the OS bootloader

To uninstall, run
```
./uRenovate.sh -u
```


## Offline Usage

The kickstart file can be used to build a custom LiveCD image based on Fedora 27
that includes all the necessary files and packages to build and install the
microcode loader application.

Install the LiveCD Creator utility and the sample kickstart files, and make a local 
copy of the kickstart files to work with.
```
dnf -y install livecd-tools spin-kickstarts
cp /usr/share/spin-kickstarts/\*.ks .
```
The LiveCD utility will need to be modified to launch the desired OS on boot.
```
sed -i 's/set default="1"/set default="0"/' /usr/lib/python3.6/site-packages/imgcreate/live.py
```
Finally, run LiveCD-Creator to build the ISO
```
livecd-creator --verbose --config=reno-live.ks --fslabel=URENO
```
The resulting URENO.iso file is a bootable image that can be burned to a DVD or USB drive like 
any other live image. Once booted into this live image, simply run the uRenovate.sh installer script.


## Building EFI Utilities

Building the EFI applications requires an 
[EDK2 environment](https://github.com/tianocore/tianocore.github.io/wiki/Common-instructions).

Copy the Uload directory into the edk2/ folder of a configured EDK2 environment, 
and run the following:
```
build -a X64 -p ShellPkg/ShellPkg.dsc -b RELEASE
build -a X64 -p Uload/Uload.dsc -b RELEASE
```

To use the resulting files instead of the provided .efi binaries, change the "edk2_dir" 
in uRenovate.sh to point at the desired edk2/ directory.

If using a LiveCD created by the MicroRenovator kickstart file, running the
included build_efi.sh script will generate the necessary files.


## ToDo
* verify microcode in LiveCD /lib/firmware/intel-ucode/ folder is "good" (add "--date-after" switch in iucode_tool?)
* add run-time warnings
* error handling in EFI application and script
* S3 callback?


## Known Issues
* Not compatible with Sleep (S3). Hibernate is not impacted
* Not currently compatible with UEFI secure boot
* Windows update has been observed to revert bootloader changes made by MicroRenovator
* Windows sometimes fails to boot after running Uload.efi, rebooting usually resolves the problem

#!/bin/bash

## A script to build Uload.efi and dependancies
## Requires https://github.com/tianocore/edk2

sed -i 's/ShellInfoObject.ShellInitSettings.BitUnion.Bits.NoInterrupt  = FALSE/ShellInfoObject.ShellInitSettings.BitUnion.Bits.NoInterrupt  = TRUE/' edk2/ShellPkg/Application/Shell/Shell.c
make -C edk2/BaseTools
cd edk2/
. edksetup.sh
build -a X64 -p ShellPkg/ShellPkg.dsc -b RELEASE -t GCC5
build -a X64 -p Uload/Uload.dsc -b RELEASE -t GCC5

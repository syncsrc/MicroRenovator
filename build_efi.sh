#!/bin/bash

## A script to build Uload.efi and dependancies
## Requires https://github.com/tianocore/edk2

make -C edk2/BaseTools
cd edk2/
. edksetup.sh
build -a X64 -p ShellPkg/ShellPkg.dsc -b RELEASE -t GCC5
build -a X64 -p Uload/Uload.dsc -b RELEASE -t GCC5

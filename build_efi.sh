#!/bin/bash

## A script to build Uload.efi and dependancies
## Requires https://github.com/tianocore/edk2

make -C edk2/BaseTools
cd edk2/
sed -i "s/TOOL_CHAIN_TAG[[:space:]]*=.*$/TOOL_CHAIN_TAG = GCC5/" Conf/target.txt
. edksetup.sh
build -a X64 -p ShellPkg/ShellPkg.dsc -b RELEASE
build -a X64 -p Uload/Uload.dsc -b RELEASE

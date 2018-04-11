//
//  Copyright (c) 2018  syncsrc.org
//
//  This program and the accompanying materials
//  are licensed and made available under the terms and conditions of the BSD License
//  which accompanies this distribution. The full text of the license may be found at
//  http://opensource.org/licenses/bsd-license.php
//
//  THE PROGRAM IS DISTRIBUTED UNDER THE BSD LICENSE ON AN "AS IS" BASIS,
//  WITHOUT WARRANTIES OR REPRESENTATIONS OF ANY KIND, EITHER EXPRESS OR IMPLIED.
//  


#include <Uefi.h>

#include <Library/UefiLib.h>
#include <Library/ShellCEntryLib.h>
#include <Library/ShellLib.h>
#include <Library/ShellCommandLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/PrintLib.h>

#include <Protocol/EfiShell.h>
#include <Protocol/LoadedImage.h>

#include <Library/MpInitLib/MpLib.h>
#include <Feature/Capsule/MicrocodeUpdateDxe/MicrocodeUpdate.h>


#define UTILITY_VERSION L"0.7"


// Print some info about a microcode patch. Added for debugging.
// CPU_MICROCODE_HEADER is defined in UefiCpuPkg/Include/Register/Microcode.h
EFI_STATUS
DisplayMicrocodeInfo(IN CPU_MICROCODE_HEADER *MicrocodePatch)
{
  Print(L"Patch header version = %u\n", MicrocodePatch->HeaderVersion);
  Print(L"Patch update revision = 0x%x\n", MicrocodePatch->UpdateRevision);
  Print(L"Patch date = %x\n", MicrocodePatch->Date);
  Print(L"Patch processor signature = 0x%x\n", MicrocodePatch->ProcessorSignature);
  Print(L"Patch checksum = 0x%x\n", MicrocodePatch->Checksum);
  Print(L"Patch loader revision = 0x%x\n", MicrocodePatch->LoaderRevision);
  Print(L"Patch processor flags = 0x%x\n", MicrocodePatch->ProcessorFlags);
  Print(L"Patch data size = 0x%x\n", MicrocodePatch->DataSize);
  Print(L"Patch total size = 0x%x\n", MicrocodePatch->TotalSize);
  return EFI_SUCCESS;
}


// shamelessly copied from MicrocodeUpdateDxe/MicrocodeUpdate.c
UINT32
GetCurrentMicrocodeSignature ( VOID )
{
  UINT64 Signature;

  AsmWriteMsr64(MSR_IA32_BIOS_SIGN_ID, 0);
  AsmCpuid(CPUID_VERSION_INFO, NULL, NULL, NULL, NULL);
  Signature = AsmReadMsr64(MSR_IA32_BIOS_SIGN_ID);
  return (UINT32)RShiftU64(Signature, 32);
}


// shamelessly copied from MicrocodeUpdateDxe/MicrocodeUpdate.c
UINT32
LoadMicrocode ( IN UINT64  Address )
{
  AsmWriteMsr64(MSR_IA32_BIOS_UPDT_TRIG, Address);
  return GetCurrentMicrocodeSignature();
}


// shamelessly copied from MicrocodeUpdateDxe/MicrocodeUpdate.c
VOID
EFIAPI
MicrocodeLoadAp ( IN OUT VOID  *Buffer )
{
  MICROCODE_LOAD_BUFFER                *MicrocodeLoadBuffer;

  MicrocodeLoadBuffer = Buffer;
  MicrocodeLoadBuffer->Revision = LoadMicrocode (MicrocodeLoadBuffer->Address);
}


// Copied from MicrocodeUpdateDxe/MicrocodeUpdate.c with minimal modification
UINT32
LoadMicrocodeOnThis (IN  UINTN                       Bsp,
		     IN  EFI_MP_SERVICES_PROTOCOL    *MpService,
		     IN  UINTN                       CpuIndex,
		     IN  UINT64                      Address )
{
  EFI_STATUS                           Status;
  MICROCODE_LOAD_BUFFER                MicrocodeLoadBuffer;

  if (CpuIndex == Bsp) {
    return LoadMicrocode (Address);
  } else {
    MicrocodeLoadBuffer.Address = Address;
    MicrocodeLoadBuffer.Revision = 0;
    Status = MpService->StartupThisAP (
				       MpService,
				       MicrocodeLoadAp,
				       CpuIndex,
				       NULL,
				       0,
				       &MicrocodeLoadBuffer,
				       NULL
				       );
    ASSERT_EFI_ERROR(Status);
    return MicrocodeLoadBuffer.Revision;
  }
}


// Main application. Loads the microcode patch in "ucode.pdb"
// It it out-of-scope currenty to deal with or manage multiple patch files, that
// logic has been outsourced to the script installing this on the EFI boot partition.
INTN
EFIAPI
ShellAppMain(UINTN Argc, CHAR16 **Argv)
{
  EFI_STATUS                 Status = EFI_SUCCESS;
  SHELL_FILE_HANDLE          FileHandle;
  CHAR16                     *FileName = L"ucode.pdb";
  CHAR16                     *FullFileName;
  VOID                       *Buffer;
  UINTN                      Size;
  UINTN                      ReadSize;
  VOID                       *MpProto;
  EFI_MP_SERVICES_PROTOCOL   *Mp;
  UINTN                      NumProc;
  UINTN                      NumEnabled;
  UINTN                      cpu;
  UINTN                      CurrentCpu;
  UINT32                     TestCpu;
  CPU_MICROCODE_HEADER       *MicrocodePatch;


  // get full filename for open()
  FullFileName = ShellFindFilePath(FileName);
  if (FullFileName == NULL) {
    Print(L"ERROR: Could not find %s\n", FileName);
    Status = EFI_NOT_FOUND;
    goto Error;
  }

  // open the file
  Status = ShellOpenFileByName(FullFileName, &FileHandle, EFI_FILE_MODE_READ, 0);
  if (EFI_ERROR(Status)) {
    Print(L"ERROR: Could not open file\n");
    goto Error;
  }

  // get file size
  Status = ShellGetFileSize(FileHandle, &Size);
  if (EFI_ERROR(Status)) {
    Print(L"ERROR: Could not get file size\n");
    goto Error;
  }
  
  // allocate a buffer to read ucode into
  Buffer = AllocateZeroPool(Size);
  if (Buffer == NULL) {
    Print(L"ERROR: Could not allocate memory\n");
    Status = EFI_OUT_OF_RESOURCES;
    goto Error;
  }
    
  // read file into Buffer
  ShellSetFilePosition(FileHandle, 0);
  ReadSize = Size;
  Status = ShellReadFile(FileHandle, &ReadSize, Buffer);
  if (Status == EFI_BUFFER_TOO_SMALL) {
    Print(L"ERROR: Allocated %x bytes of memory but file requires %x\n", Size, ReadSize);
    goto Error;
  }
  if (EFI_ERROR(Status)) {
    Print(L"Could not read file\n");
    goto Error;
  }

  // Display microcode patch info
  //Print(L"Read %u bytes of file into buffer\n", ReadSize);
  //Print(L"File buffer at address: 0x%x\n", Buffer);
  MicrocodePatch = (CPU_MICROCODE_HEADER*) Buffer;
  Status = DisplayMicrocodeInfo(MicrocodePatch);
  if (EFI_ERROR(Status)) {
    Print(L"Error parsing microcode patch: %r\n", Status);
    goto Error;
  }
  
  // Find the MP Services Protocol
  Status = gBS->LocateProtocol( &gEfiMpServiceProtocolGuid, NULL, &MpProto);
  if (EFI_ERROR(Status)) {
    Print(L"Unable to locate the MpService procotol: %r\n", Status);
    goto Error;
  }
  Mp = (EFI_MP_SERVICES_PROTOCOL*) MpProto;

  // Get Number of Processors and Number of Enabled Processors
  Status = Mp->GetNumberOfProcessors( Mp, &NumProc, &NumEnabled);
  if (EFI_ERROR(Status)) {
    Print(L"Unable to get the number of processors: %r\n", Status);
    goto Error;
  } else {
    Print(L"%u Processors detected, %u enabled\n", NumProc, NumEnabled);
  }

  // This is probably not the best way to determine the BSP  
  Status = Mp->WhoAmI(Mp, &CurrentCpu);
  if (EFI_ERROR(Status)) {
    Print(L"Unable to determin BSP\n", Status);
    goto Error;
  } else {
    Print(L"Processor %u appears to be the BSP\n", CurrentCpu);
  }

  // Apply microcode patch
  for ( cpu=0; cpu<NumEnabled; cpu++ ) {
    TestCpu = (UINT32) cpu;

    // Starting point of uCode patch data = (UINTN) Buffer + sizeof(CPU_MICROCODE_HEADER)    
    Print(L"Attempting to load ucode on processor %u\n", cpu); 
    TestCpu = LoadMicrocodeOnThis(CurrentCpu, Mp, cpu, (UINTN) Buffer + sizeof(CPU_MICROCODE_HEADER));
    Print(L"CPU %u is on microcode version %x\n", cpu, TestCpu);
  }


  // FIXME: error handling & cleanup
 Error:
  /**
  if (FileName != NULL) {
    FreePool(FileName);
  }
  if (FullFileName != NULL) {
    FreePool(FullFileName);
  }
  if (Buffer != NULL) {
    FreePool(Buffer);
  }
  if (FileHandle != NULL) {
    ShellCloseFile(&FileHandle);
  }
  **/
  
  return Status;
}

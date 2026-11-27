; Copyright 2019-2024 Tauri Programme within The Commons Conservancy
; SPDX-License-Identifier: Apache-2.0 OR MIT
; Source: https://github.com/tauri-apps/tauri/blob/59b63ab500da9859f12d8888c3298bc29bba0b92/crates/tauri-bundler/src/bundle/windows/nsis/utils.nsh
; Tauri CLI 2.12.3. The original macro and every diagnostic insertion are pinned.
; Successful installations add no diagnostic I/O. The existing silent error
; console gains one line, using its existing handle; the original Abort remains.
!ifmacrondef CheckIfAppIsRunning
  !error "The pinned Tauri CheckIfAppIsRunning macro must be included first."
!endif
!macroundef CheckIfAppIsRunning
Var RbnRmShutdownCode
Var RbnRmWriteHadError

!macro CheckIfAppIsRunning executablePath productName
  !define UniqueID ${__LINE__}

  ; Replace {{product_name}} placeholder in the messages with the passed product name
  nsis_tauri_utils::StrReplace "$(appRunning)" "{{product_name}}" "${productName}"
  Pop $R1
  nsis_tauri_utils::StrReplace "$(appRunningOkKill)" "{{product_name}}" "${productName}"
  Pop $R2
  nsis_tauri_utils::StrReplace "$(failedToKillApp)" "{{product_name}}" "${productName}"
  Pop $R3

  !insertmacro RestartManager_StartSession $R0
  ${If} $R0 != ""
    !insertmacro RestartManager_RegisterFile $R0 "${executablePath}"
    ${If} $0 = 0
      System::Call 'RSTRTMGR::RmGetList(p R0, *i .r1, *i .r2, p 0, *i .r3) i .r0'
      ; ERROR_SUCCESS means no running processes, ERROR_MORE_DATA means there're some
      ${If} $0 = ${ERROR_MORE_DATA}
        IfSilent kill_${UniqueID} 0
        ${IfThen} $PassiveMode != 1 ${|} MessageBox MB_OKCANCEL $R2 IDOK kill_${UniqueID} IDCANCEL cancel_${UniqueID} ${|}
        kill_${UniqueID}:
          ; Call manually here to get the result
          ; !insertmacro RestartManager_Shutdown $R0
          System::Call 'RSTRTMGR::RmShutdown(p R0, i ${RmForceShutdown}, p 0) i .r0'
          ${If} $0 = 0
            Goto app_check_done_${UniqueID}
          ${Else}
            ; RBN_NSIS_DIAGNOSTIC_BEGIN save-shutdown-returncode
            StrCpy $RbnRmShutdownCode $0
            ; RBN_NSIS_DIAGNOSTIC_END save-shutdown-returncode
            IfSilent silent_${UniqueID} ui_${UniqueID}
            silent_${UniqueID}:
              System::Call 'kernel32::AttachConsole(i -1)i.r0'
              ${If} $0 != 0
                System::Call 'kernel32::GetStdHandle(i -11)i.r0'
                System::call 'kernel32::SetConsoleTextAttribute(i r0, i 0x0004)' ; set red color
                FileWrite $0 "$R1$\n"
                ; RBN_NSIS_DIAGNOSTIC_BEGIN append-existing-error-console
                StrCpy $RbnRmWriteHadError 0
                IfErrors 0 +2
                StrCpy $RbnRmWriteHadError 1
                FileWrite $0 'RBN_NSIS_RM_DIAGNOSTIC target="${executablePath}" shutdown=$RbnRmShutdownCode register=0 getList=234 needed=$1 count=$2 rebootReasons=$3$\n'
                ${If} $RbnRmWriteHadError = 1
                  SetErrors
                ${Else}
                  ClearErrors
                ${EndIf}
                ; RBN_NSIS_DIAGNOSTIC_END append-existing-error-console
              ${EndIf}
              !insertmacro RestartManager_EndSession $R0
              Abort
            ui_${UniqueID}:
              !insertmacro RestartManager_EndSession $R0
              Abort $R3
          ${EndIf}
        cancel_${UniqueID}:
          !insertmacro RestartManager_EndSession $R0
          Abort $R1
        app_check_done_${UniqueID}:
      ${EndIf}
    ${EndIf}
    !insertmacro RestartManager_EndSession $R0
  ${EndIf}

  !undef UniqueID
!macroend

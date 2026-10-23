' campus-launch.vbs
'
' Wrapper used as the Task Scheduler action target, instead of invoking
' powershell.exe directly.
'
' Why this exists:
'   Task Scheduler launches powershell.exe as a console process in the
'   interactive session, so Windows creates and SHOWS a console window first.
'   PowerShell only processes "-WindowStyle Hidden" afterwards, which hides a
'   window that was already visible. Result: a visible flash on every run.
'
'   wscript.exe is a GUI-subsystem process and has no console. Shell.Run with
'   window style 0 passes SW_HIDE at process creation time, so the child
'   console is never shown at all -- no flash.
'
'   Argument 0      = hidden window
'   Argument False  = do not wait for the child to exit

Dim fso, sh, here, script

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

' Resolve campus-login.ps1 relative to this file, so moving the whole
' folder elsewhere does not break the task.
here   = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(here, "campus-login.ps1")

If Not fso.FileExists(script) Then
    ' Nothing sensible to do; fail silently so no error dialog pops up.
    WScript.Quit 1
End If

sh.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & script & """", 0, False

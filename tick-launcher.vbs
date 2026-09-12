' Invisible launcher for the cswap tick (Windows). Mirrors
' scripts/freshener-launcher.vbs: Task Scheduler -> powershell.exe flashes a
' console window every run, and this tick fires every 5 minutes all day.
' wscript creates NO console, so window style 0 kills the flash entirely.
'
' Derives its own directory, so it follows a vault-folder rename with no edit.
' Uses powershell (5.1) deliberately: pwsh is NOT installed on YUKIKAZE.
'
' LOGGING (added 2026-08-09). This previously ran powershell.exe directly with no
' redirection, so tick.ps1's stdout went nowhere and Windows had NO tick log at
' all -- the Mac plist had one, Windows silently did not. That was only noticed
' when asking "how often did warming fire overnight?" turned out to be
' unanswerable: warm-state.json keeps only the LATEST stamp per slot, so every
' earlier warm was unrecoverable. Routed through cmd /c purely to get `>>`.
' The tick writes stdout ONLY when it acted, so this stays small by contract --
' content in it is the signal, exactly like the freshener's log.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("Wscript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
logf = sh.ExpandEnvironmentStrings("%TEMP%") & "\ultraagent-cswap-tick.log"
sh.Run "cmd /c powershell -NoProfile -ExecutionPolicy Bypass -File """ & dir & _
        "\tick.ps1"" >>""" & logf & """ 2>&1", 0, False

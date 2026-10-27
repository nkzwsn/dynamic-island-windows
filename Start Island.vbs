' Starts Mini Island without a console window.
' If the island stops because of an error (non-zero exit code), it is restarted automatically.
' Exiting from the island's menu returns 0, so it is not restarted.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\island.ps1"""
restarts = 0
Do
    started = Now
    rc = sh.Run(cmd, 0, True)
    If rc = 0 Then Exit Do
    ' Only back-to-back crashes count (the island died again within 60 seconds of starting);
    ' after a normal run the counter is reset
    If DateDiff("s", started, Now) >= 60 Then restarts = 0
    restarts = restarts + 1
    ' Don't loop forever if it always fails at startup
    If restarts > 10 Then Exit Do
    WScript.Sleep 3000
Loop

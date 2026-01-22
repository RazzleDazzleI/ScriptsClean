@echo off
setlocal

rem --- optional: set a start delay (env var read by PostUpgrade.ps1) ---
rem setx POST_DELAY_SECONDS 300 /M >nul

rem --- force LocalMachine policy to RemoteSigned (just in case) ---
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "try{ Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned -Force }catch{}"

rem --- launch the post-upgrade workflow ---
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\PostUpgrade.ps1"

endlocal

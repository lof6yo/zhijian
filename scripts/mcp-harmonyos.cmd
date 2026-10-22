@echo off
for %%I in ("%~dp0..") do set "PROJECT_PATH=%%~fI"
set "DEVECO_STUDIO_HOME=D:\deveco\command-line-tools"
set "DEVECO_SDK_HOME=D:\deveco\command-line-tools\sdk"
set "OHOS_HDC_SERVER_PORT=18710"
set "PATH=D:\deveco\command-line-tools\bin;D:\deveco\command-line-tools\sdk\default\openharmony\toolchains;D:\deveco\command-line-tools\emulator;C:\Users\Huangly\AppData\Roaming\npm;%PATH%"
call harmonyos-mcp

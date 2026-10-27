@echo off
for %%I in ("%~dp0..") do set "PROJECT_PATH=%%~fI"
set "DEVECO_CLI_CLT_PATH=D:\deveco\command-line-tools"
set "OHOS_HDC_SERVER_PORT=18710"
set "PATH=%APPDATA%\npm;%PATH%"
call devecocli serve mcp

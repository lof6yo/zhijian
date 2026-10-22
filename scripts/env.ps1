# HMStart environment
# Dot-source this file: . .\scripts\env.ps1
$env:DEVECO_CLI_CLT_PATH = 'D:\deveco\command-line-tools'
$env:DEVECO_SDK_HOME     = 'D:\deveco\command-line-tools\sdk'
$env:DEVECO_STUDIO_HOME  = 'D:\deveco\command-line-tools'
# WSL2 mirrored networking already owns 8710 (sshd-sess/semi-grpc).
# Use a non-default hdc server port so hdc/DevEco CLI/MCP do not hang.
$env:OHOS_HDC_SERVER_PORT = '18710'
$env:PATH = "D:\deveco\command-line-tools\bin;D:\deveco\command-line-tools\sdk\default\openharmony\toolchains;D:\deveco\command-line-tools\emulator;$env:PATH"

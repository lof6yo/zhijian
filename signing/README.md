# Local debug signing (emulator only)

This directory contains a **local debug** signing chain for `HMStart`
(`com.hmprojects.hmstart`). It exists so the emulator loop works without a
Huawei developer account. **Never ship these materials or commit them.**

## Files

| File | Purpose |
|---|---|
| `app-release.cer` | Leaf app certificate (OpenHarmony Application Release, CA-issued). |
| `app-subca.cer` | OpenHarmony Application CA. |
| `app-root.cer` | OpenHarmony Application Root CA. |
| `app-chain.cer` | Leaf + sub-CA + root, used by `hap-sign-tool` and hvigor. |
| `hmstart-profile.json` | Unsigned debug profile: bundle name, UUID, validity, app cert chain. |
| `hmstart-debug.p7b` | Signed debug profile (signed with the OpenHarmony debug profile key). |
| `hmstart-signed.hap` | Output of the last `scripts/sign-and-install.ps1` run. |

The keystore is the SDK's public test keystore:
`D:\deveco\command-line-tools\sdk\default\openharmony\toolchains\lib\OpenHarmony.p12`
(password `123456`). It contains the app release key and the debug profile key.
Do not copy it into the repo.

## How it was generated

Profile (bundle name and validity live in `hmstart-profile.json`):

```powershell
java -jar $lib\hap-sign-tool.jar sign-profile `
  -mode localSign `
  -keyAlias "openharmony application profile debug" `
  -keyPwd 123456 `
  -profileCertFile $lib\OpenHarmonyProfileDebug.pem `
  -inFile signing\hmstart-profile.json `
  -signAlg SHA256withECDSA `
  -keystoreFile $lib\OpenHarmony.p12 `
  -keystorePwd 123456 `
  -outFile signing\hmstart-debug.p7b
```

HAP signing (done by `scripts/sign-and-install.ps1`):

```powershell
java -jar $lib\hap-sign-tool.jar sign-app `
  -mode localSign `
  -keyAlias "openharmony application release" `
  -keyPwd 123456 `
  -appCertFile signing\app-chain.cer `
  -profileFile signing\hmstart-debug.p7b -profileSigned 1 `
  -inFile entry\build\default\outputs\default\entry-default-unsigned.hap `
  -signAlg SHA256withECDSA `
  -keystoreFile $lib\OpenHarmony.p12 -keystorePwd 123456 `
  -outFile signing\hmstart-signed.hap `
  -compatibleVersion 26 -signCode 1
```

Verify:

```powershell
java -jar $lib\hap-sign-tool.jar verify-app -inFile signing\hmstart-signed.hap
```

## Official alternative

For a real device or release, use Huawei's automatic signing:

```powershell
devecocli auth login --no-prompt
devecocli signature generate --product default
```

That writes `signingConfigs` into `build-profile.json5` and materials under
`~/.ohos/config/`. Keep those out of git too.

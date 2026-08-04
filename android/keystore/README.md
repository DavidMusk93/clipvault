# CI sideload keystore

`keepsake-ci.jks` 用于 GitHub Actions 与本地 `assembleRelease` 签名，方便安装 APK。

| 项 | 值 |
| --- | --- |
| alias | `keepsake` |
| store/key password | `keepsake-ci`（也可用 env `KEEPSAKE_*` 覆盖） |

**不要**用这个密钥上架 Play。上架请换独立 upload key 并走 secrets，勿提交生产密钥。

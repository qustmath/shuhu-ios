# iOS 发版手册（shuhu-ios 权威版）

> **新 session 必读**。本文档记录 2026-09-13 首包发版踩过的全部坑与最终固化方案。
> 发版本身已全自动（一条 workflow），但如果你要改流水线、换证书、或排查失败，先读完本文档再动手。
> 跨项目通用版见根仓库 `docs/lessons/ios-release-playbook.md`。

## 一、日常发版（唯一动作）

GitHub → Actions → **Release (TestFlight) → Run workflow** → 填 changelog → 跑约 7 分钟。
或用 PAT 触发：

```bash
curl -X POST -H "Authorization: Bearer <PAT>" \
  "https://api.github.com/repos/qustmath/shuhu-ios/actions/workflows/release.yml/dispatches" \
  -d '{"ref":"master","inputs":{"changelog":"本次测试内容"}}'
```

**开发机（Ubuntu）专用通道——推标签触发**（本机到 github.com / dispatches API 均不通，
SSH 推 git 标签可用）：

```bash
git tag release-1.1-20260920 && git push origin release-1.1-20260920
# 标签推上即触发 Release workflow（匹配 release-* 模式）
```

**关键铁律：workflow 绿 ≠ 构建入库。** 上传完成后必须用 ASC REST 复核
（见「验证构建」），处理完成后 TestFlight 页构建状态应为 VALID。

## 二、当前架构（改前先懂）

### 签名：手动模式，资产持久化

CI 无 Apple 账号登录，**自动签名（-allowProvisioningUpdates）不可靠且已废弃**——
它会尝试给 runner 设备注册"开发"描述文件而失败，且失败被管道吞成假绿。

| 资产 | 值 | 位置 |
|---|---|---|
| 分发证书 | Apple Distribution: fuhao wei，ID `XHKVWA8744`，**到期 2027-09-12** | 本地 `~/.asc-certs/`（key/p12）+ Secret `DIST_P12_B64` |
| p12 密码 | `shufu-ci` | Secret `DIST_P12_PASSWORD` |
| 描述文件 | "Shufu App Store"，UUID `48ba2855-56c5-45c0-8ddd-f8d4badf4f62` | Secret `DIST_PROFILE_B64` |
| ASC API Key | Key ID `H6LLA5YHQ6`（p8 本地 `~/.keys/`） | Secrets `ASC_KEY_*`、`ASC_TEAM_ID` |

- 签名设置写在 **project.yml 的 Release 配置（仅 Shuhu 目标）**，命令行不覆盖。
  SPM 依赖目标（GRDB）不支持描述文件，绝不能继承 Manual+Specifier。
- p12 **必须用 `openssl pkcs12 -export -legacy`** 导出（macOS `security import`
  不认 OpenSSL 3 默认算法，报 `MAC verification failed`）。
- profile UUID 硬编码在 release.yml（装描述文件用）；profile 续期/换证书后要同步更新
  Secret `DIST_PROFILE_B64` 与该 UUID。

### 上传：fastlane pilot

`altool` 不要再用（Apple 弃用中）。`fastlane pilot upload --skip_waiting_for_build_processing true`
不原地等处理（省 CI 时长），处理状态靠「验证构建」查。

## 三、验证构建（每次发版必做）

本机网络到 Apple API 不通（DNS/连接被重置），两条路：

**A. 本地签 JWT + 干净服务器 curl 中继**（快，首选）：

```bash
TOKEN=$(python3 - <<'EOF'
import jwt, time
key = open('/home/czx/.keys/AuthKey_H6LLA5YHQ6.p8').read()
now = int(time.time())
print(jwt.encode({"iss": "6c9399cf-f994-4d87-9d98-92c2e4792484", "iat": now,
      "exp": now + 1200, "aud": "appstoreconnect-v1"}, key,
      algorithm="ES256", headers={"kid": "H6LLA5YHQ6"}))
EOF
)
ssh root@110.42.63.37 "curl -s -H 'Authorization: Bearer $TOKEN' \
  'https://api.appstoreconnect.apple.com/v1/builds?filter%5Bapp%5D=6811369493&fields%5Bbuilds%5D=version,processingState,uploadedDate&sort=-uploadedDate&limit=3'"
```

**B. Actions 里跑 Check TestFlight 工作流**（`.github/workflows/check-testflight.yml`），
结果以 notice 注解回读，用 `check-runs/<job-id>/annotations` API 读。

期望输出：`BUILD <n> | VALID | <date>`。`PROCESSING`/`PROCESSING_FAILED` 等状态见下表。

## 四、排障速查（全部实战踩过）

| 症状 | 根因 | 修法 | 已固化在 |
|---|---|---|---|
| 步骤绿但 ASC 查无构建 | xcbeautify/tee 管道吞 xcodebuild 退出码 → Archive/Export 假绿，IPA 根本没生成 | 每个跑 xcodebuild/fastlane 的 step 加 `set -euo pipefail` | release.yml 全部 step |
| `Device "..." isn't registered ... provisioning profile` | 自动签名试图给 runner 设备注册开发描述文件 | 弃自动签名，改手动（本文档方案） | project.yml Release 配置 |
| `GRDB_GRDB does not support provisioning profiles` | 命令行给整个 scheme 覆盖签名设置，SPM 依赖目标被强制套 profile | 签名设置只写在 App 目标（project.yml configs），命令行零覆盖 | project.yml |
| `xcodebuild: error: You cannot specify both a scheme and targets` | archive 同时给 `-scheme` 和 `-target` | 只用 -scheme，签名走工程文件 | release.yml |
| `MAC verification failed during PKCS12 import` | OpenSSL 3 默认 p12 加密 macOS 不认 | `openssl pkcs12 -export -legacy` 重导 p12，更新 Secret | 本地 `~/.asc-certs/` |
| 上传报 `SDK version issue ... iOS 26 SDK or later (Xcode 26)` | runner 镜像默认 Xcode 太老 | runner 用 `macos-26` + 显式 `xcode-select` Xcode 26 | release.yml |
| ASC API 报域名解析失败（连 1.1.1.1 都 NXDOMAIN） | **Apple 已全球下线 `api.appstoreconnect.com`**，新域名 `api.appstoreconnect.apple.com` | 所有直连 ASC API 的脚本用新域名 | check-testflight.yml |
| `pilot builds` 报 `relationship 'buildDeliveries' does not exist` | fastlane 落后于 Apple API 变更 | 不用 pilot builds，直接 REST 查 builds | check-testflight.yml |
| TestFlight 一直"处理中"数小时无果 | 上传的包其实从未入库（见假绿）或被 Apple 静默拒收 | 先查注册邮箱有无 ITMS 邮件；再用本文档「验证构建」确认是否真的入库 | — |

## 五、证书/描述文件到期后的重置流程（2027-09 前必做）

1. 本地生成新 CSR：`openssl req -new -newkey rsa:2048 -nodes -keyout new.key -out new.csr -subj "/CN=Shufu Distribution/O=Groovy/C=CN"`
2. JWT 调 `POST /v1/certificates`（`certificateType: DISTRIBUTION`，`csrContent` 传 **PEM 文本**，**不能带 name 字段**），拿回 `certificateContent`（base64 的 DER）
3. DER→PEM→与 key 合成 p12（**-legacy**）→ 更新 Secrets `DIST_P12_B64`（密码不变）
4. JWT 调 `POST /v1/profiles`（`profileType: IOS_APP_STORE`，relationships 给 bundleId `DSZGB3N72L` + 新证书 id）→ 新 profileContent 更新 `DIST_PROFILE_B64`，新 UUID 改 release.yml 里的硬编码
5. 跑一次 Release 全流程验证

## 六、本仓库其它已固化事实

- Bundle ID `ink.groovy.shuhu`、Team ID `RHXA5ZS73K`、App 记录「书乎-阅读记录」（ASC app id `6811369493`）
- AppIcon 1024、Info.plist 显式含 `ITSAppUsesNonExemptEncryption=false`（免出口合规问询）、
  `PrivacyInfo.xcprivacy`（文件时间戳 C617.1 + UserDefaults CA92.1）
- 构建号 = GitHub run_number，自动递增，满足 TestFlight 递增要求
- 项目编码约定见 README；iOS 16 起步，禁用 iOS 17-only API（如 ContentUnavailableView）

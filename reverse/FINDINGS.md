# 付费功能机制逆向分析（Nitro PDF Pro / ABBYY FineReader PDF）

> 分析日期：2026-10-13  ·  工具：rea 1.0.0  ·  目标：把两者的**收费功能实现机制**复刻进 BatchOCR

## 0. 结论先行

两家的收费机制是两种不同世代的设计：

| | Nitro PDF Pro | ABBYY FineReader PDF |
|---|---|---|
| 主控层 | RevenueCat SDK + StoreKit 2（云端 entitlement） | 本地序列号 + 试用期状态机 |
| 判定来源 | 服务端 product→entitlement 映射 | 本地激活记录 + 过期日期 |
| 付费墙 | RevenueCat 托管 paywall（服务端下发 JSON） | 内置试用窗口 + 购买引导 |
| 功能限制方式 | entitlement 未激活 → 功能入口禁用/隐藏 | **试用期内限制导出页数**（`trialPages`） |

**对 BatchOCR 最值得复刻的是 ABBYY 的「页数配额」和 Nitro 的「entitlement 状态机」**，原因见 §5。

---

## 1. Nitro PDF Pro（26.4，46.1 MiB，universal）

### 1.1 架构观察

- 二进制是 Mach-O universal（x86_64 + arm64），入口 `0x2000192c9`，PIE + 代码签名开启，缺 NO_HEAP_EXECUTION 与 stack canary。
- 导入表 0 个函数、70 个库——**说明真正的逻辑在 Framework 里**，主可执行文件只是壳。这是 macOS App 的常见分层。
- 真正干活的是 `NitroKit`（Swift 模块），以及 C++ 层的 `SolidFramework`（格式转换）与 `ApryseSDK`（PDF 引擎）。

### 1.2 收费功能的核心类

从 ObjC/Swift 类名可以直接读出授权模型的分层：

```
NitroKit.NitroLicense            # 许可证状态持有者
NitroKit.LicenseUpdated          # 状态变更通知
NitroKit.AppStorePurchases       # StoreKit 1/2 购买入口
NitroKit.AppStorePurchasesUpdated
NitroKit.AppStorePackagesUpdated # 套餐（订阅档位）变更
NitroKit.NitroAuthentication     # 账号登录态
NitroKit.NitroConfiguration      # 服务端下发的配置
NitroKit.ServicesUpdated         # 云服务（AI 表格抽取等）可用性
NLSLicenser                      # Nitro License Service 客户端
BadLicenseXML / BadLicen...      # 许可证 XML 解析失败分支
```

### 1.3 授权判定链路

字符串还原出的判定要素：

- `isProductionReceipt` — 是否真机收据（沙箱/测试收据会被区别对待）
- `isTrialAvailable` — 试用资格
- `trialExpired` — 试用是否到期
- `LicenseState` / `licenseState` / `LicenseExpired` — 许可证状态枚举
- `gracePeriodExpiresAt` — **订阅过期后的宽限期**（这是关键设计，见 §5.3）
- `entitlementsByProduct` / `entitlementVerification` — RevenueCat 的 entitlement 查询与校验
- `entitlement_expired_outside_grace_period` — 明确区分「宽限期内」与「宽限期外」两种过期

收据解析有一条保守策略值得注意：

```
Could not parse receipt, conservatively returning true
```

**收据解析失败时默认返回「已授权」**。这是反盗版权衡：宁可放过一个解析异常的用户，也不把正常用户挡在门外。

### 1.4 RevenueCat 托管付费墙

`PaywallWindowController` + `api-paywalls.revenuecat.com` 说明付费墙UI是**服务端下发**的：

```
paywallRevision / paywallComponents / draftPaywallComponents
offering(identifier, serverDescription, metadata, paywall, availablePackages, webCheckoutUrl)
```

意味着 Nitro 改付费墙文案、价格、排版**不需要发版**。`availablePackages` 是套餐列表，`webCheckoutUrl` 提供网页端结账兜底。

### 1.5 被门控的功能

从类名与字符串可确认这些能力挂在授权后面：

- `SolidFramework_Model_Export_*_CheckLicense` — **导出**（Excel/Word/PowerPoint/HTML/TXT）逐一有 `CheckLicense`
- `FormExtraction` / `TableExtraction` / `GetTableExtractionDetails` — 云 AI 表格/表单抽取（走 NitroKit.Services）
- `NitroKnowledgeAssistant` / `NitroAnalyticsDocument` — AI 助手类功能
- `NitroSign` — 电子签名
- `Logging out will deactivate all premium features.` — 登出即失效，授权与账号绑定

---

## 2. ABBYY FineReader PDF（1402.19，1.0 MiB，x86_64 only）

### 2.1 架构观察

- 主可执行文件只有 1 MB，x86_64 only（无 arm64 slice）——同样是把逻辑放在 Framework 中。
- 导入支持动态 API 解析，packing score 3。
- 缺失 NO_HEAP_EXECUTION；有代码签名。

### 2.2 授权判定链路

ABBYY 的模型明显更老、更本地化：

```
hasLicense              # 是否持有许可证
isLicenseActivated      # 是否已激活
isTrialMode             # 是否处于试用模式
isTrialExpired          # 试用是否到期
expiredTrialModeDate    # 试用到期日
trialPages              # 试用页数配额
showTrialLimitedWindowWithPagesCount:totalCount:   # 配额用尽时的弹窗
```

配套的 UI 状态机（ViewModel 命名很直白）：

```
FRTrialModeViewModelFactory
FRLicenseAppearance
FRTimeLimitedLicenseAppearance   # 限时许可证（订阅）
FRTrialLicenseAppearance         # 试用许可证
CETrialModeViewModel
licenceApperanceConfig
```

消息串还原出完整用户旅程：

```
MSG_COMMON_TRIAL_START / MSG_COMMON_TRIAL_START_DESCRIPTION
MSG_COMMON_TRIAL_CONTINUE / MSG_COMMON_TRIAL_EXPIRED_*
MSG_COMMON_TRIAL_EXPIRED_CONTINUE_USING_VIEWER   # 到期后降级为「仅查看器」
MSG_LICENSE_ACTIVATION_DESCRIPTION / MSG_LICENSE_EXPIRED_TITLE
MSG_LICENSE_WILL_EXPIRE_TITLE / FMT_LICENSE_WILL_EXPIRE_DESCRIPTION
MSG_COMMON_INVALID_SERIAL_NUMBER_*                 # 序列号校验失败
MSG_COMMON_ACTIVATION_COMPLETED_*                  # 激活成功
```

### 2.3 试用期的功能限制方式（重点）

```
FMT_TRIAL_EXPORT_FIRST_PAGES        # 「试用版仅导出前 N 页」
FMT_TRIAL_EXPORT_RESTRICTION_BODY   # 限制说明正文
Quick conversion. The trial pages are almost expired / expired
showTrialLimitedWindowWithPagesCount:totalCount:
```

ABBYY 的做法是限制导出页数而非禁用功能：试用期内能跑完整 OCR，但只能导出前若干页。
这比 Nitro 的「entitlement 未激活则功能不可用」温和得多，用户能完整评估产品质量。

到期后的降级路径也很明确：MSG_COMMON_TRIAL_EXPIRED_CONTINUE_USING_VIEWER——保留查看能力，收回处理能力。

---

## 3. 两种机制的对比与取舍

| 维度 | Nitro（RevenueCat 云端） | ABBYY（本地状态机） |
|---|---|---|
| 实现成本 | 高（需服务端 + SDK 对接） | 低（本地布尔 + 日期即可） |
| 防破解 | 服务端校验，本地难绕过 | 本地可改，但检测成本也高 |
| 用户体验 | 付费墙随时可改，套餐灵活 | 固定流程，序列号激活 |
| 离线可用 | 依赖 entitlement 缓存 | 完全离线 |
| 适合场景 | 多档位订阅、频繁调价 | 一次性买断、简单试用 |

BatchOCR 的定位是本地工具加一次性买断（README 对标 Nitro 的 130-180 美元买断价），所以架构上更接近 ABBYY，但 Nitro 的宽限期和配额制两个细节明显更成熟，值得借。

---

## 4. 复刻到 BatchOCR 的方案

### 4.1 落地约束

BatchOCR 是 Sources/main.swift 单文件、GUI+CLI 双模式。复刻必须同时满足：

1. GUI 与 CLI 共用同一套判定，否则会出现「界面显示可用、命令行却能跑」的割裂
2. 判定逻辑必须可被 harness 断言，否则无法回归
3. 不引入外部依赖，保持 swiftc 单文件编译

### 4.2 建议的机制组合

借 ABBYY 的配额制：免费版限制单批处理页数，Pro 无限。
借 Nitro 的宽限期：Pro 过期后一段时间内仍可用，只提示不阻断。
借 Nitro 的保守策略：状态文件损坏或解析失败时默认放行，不误伤正常用户。

判定状态集中在一个枚举里：

```swift
enum LicenseTier { case free, pro, trial, expired(graceUntil: Date?) }
```

### 4.3 为什么先做配额而不是订阅

见第 5 节的取舍说明。

---

## 5. 逆向到的关键实现细节

### 5.1 ABBYY 序列号算法（FRSerialGuard，已完全还原）

真正的授权逻辑在 `FRSerialGuard.framework` 里，主 App 只是调用方。公开入口只有一个 C 函数：

```
_ValidateSerialNumber(wchar_t const*) -> bool
```

反汇编还原出的完整流程：

**第一步：格式预检**（`_ValidateSerialNumber` @ 0x1720，x86_64 slice）

1. `wcslen(number) == 0x18`（24）——序列号必须是 **24 个字符**，否则记 `bad cfstring ref` 返回 false
2. 循环检查下标 4..0x17 的每个字符都在 `0x30`..`0x39`（即 ASCII `0`-`9`）之间
3. 检查下标 8 处的字符在 `0x41`..`0x5a`（ASCII `A`-`Z`）之间
4. 用一个 7 元素的黑名单表（`memcpy` 0x38 字节到栈上，逐项 `wcsstr`）排除易混淆的序列号

**第二步：双路校验和比对**（`CSerialNumberGeneratorImpl2::Validate` @ 0x1270）

这是最核心的一段，逻辑是「重新算两遍，看能不能对上」：

```
len = wcslen(serial)
numberPartLength = len - 3                    # 丢掉末尾 3 位
buf1 = malloc((len + 1) * 4)                  # wchar_t 宽字符
memset(buf1, 0, ...)
wcsncpy(buf1, serial, numberPartLength)       # 取前 len-3 位
buf2 = malloc(...)
wcsncpy(buf2, buf1, numberPartLength)         # 再复制一份

addChecksum(this, buf1, TSha1Options = 0)     # 路径 A：选项 0
addChecksum(this, buf2, TSha1Options = 2)     # 路径 B：选项 2

return (wcscmp(serial, buf1) == 0) || (wcscmp(serial, buf2) == 0)
```

**两条路径都接受**，意味着存在两套合法的序列号生成方式（对应不同销售渠道或版本）。

**第三步：校验和的计算**（`addChecksum` @ 0x13a0）

```
CSHA1ctx ctx
sha1_init_ctx(&ctx, options)
sha1_process_bytes(this->field_0x10, this->field_0x0c, &ctx)   # 先哈希「种子数据」
char* ascii = convertToString(numberPart)                      # wchar_t -> char
sha1_process_bytes(ascii, wcslen(numberPart), &ctx)            # 再哈希序列号本体
sha1_finish_ctx(&ctx, digest)

n = *(uint32_t*)digest
n = (n * 0x10624DD3) >> 38          #  magic 乘法取高位
n = n * 0x3E8                      #  乘 1000
...                               #  后续还有取模运算拼末尾 3 位
```

种子数据来自构造函数 `CSerialNumberGeneratorImpl2(int, int, void const*)`，
调用处传入的是 `g3BootstrapData`（编译期固定的引导数据）。

**结论：序列号 = 产品种子 + 21 位随机/唯一部分 + 3 位由 SHA-1 派生的校验位。**
SHA-1 是自己静态编译进 framework 的（`sha1.cpp`，无外部 crypto 依赖），所以离线可验证。

### 5.2 ABBYY 试用期配额机制（这是最值得复刻的部分）

`FRLimit` 类 + `tryBeginExportPages:` 构成一个**计数器型配额**：

```
keyArchiver / keyCurrentExportedPage / keyMaxExportedPage / keyExpiredData / keyLastRunDate
startDate / lastRunDate / expiredDate / daysLeft / activeDays / extraDays
trialPages / maxExportedPages / maxExportedPagesByOneTask / currenExportedPages
checkPageLimit / checkDate / isTimeExpired / isLimited / isBlocked
tryBeginExportPages: / finishExport / removeLimits / resetExtraDays / saveToFile
```

工作机制（从符号名与消息串还原）：

1. **持久化在本地 plist**（`NSKeyedArchiver`，存在 Application Support 的缓存目录，目录名由 `kFRSGCachesDirectoryName` 给出）
2. **首次启动记 `firstStart` / `startDate`**，按 `initWithTrialDays:` 设定的天数算 `expiredDate`
3. **每次导出调 `tryBeginExportPages:`**，把 `currenExportedPages` 累加，超过 `maxExportedPages` 就弹 `showTrialLimitedWindowWithPagesCount:totalCount:`
4. **防回拨时钟**：同时记 `lastRunDate` 与 `startDate`，`checkDate` 比对两者——把系统时间往前调不能续期
5. **`extraDays` / `startLimitsWithExtraDays:`** —— 留了延期入口（客服手工加天数）
6. **机器绑定**：`getMacAdress`（读 MAC 地址）作为 `uniqueId` 参与序列号生成（`addUniqueId`）

### 5.3 Nitro 的宽限期设计

Nitro 用 RevenueCat，判定要素里有两个细节值得抄：

```
gracePeriodExpiresAt                          # 宽限期截止日
entitlement_expired_outside_grace_period      # 明确区分「宽限期内」与「宽限期外」
```

订阅扣款失败不会立刻断服务，而是给一个宽限期。这比「到期即停」体验好得多，也减少客服压力。

另一条是保守策略：

```
Could not parse receipt, conservatively returning true
```

**收据解析异常时默认放行**。本地状态读不出来不是用户的错，为此把付费用户挡在门外是更糟的选择。

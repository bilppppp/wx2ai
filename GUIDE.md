# macOS 微信「转发到其他应用」技术设计与桥接实现

本文档详细说明如何基于 macOS 原生 `NSExtension` (`com.apple.share-services`) 规范，构建针对微信桌面端（WeChat for Mac）的系统级文件转发与数据桥接套件，实现**一键转发聊天记录与附件、自动解压归档、智能组装 Prompt 并支持自动粘贴**。

---

## 一、 初衷与背景

在日常开发与协作中，大量的需求讨论、Bug 截图、日志文件以及上下文散落在微信聊天记录（单聊或群聊合并转发）中。macOS 微信桌面端（`WeChat.app`）提供了 **「转发 -> 转发到其他应用」** 功能，可以把多条聊天记录连同图片、文档、代码片段打包导出。

然而存在几个痛点：
1. **默认菜单不支持开发者常用 AI 工具**：日常主力使用的 **Antigravity**（`/Applications/Antigravity.app`）和 **Codex 桌面版**（`/Applications/ChatGPT.app`）未声明针对微信分享导出的 `.zip` 格式的系统扩展，因此不会出现在微信的「选择电脑中的应用」列表里。
2. **严守安全底线，不破坏微信客户端签名或注入**：任何修改微信二进制或注入动态库的方案不仅在客户端更新时极易失效，还会破坏 macOS 系统的安全基线（Code Signature 与 TCC 权限模型）。

**wx2ai 的设计目标**：
- **零侵入微信本体**：完全遵循 macOS 原生 `PlugInKit` 与 `NSSharingService` 规范，通过系统级扩展被微信标准调用。
- **图文与附件全量保留**：微信转发的数据包本质是一个包含 `聊天记录.txt` 及各类媒体/文档附件的 `.zip` 压缩包。自动将其解压到固定目录（`~/WeChatForwards/`），并将结构化的聊天文本与附件绝对路径一并提供给 AI Agent。
- **免手动粘贴与保持工作流上下文**：可直接切回 Antigravity 或 Codex **当前正在进行的会话窗口**，等待焦点就绪后自动将组装好的 Prompt 填入输入框；亦提供**纯剪贴板模式**（不切窗、不抢焦点，随时随地手动按 `⌘V`）。

---

## 二、 系统架构与数据流转

基于 macOS 标准 `NSExtension` (`com.apple.share-services`) 与 `public.zip-archive` UTI 规范，微信与本地桥接应用的数据流转如下：

```
微信 (WeChat Desktop)
  │
  ├─> 1. 打包导出临时 .zip 归档
  │
  └─> 2. 调用 macOS NSSharingServicePicker 查询系统扩展
        │
        ▼
  Share Extension (WechatShare.appex)
        │
        ├─> 3. 沙盒内安全接收附件 (URL/Data)，暂存至 /tmp/wechat-share/
        │
        └─> 4. 唤起对应 Host App (LSUIElement 后台进程)
              │
              ▼
        Host App (wx2ai)
              │
              ├─> 5. 计算 .zip 路径 MD5 并通过 DistributedNotificationCenter 发送 Ack
              │
              ├─> 6. 调用 /usr/bin/ditto 解压至 ~/WeChatForwards/<时间戳_随机码>/
              │
              ├─> 7. 更新 ~/WeChatForwards/latest 软链接
              │
              ├─> 8. 读取聊天记录与附件，生成 Markdown Prompt 存入剪贴板
              │
              └─> 9. 模式响应：
                     ├─ 剪贴板模式: 显示系统通知，保持当前工作窗口
                     └─ 客户端模式: 激活目标应用，等待聚焦后合成 ⌘V 粘贴
```

---

## 三、 免手动「粘贴（`⌘V`）」实现原理

在 `Sources/HostApp/main.swift` 中，提供了两种自动交付方案：

### 方案 A（默认）：保持当前会话上下文 + 自动模拟 `⌘V` 填入输入框
- **工作方式**：激活 `Antigravity` 或 `Codex` 现有窗口（保持在你上次停留的 Thread / Session），主程序轮询等待目标窗口成为前台活动应用并等待 0.25 秒输入框完全就绪，随后通过 `CGEvent`（或 `System Events` 回退）发送一次 `⌘V` 将 Prompt 填入输入框（不自动回车，便于用户确认或补充指令）。
- **首次授权**：macOS 要求发送系统级模拟按键的应用具备「辅助功能」权限。首次触发时系统会提示授权，前往 **「系统设置 -> 隐私与安全性 -> 辅助功能」** 勾选开启即可；未开启时系统自动提示手动按 `⌘V`。

### 方案 B（Codex 可选）：原生 `codex://threads/new` Deep Link 免权限直填
- Codex 桌面版原生支持 `codex://threads/new?prompt=<URL编码Prompt>&path=<路径>`。
- 若希望转发给 Codex 时总是新建一个预填好 Prompt 的会话（且无需辅助功能权限），可将 `WeChatToCodex.app/Contents/Info.plist` 中的 `AutoPasteMode` 改为 `"deeplink"`。

---

## 四、 编译、安装与日常使用

```bash
git clone https://github.com/bilppppp/wx2ai.git
cd wx2ai
./build.sh
./install.sh
```

安装后即可在微信「转发 -> 转发到其他应用 -> 选择电脑中的应用」中看到：
- **转发到剪贴板**
- **转发到 Antigravity**
- **转发到 Codex**

---

## 五、 注意事项：转发文件的存储本质与清理逻辑

在生成的 Prompt 顶部会带有如下路径引用：

```markdown
- **解压目录**: `/Users/<username>/WeChatForwards/2026-10-29_143506_748c`
- **最新记录软链接**: `/Users/<username>/WeChatForwards/latest`
- **聊天记录文本文件**: `/Users/<username>/WeChatForwards/2026-10-29_143506_748c/聊天记录.txt`
- **附件列表**: （无其他附件）
```

1. **这些文件是转发时导出的独立副本，绝非微信内部原文件引用**：
   - 微信客户端内部将聊天文字存储在加密的本地 SQLite 数据库中，图片与媒体文件采用专有格式存放，外部应用无法直接通过路径读取微信内部私有库。
   - 当你在微信点击「转发到其他应用」时，**微信客户端会临时将选中的消息和附件解密导出，打包生成一个新的 `.zip` 压缩包**传给系统分享扩展。
   - 桥接程序将 `.zip` 解压至 `~/WeChatForwards/<时间戳_随机码>/`，以便当聊天记录包含**图片、PDF、代码或超长文本**时，AI Agent 能通过本地绝对路径直接读取并解析这些多模态文件。
2. **清理逻辑与安全性**：
   - **中转 `.zip`（`$TMPDIR/wechat-share/`）**：位于 macOS 临时目录，系统会在重启或周期性维护时自动回收。
   - **解压归档目录（`~/WeChatForwards/`）**：默认保留历史转发文件，每次转发生成一个时间戳子文件夹，并更新快捷软链接 `~/WeChatForwards/latest`。
   - **100% 安全可删**：删除 `~/WeChatForwards/` 下的任何文件**绝不会影响微信内的原始聊天记录**。如需释放磁盘空间，可随时安全执行：
     ```bash
     rm -rf ~/WeChatForwards/*
     ```

---

## ⚖️ 免责声明 (Disclaimer)

1. 本项目仅调用 macOS 官方公开的 `Share Extension` / `NSSharingService` 接口处理用户主动导出的文件，不修改、不注入、不破解任何第三方软件客户端；
2. WeChat、微信、WorkBuddy、Antigravity、Codex 等商标归各自权利人所有，本项目与腾讯、Google、OpenAI 无任何官方关联；
3. 用户在将聊天记录及附件转发至第三方 AI 服务前，应自行审慎评估数据隐私与商业秘密合规要求。

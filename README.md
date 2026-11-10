# mame_autopress — MAME 自动按键插件

按玩家分页的自动按键插件：每一页对应一个玩家，页内 4 个方向与每一个「已赋值」的按键**各自独立开关**，打开即由插件每帧程序化写入输入值，**不需要物理按键触发**。

- 当前版本：**v1.0.5**（20261110-v6）
- 源码：`G:\Python_Code\mame_autopress\plugins\mame_autopress`
- 部署：`Z:\ROM 街机\MAMEUI64 Plus!\mameui\plugins\mame_autopress`
- 兼容：MAMEUI64 Plus!（MAME 0.289 实测），纯 Lua 插件，无外部依赖

---

## 1. 功能

| 能力 | 说明 |
|---|---|
| 每玩家一页 | 主菜单列出 `P1 玩家（分页）`…`P4 玩家（分页）`；进入后是该玩家的方向与按键 |
| 逐项独立开关 | 每个方向（上/下/左/右）、每个按键各一行，`ON`/`OFF` 独立切换 |
| 无需物理按键 | 打开即自动写入，不依赖按住某个触发键（与官方 autofire 相反） |
| 只显示已赋值按键 | 字段必须「存在 + 控制器类 + 非模拟 + 已启用 + 有绑定」才进菜单；没绑定的按钮不会出现，菜单里没有空行 |
| 菜单不显示绑定名 | 分页行只写 `上/下/左/右`、`按钮 N`，不再拼 `(J1_YUP)` 这类尾巴；绑定只用于判断"有没有赋值"，不参与显示 |
| 两种自动模式 | `连发 burst`（按 on/off 帧节奏循环，默认 **1/1** 逐帧交替，可调 1..30）与 `持续按住 hold`（一直按住） |
| 全局总开关 + 一键全开/全关 | 主页可整体启停；分页内可一键全开或全关该玩家 |
| 按键级总开关（跨玩家） | 主页「总开关」下方按按键生成 `总开关（按键 1）`…，一次开关所有玩家的同一个按键；三态显示 `ON`/`OFF`/`混合`，右键全开、左键全关。只对**有赋值**的按键生成 |
| 配置实时落盘 | 任何切换立即写 JSON，重启自动读回；全局设置跨 ROM 共享，各项开关按 ROM 隔离 |
| 保存为默认（其他 ROM 通用） | 把当前 ROM 的开关快照写入 `settings_default.json`，作为**所有 ROM 的兜底默认**（新 ROM 首次进入即继承） |
| 重置本 ROM（回落到默认） | 删掉本 ROM 的 `settings_<rom>.json`，回落到默认并立即生效；旧文件自动备份为 `.bak`，误触可恢复 |

按键显示上限 16，但实际只列 ROM 真正声明且有绑定的项（街机常见 2/3/4 键，6 键较少）。

## 2. 安装

1. 复制整个 `mame_autopress` 目录到 `MAMEUI64 Plus!\mameui\plugins\` 下，确保 `plugins\mame_autopress\plugin.json` 与 `init.lua` 同级。
2. 编辑 `mameui\ini\plugin.ini`，追加一行（列宽与现有条目对齐即可）：

   ```ini
   mame_autopress            1
   ```

3. 重启 MAMEUI64。日志出现下面两行即加载成功：

   ```text
   Starting plugin mame_autopress...
   [mame_autopress] v1.0.5 已启动（配置目录 ./mame_autopress）
   ```

## 3. 菜单操作

游戏中按 `Tab` → **插件菜单** → `AUTOPRESS 自动按键`：

| 按键 | 作用 |
|---|---|
| 上 / 下 | 移动光标 |
| 左 / 右 | 切换开关、调整档位（连发节奏、模式）；按键级总开关行：右键=全开、左键=全关 |
| 回车（select） | 进入玩家分页 / 切换当前项 / 执行命令（按键级总开关行等同右键全开） |
| 取消（back） | 从分页返回主页 |

主页结构：`总开关` → `总开关（按键 1..N）`（按有赋值的按键生成，跨玩家）→ `自动模式`、`连发 按下帧`、`连发 松开帧`、`一键全开`、`一键全关`、`配置`区（`保存为默认（其他 ROM 通用）`、`重置本 ROM（回落到默认）`）、`P1~P4 玩家（分页）`。
分页结构（自上而下）：`上/下/左/右` → `按钮 1..N`（只列有绑定的）→ `全部开启（本玩家）` → `全部按键开启（本玩家）`（只开按键、不动方向）→ `全部关闭（本玩家）` → `← 返回上级`。

## 4. 配置文件

位置：**`<homepath>/mame_autopress/`**，`homepath` 实测为 `.`，即 `mameui.exe` 所在目录。

| 文件 | 内容 | 作用域 |
|---|---|---|
| `settings_global.json` | `master` / `mode` / `on_frames` / `off_frames` | 跨 ROM 共享 |
| `settings_default.json` | 「保存为默认」写入的开关快照 + `from_rom` / `ts` | 所有 ROM 的兜底默认 |
| `settings_<rom>.json` | 各玩家各方向的开关状态 | 单个 ROM |
| `settings_<rom>.json.bak` | 「重置本 ROM」前自动备份的上一份配置 | 单个 ROM，仅误触恢复用 |
| `status.json` | `built` / `players` / `dirs` / `buttons` / `on` / `frame` / `last_error` / `phase` | 诊断用，每 60 帧刷新 |

**读取顺序固定**（后读的覆盖先读的）：

```text
配置目录 settings_default.json
  → 插件目录 settings_default.json（只读兜底，可随插件分发）
  → 配置目录 settings_<rom>.json（必须最后读，盖过默认）
  → 插件目录 settings_<rom>.json（只读兜底）
```

新 ROM 没有自己的文件时自动继承默认；「重置本 ROM」删掉自己的文件后同样回落默认；改默认会影响所有还没有自己文件的 ROM。

目录首次运行自动创建；创建后用 `lfs.attributes` 复查并用 `.write_probe` 探针验证可写，不可写时错误会写进 `status.json` 的 `last_error`，不静默失败。

## 5. 回归与调试

```powershell
$env:PYTHONIOENCODING='utf-8'; [Console]::OutputEncoding=[Text.Encoding]::UTF8
& 'D:\Program Files\Python310\python.exe' scaffold\test_mock.py
```

- 静态门禁 9 项：BOM / LF / `plugin.json` 可解析 / `name`、`type`、`start` / 版本三处一致。
- 行为断言 83 项：用 lupa 真跑 Lua（`mock_env.lua` 模拟 emu/manager/ioport/input/field），覆盖字段收集、无绑定不显示、菜单不显示绑定名、动作下标对齐、连发波形（含默认 1/1 逐帧交替）、未开启零写入、`back` 语义、总开关归还字段、重启读回、`hold` 模式、保存为默认后新 ROM 继承、重置本 ROM 回落默认、按键级总开关的混合态与跨玩家联动、分页「全部按键开启」只动按键不动方向等。
- 全部通过时退出码 0，输出 `合计 92 项：通过 92，失败 0`。

真机取日志：

```powershell
Start-Process mameui.exe -WorkingDirectory $wd -ArgumentList @(
  'xmen','-log','-verbose','-window','-seconds_to_run','6',
  '-noreadconfig','-nowriteconfig',
  '-cfg_directory',$tmp,'-nvram_directory',$tmp,'-snapshot_directory',$tmp,'-state_directory',$tmp
) -RedirectStandardOutput out.txt -RedirectStandardError err.txt -Wait
```

写入是否真的生效，可用只读探针验证（改部署侧临时版本，跑完务必还原）：

```powershell
python scaffold\_probe_patch.py patch     # 插入 port:read() 逐帧打印
# 运行 mameui，看日志中端口值是否随连发节奏在 0/1 间交替
python scaffold\_probe_patch.py restore   # 从 G 盘源码覆盖还原
```

## 6. 已知限制

- **物理正按住的键无法被接管**：MAME 每帧用物理状态刷新字段，`set_value` 会被顶回；本插件定位纯自动（没人碰键盘），不受影响。
- 菜单无文本输入控件、单行无法上色（MAME 插件菜单的固有限制），只能左右切换/回车确认。
- 每个玩家一页；ROM 未声明输入的玩家不会出现在主页。
- 按键显示上限 16，实际数量由 ROM 声明且有绑定的字段决定。

## 7. 目录结构

```text
mame_autopress/
├── plugins/mame_autopress/     # 插件本体（部署用）
│   ├── init.lua                # 28.4 KB，v1.0.5
│   └── plugin.json
├── scaffold/                   # 回归脚手架（不部署）
│   ├── mock_env.lua            # MAME 环境模拟
│   ├── test_mock_cases.lua     # 83 项行为断言
│   ├── test_mock.py            # 驱动：静态 + 行为
│   ├── _probe_patch.py         # 真机只读探针 patch/restore
│   └── probe_autopress.lua     # 探针逻辑（machine script 版，MAMEUI 下不生效，留档）
├── version/20261110-v1/        # 归档 v1.0.0：init.lua + plugin.json + 迭代记录
├── version/20261110-v2/        # 归档 v1.0.1
├── version/20261110-v3/        # 归档 v1.0.2
├── version/20261110-v4/        # 归档 v1.0.3
├── version/20261110-v5/        # 归档 v1.0.4
├── version/20261110-v6/        # 归档 v1.0.5
├── MAME插件开发避坑指南.md      # 开发守则（来源：mame_kbd 项目，原样留档）
└── 软件升级迭代记录.md
```

## 8. 开发约定

开发前请先读 [MAME插件开发避坑指南.md](MAME插件开发避坑指南.md)（原样拷自 `G:\Python_Code\mame_kbd`）。几条最常踩的：

- `plugin.json` 必须无 BOM，否则插件根本不加载。
- `menu_items()` 里动作表下标用 `actions[#items]`，用 `#items+1` 会整体错位（点 A 改 B）。
- `back` 事件要在回调最前面处理；子页 `return true` 吞掉，主页 `return false`。
- 连发的松开相写 `set_value(0)`，不要用 `clear_value()`（会被物理状态顶回）。
- `set_value` 只维持到下一次输入刷新，必须每帧续写。
- 玩家号从字段名解析，`field.player` 恒为 0，不可信。
- 帧回调订阅必须存进文件级 `local`，否则被 GC、回调永不触发。
- 配置放 `<homepath>/mame_autopress/`，不要放插件目录。

### 所有 MAME 插件必备的两项（用户定下的通用要求）

任何 MAME 插件的主页都必须有这两项，位置固定在「配置」区，行数恒定：

1. **保存为默认（其他 ROM 通用）** —— 把当前设置快照写成 `settings_default.json`，作为其他 ROM / 重置后的兜底。
2. **重置本 ROM（回落到默认）** —— 删除本 ROM 的覆盖文件，回落到默认（不是清空成全 OFF），删前自动留 `.bak`。

配套约定：读取顺序为 `配置目录默认 → 插件目录默认（只读兜底）→ 配置目录本 ROM → 插件目录本 ROM`；切换即落盘，停止通知里不要重复保存（否则「重置」会被立刻固化）。

# 排障：非管理员运行时数据库只读 / 设置写不进去

2026-10-20 现场记录。现象、判据、根因、修法各一段，照着走能在 5 分钟内定位或排除。

## 现象

非提权（普通双击）启动后：

```
ERROR [app] 数据库打开失败，降级为无历史模式：SqliteException(8):
  while executing, attempt to write a readonly database
  Causing statement: INSERT INTO meta(key, value) VALUES('schema_version', '3') ...
WARNING [sync] 保存同步设置失败：PathAccessException: Cannot open file,
  path = '...\AppData\Roaming\webhtv-pc\settings.json.sync.tmp'
  (OS Error: 拒绝访问。, errno = 5)
```

同时 `%LOCALAPPDATA%\webhtv-pc\logs\webhtv-pc.log` 的修改时间**停在某个时刻不再前进**（日志也写不进去）。以管理员身份运行则一切正常。

## 判据：先分清「不是权限问题」

```powershell
# 1) ACL 是否真的缺写权限？（多数情况下不缺）
icacls "$env:LOCALAPPDATA\webhtv-pc"        # 期望：Maple:(I)(F)
icacls "$env:LOCALAPPDATA\webhtv-pc\webhtv-pc.sqlite3"

# 2) 同一账户的普通进程能不能写？（能写 → 不是 ACL）
Set-Content "$env:LOCALAPPDATA\webhtv-pc\.probe" x; Remove-Item "$env:LOCALAPPDATA\webhtv-pc\.probe"
```

两条都通过、app 却写不进去 ⇒ 问题在**进程的身份**，不在文件权限。

## 根因：exe 所在目录带 Low 完整性标签

Windows 强制完整性控制（MIC）规定：**Low 完整性进程不能写 Medium 完整性对象**。
`%LOCALAPPDATA%` / `%APPDATA%` 下的对象默认是 Medium，于是数据库、`settings.json.sync.tmp`、
日志文件全部只读；而 DACL 里 `Maple:(I)(F)` 照旧，`icacls` 看不出问题。

本次现场：构建产物所在的 Orca 工作区目录被打了 Low 标签，构建出的 `webhtv_pc.exe`
继承该标签 → 每次双击都以 Low IL 启动。管理员能跑是因为提权后是 High IL，可向下写 Medium。

检测（PowerShell，读 SACL 里的强制标签 ACE）：

```powershell
# 进程 IL
$p = Start-Process .\webhtv_pc.exe -PassThru   # 双击等价
# 用 Process Explorer / Get-Process 看 Integrity 列；或下面的文件标签检查

# 文件/目录标签（0x11 = SYSTEM_MANDATORY_LABEL_ACE）
icacls .\webhtv_pc.exe                        # 不含标签时看不到，需读 SACL
```

判定要点：**exe 的标签决定进程的完整性级别**，与账户是否管理员无关。

## 修法

```powershell
# 修构建产物（发版前必做；也要修整棵 Release 目录）
icacls "<Release 目录>" /setintegritylevel "(OI)(CI)Medium" /T /C

# 若是工作区根目录被打标（会导致以后每次构建又继承 Low），连根一起修
icacls "<工作区根目录>" /setintegritylevel "(OI)(CI)Medium" /T /C
```

验证：修复后非提权启动应满足

```powershell
(Get-Item "$env:LOCALAPPDATA\webhtv-pc\logs\webhtv-pc.log").LastWriteTime   # 变成刚才
Test-Path "$env:LOCALAPPDATA\webhtv-pc\webhtv-pc.sqlite3-wal"                # 运行中为 True
```

## 应用侧加固（已落地）

这类故障以前是**静默**的：唯一的线索（`PathAccessException`）恰好写不进日志文件，
用户在 UI 上只能感到「历史没了」。现在的处理：

- `AppPaths.probeWritable()`：启动时对 config/data/log 三个目录各建一个探针文件再删，
  真的写一次——MIC 只读在 DACL 上看不出来；
- 失败时**同时写 stderr**（日志文件本身可能就是不可写的那个），并把失败目录带进
  `StartupInfo.storageWarnings`；
- UI 顶部显示「数据目录不可写，本次运行不会保存历史与设置」横幅，设置页
  `运行信息` 里也会出现 `writable=NO: <目录>: <错误>`；
- 日志里按目录逐条记 `数据目录不可写…`（scope=`storage`）。

## 一句话给用户

不是「必须用管理员运行」，而是**这个 exe 所在的目录被打上了低完整性标签**，
导致非提权进程只能读不能写。对 exe 目录执行一次
`icacls <目录> /setintegritylevel Medium /T` 即可恢复正常双击使用。

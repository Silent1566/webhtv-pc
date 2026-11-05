# 第三方依赖许可登记（sidecars/spider-host-jvm/lib/）

本目录的 17 个 jar **随仓库入库、随发行包分发**，构建与运行都不下载任何东西。
清单与 `build.ps1` 里的 `$Dependencies` 一一对应：字节数不符会让构建失败，升级版本时两处同步改。

合计 17 个 jar，约 2.51 MiB。

## 用什么、为什么

- **dex2jar 2.4.28 闭包（13 个 jar）**：把 Android 站源 jar 里的 `classes.dex` 转成 JVM 字节码
  （`DexIntake`）。入口类 `com.googlecode.dex2jar.tools.Dex2jarCmd` 在 `dex-tools.jar`，不在
  `dex-translator.jar`；jar 内 MANIFEST 无 `Main-Class`，必须显式 `-cp`/类路径。
- **asm 9.x 闭包（5 个 jar：asm / asm-analysis / asm-commons / asm-tree / asm-util）**：
  dex2jar 的输出栈帧与字节码不一致，JVM 校验器会以 `VerifyError` 拒绝加载，`DexIntake` 用
  asm 丢弃原帧并重算。
- **gson / org.json / okhttp / okio**：桌面 Java 站源（`tvbox-java-v1`）的常见运行时依赖，
  站源类加载时按需解析。

## 逐项登记

| # | jar | 版本 | 字节数 | 许可 | 来源 URL | jar 内自带许可文本 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `asm.jar` | 9.x（dex2jar 2.4.28 闭包） | 126113 | Apache-2.0 | https://gitlab.ow2.org/asm/asm | 否 |
| 2 | `asm-analysis.jar` | 9.x（同上） | 35151 | Apache-2.0 | https://gitlab.ow2.org/asm/asm | 否 |
| 3 | `asm-commons.jar` | 9.x（同上） | 73498 | Apache-2.0 | https://gitlab.ow2.org/asm/asm | 否 |
| 4 | `asm-tree.jar` | 9.x（同上） | 51934 | Apache-2.0 | https://gitlab.ow2.org/asm/asm | 否 |
| 5 | `asm-util.jar` | 9.x（同上） | 94559 | Apache-2.0 | https://gitlab.ow2.org/asm/asm | 否 |
| 6 | `commons-io.jar` | 2.x（dex2jar 2.4.28 闭包） | 538910 | Apache-2.0 | https://commons.apache.org/proper/commons-io/ | 是（`META-INF/LICENSE.txt`、`META-INF/NOTICE.txt`） |
| 7 | `d2j-base-cmd.jar` | 2.4.28 | 13936 | Apache-2.0 | https://github.com/pxb1988/dex2jar | 否 |
| 8 | `dex-ir.jar` | 2.4.28 | 228347 | Apache-2.0 | https://github.com/pxb1988/dex2jar | 否 |
| 9 | `dex-reader-api.jar` | 2.4.28 | 73111 | Apache-2.0 | https://github.com/pxb1988/dex2jar | 否 |
| 10 | `dex-reader.jar` | 2.4.28 | 67827 | Apache-2.0 | https://github.com/pxb1988/dex2jar | 否 |
| 11 | `dex-tools.jar` | 2.4.28 | 160735 | Apache-2.0 | https://github.com/pxb1988/dex2jar | 否 |
| 12 | `dex-translator.jar` | 2.4.28 | 122028 | Apache-2.0 | https://github.com/pxb1988/dex2jar | 否 |
| 13 | `dex-writer.jar` | 2.4.28 | 103930 | Apache-2.0 | https://github.com/pxb1988/dex2jar | 否 |
| 14 | `gson-2.11.0.jar` | 2.11.0 | 298435 | Apache-2.0 | https://github.com/google/gson | 否 |
| 15 | `json-20240303.jar` | 20240303 | 78332 | Public Domain | https://github.com/stleary/JSON-java | 否 |
| 16 | `okhttp-3.14.9.jar` | 3.14.9 | 430488 | Apache-2.0 | https://github.com/square/okhttp | 部分（见下） |
| 17 | `okio-1.17.6.jar` | 1.17.6 | 92255 | Apache-2.0 | https://github.com/square/okio | 否 |

许可判定依据：dex2jar 2.4.28（`de.femtopedia.dex2jar`）、gson 2.11.0、okhttp 3.14.9、okio 1.17.6
的 Maven Central POM 均带 `<licenses>` 声明；org.json（`json-20240303`）在其 README 声明
Public Domain。两者均可随产物分发。

## 单独说明：okhttp 3.14.9 内的 MPL-2.0 内容

`okhttp-3.14.9.jar` 内含 `okhttp3/internal/publicsuffix/NOTICE`，它只覆盖同目录下的
`publicsuffixes.gz`（Public Suffix List 数据，**MPL-2.0**），不改变 okhttp 代码本身的
Apache-2.0 许可。MPL-2.0 是文件级 copyleft：随包分发该数据文件时须保留其许可声明，
已随 jar 一并保留，无需额外处理。若将来移除 okhttp 或替换其 publicsuffix 数据，此条随之失效。

## 缺失的许可文本

多数 jar 不内嵌 `LICENSE`/`NOTICE`（上表已标注）。这里不再额外附带许可全文：
Apache-2.0 要求分发时给出许可副本，本项目在仓库根 `LICENSE` 与本文档中指向
<https://www.apache.org/licenses/LICENSE-2.0> 履行该义务。

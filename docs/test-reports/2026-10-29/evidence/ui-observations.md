# 原生界面实测观察

日期：2026-10-29。对象：工作区 `macMTP.app`，版本 1.0.6 build 5。
操作工具：原生应用 AX 读取、鼠标和键盘事件（cua_repl）。本文是操作后观察记录，不是截图或录像；未保存完整 AX 历史。

| 场景 | 实际操作及可见结果 | 判定边界 |
| --- | --- | --- |
| 启动自动连接 | 启动先显示 No Device Detected，随后 iFlytek AiNote Gallery、设备能力和根目录加载；最终 10 项 | 启动前设备已连接；不等于物理拔插测试 |
| MTP 新建文件夹 | 右侧空白区激活、Command-N、输入 macmtp-ui-test-20261029、点击 Create；双击进入空目录 | 仅本轮独立测试根 |
| 路径输入焦点 | 编辑本地面包屑路径；Command-A 后输入完整路径，字段出现新路径追加旧的 /path/to/home；普通 Return 未正常提交。setValue 精确设置后 shift+Return 可提交 | BUG-08；未测试该缺陷下的文件删除，不推断已发生误删 |
| 多选拖动 | 选中 3 文件，从 two.pdf / 三号 文件.epub 启动向 MTP 空白区拖动，多次尝试。日志 dragProvider 包含全部 3 项，但无对应目标 handleDrop 回调，无目标文件生成 | 工具与原生拖动链路尚未区分；不判通过，也不据此判定原问题仍存在 |
| UI 上传 | 本地 input 中 3 文件 Command-A、Command-C；MTP 测试根 Command-V。目标 3 项，Transfer Complete，3 of 3 files，100%，6 KB/6 KB | 真实未抑制通知的应用；未核实系统通知是否显示 |
| UI 下载 | MTP 3 文件 Command-A、Command-C；本地 return 空目录 Command-V。回读 3 项 | ui-roundtrip-hashes.json 核对全部 SHA-256 |
| 筛选 | 本地、MTP 输入 .PDF 仅 two.pdf；输入 ONE 仅 one.txt。清空恢复 3 项。本地不存在名称显示 No files match the filter；Clear Filter 恢复 | 未验证“筛选时保留目录” |
| 排序 | 本地点 Size 切换升降序；降序依次 3 KB、2 KB、1 KB | 未完成四字段两端完整矩阵 |
| 视图 | 本地 List → Icons → Large Icons → List，均显示 3 项 | 样本 PDF 为占位字节，仅验证文件传输，不作为有效 PDF 预览证据 |
| 选择 | 两端全选后各显示 3 selected；本地点击 one.txt 后显示 1 selected | 未完成 Command/Shift 组合矩阵；一次 AX modifier click 未见选中数变化，未据此报产品缺陷 |
| 关于 | Info 打开版本 1.0.6、LibMTP 说明；关闭返回主窗口 | 入口为工具栏，未完整覆盖菜单帮助 |
| 偏好设置 | 打开显示 Follow System，自动连接开启，两端隐藏关闭，Swap 关闭，字号 1.0x，日志上传关闭；关闭返回正常 | 未切换这些设置，未验证持久化/语言重启 |
| 布局 | 清理后重启，点击单栏仅显示 MTP 根 10 项；点击双栏恢复两端，设备根仍为 10 项 | 已恢复双栏；交换位置及布局持久化未全覆盖 |

本地输入：`/path/to/home/Downloads/macmtp-ui-test-20261029/input`
本地回读：`/path/to/home/Downloads/macmtp-ui-test-20261029/return`
设备测试根：`/macmtp-ui-test-20261029`

原生拖动日志见 ui-drag.log，仅截取本轮测试时间及测试路径。设备测试根已在核对 SHA-256 后删除，其他根路径集合不变，见 ui-cleanup.json；应用已重新启动并连接，停留根目录，无活动传输。本地样本及回读保留用于复查。

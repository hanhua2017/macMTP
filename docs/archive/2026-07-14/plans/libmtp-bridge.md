# LibMTPBridge Implementation Plan

> 历史归档：原路径 `docs/superpowers/plans/2026-07-14-libmtp-bridge.md`。文内命令与非链接路径保留当时记录，不代表当前项目布局或实现。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增一个基于 `libmtp 1.1.23` 的 `LibMTPBridge` 后端，先与现有 Kalam 后端并行运行，最终允许 macMTP 在不依赖 OpenMTP/Kalam Go c-archive 的情况下完成 MTP 文件浏览和传输。

**Architecture:** 保持 Swift 上层的 MTP 业务接口稳定，在 `Sources/macmtp/MTP` 内新增后端无关的 `MTPBridgeProtocol`，让 `KalamBridge` 和 `LibMTPBridge` 都实现同一组方法。`LibMTPBridge` 通过一个小型 C target `CLibMTPBridge` 封装 `libmtp` 的生命周期、对象 ID 查询、目录遍历、文件传输和错误栈读取，Swift 侧只处理 actor 串行化、模型转换和 UI 进度回调。

**Tech Stack:** Swift 6、SwiftPM、C、libmtp 1.1.23、libusb-1.0、libgcrypt、libgpg-error、iconv、IOKit.framework、macOS 14+。

## Global Constraints

- 默认语言：中文；代码命名保持英文。
- git 提交信息使用中文。
- 不删除 Kalam 后端，直到 libmtp 后端完成真实设备验收。
- 不修改 UI 布局，除非任务明确要求新增后端选择入口。
- 所有 MTP 操作必须串行执行；不得并发调用同一个 `LIBMTP_mtpdevice_t *`。
- `LibMTPBridge` 的 Swift 公共方法签名必须与现有 `KalamBridge` 调用面兼容，优先减少 `MTPDeviceManager` 和 `FileTransferService` 改动。
- libmtp 源码路径默认使用仓库同级目录：`../libmtp-1.1.23`。
- 第一阶段只支持连接第一个检测到的 MTP 设备。
- 保留现有 “Fix MTP Connection” 行为；libmtp 后端失败时必须把 libmtp 错误栈转成可读错误。
- 真实设备验收设备至少包含当前已验证的 `iFlytek AiNote Air2`。

---

## File Structure

- Create: `Sources/macmtp/MTP/MTPBridgeProtocol.swift`
  - 定义后端无关的 Swift MTP 操作接口。
- Create: `Sources/macmtp/MTP/MTPBridgeModels.swift`
  - 定义从 `GoResponseModels.swift` 中抽出的通用模型别名或新模型，执行过程中先复用现有 `Go*` 模型以降低改动面。
- Create: `Sources/CLibMTPBridge/include/libmtp_bridge.h`
  - 暴露给 Swift 的 C bridge API，避免 Swift 直接操作 libmtp 指针和结构体。
- Create: `Sources/CLibMTPBridge/libmtp_bridge.c`
  - 实现 libmtp 生命周期、目录查询、上传下载、错误处理。
- Create: `Sources/CLibMTPBridge/module.modulemap`
  - SwiftPM C target 模块定义。
- Create: `Sources/macmtp/MTP/LibMTPBridge.swift`
  - Swift actor，封装 C bridge，提供和 `KalamBridge` 对齐的方法。
- Create: `Tests/macmtpTests/MTPPathResolverTests.swift`
  - 测试路径规范化、父目录解析、路径拼接。
- Create: `Tests/macmtpTests/LibMTPProgressTests.swift`
  - 测试 libmtp 单文件进度到现有传输模型的转换。
- Modify: `Package.swift`
  - 新增测试 target、`CLibMTPBridge` target、libmtp 链接参数和主 target 依赖。
- Modify: `Sources/macmtp/MTP/KalamBridge.swift`
  - 让 `KalamBridge` 显式实现 `MTPBridgeProtocol`。
- Modify: `Sources/macmtp/MTP/MTPDeviceManager.swift`
  - 将 `private let bridge = KalamBridge.shared` 改为后端工厂提供。
- Modify: `Sources/macmtp/Services/FileTransferService.swift`
  - 将 `private let bridge = KalamBridge.shared` 改为后端工厂提供。
- Modify: `Sources/macmtp/Views/PreferencesView.swift`
  - 若当前偏好页已有 “MTP Engine”，添加 `LibMTP` 选项；否则仅添加 `AppStorage` 支持，不扩大 UI 范围。
- Modify: `Resources/en.lproj/Localizable.strings`
  - 新增 LibMTP 后端文案。
- Modify: `Resources/zh-Hans.lproj/Localizable.strings`
  - 新增 LibMTP 后端中文文案。
- Modify: `scripts/build.sh`
  - 支持使用 `../libmtp-1.1.23` 的构建产物链接和打包；保留 Kalam 构建路径。
- Modify: `README.md`
  - 记录 libmtp 后端为实验选项和构建依赖。
- Modify: `README.zh-CN.md`
  - 中文同步说明。

---

### Task 1: 建立后端接口和测试基础

**Files:**
- Create: `Sources/macmtp/MTP/MTPBridgeProtocol.swift`
- Modify: `Sources/macmtp/MTP/KalamBridge.swift`
- Modify: `Package.swift`
- Create: `Tests/macmtpTests/MTPBridgeProtocolTests.swift`

**Interfaces:**
- Consumes: existing `GoDeviceInfoData`, `GoStorageData`, `GoFileInfo`, `GoTransferPreprocessData`, `GoTransferProgressInfo` in `Sources/macmtp/MTP/GoResponseModels.swift`
- Produces:
  - `public protocol MTPBridgeProtocol: Sendable`
  - `KalamBridge: MTPBridgeProtocol`

- [ ] **Step 1: Add test target to `Package.swift`**

Add this target after the executable target:

```swift
.testTarget(
    name: "macmtpTests",
    dependencies: [
        "macmtp"
    ],
    path: "Tests/macmtpTests"
)
```

Expected complete `targets` tail shape:

```swift
.executableTarget(
    name: "macmtp",
    dependencies: [
        "CKalam",
        "Sentry"
    ],
    path: "Sources/macmtp",

    linkerSettings: [
        .unsafeFlags(kalamLinkerFlags + libusbLinkerFlags),
        .linkedFramework("CoreFoundation"),
        .linkedFramework("Security"),
        .linkedFramework("IOKit"),
    ]
),
.testTarget(
    name: "macmtpTests",
    dependencies: [
        "macmtp"
    ],
    path: "Tests/macmtpTests"
)
```

- [ ] **Step 2: Create `MTPBridgeProtocol.swift`**

```swift
import Foundation

public protocol MTPBridgeProtocol: Sendable {
    func initialize() async throws -> GoDeviceInfoData
    func fetchStorages() async throws -> [GoStorageData]
    func listDirectory(storageId: UInt32, path: String, recursive: Bool) async throws -> [GoFileInfo]
    func makeDirectory(storageId: UInt32, path: String) async throws
    func deleteFiles(storageId: UInt32, paths: [String]) async throws
    func renameFile(storageId: UInt32, path: String, newName: String) async throws
    func checkFilesExist(storageId: UInt32, paths: [String]) async throws -> [Bool]
    func uploadFiles(
        storageId: UInt32,
        sources: [String],
        destination: String,
        onPreprocess: @escaping @Sendable (GoTransferPreprocessData) -> Void,
        onProgress: @escaping @Sendable (GoTransferProgressInfo) -> Void
    ) async throws
    func downloadFiles(
        storageId: UInt32,
        sources: [String],
        destination: String,
        onPreprocess: @escaping @Sendable (GoTransferPreprocessData) -> Void,
        onProgress: @escaping @Sendable (GoTransferProgressInfo) -> Void
    ) async throws
    func walk(storageId: UInt32, path: String, recursive: Bool, skipHidden: Bool) async throws -> [GoFileInfo]
    func dispose() async throws
}
```

- [ ] **Step 3: Make `KalamBridge` conform**

Change:

```swift
public actor KalamBridge {
```

To:

```swift
public actor KalamBridge: MTPBridgeProtocol {
```

- [ ] **Step 4: Add a compile-only protocol test**

Create `Tests/macmtpTests/MTPBridgeProtocolTests.swift`:

```swift
import XCTest
@testable import macmtp

final class MTPBridgeProtocolTests: XCTestCase {
    func testKalamBridgeConformsToProtocol() async {
        let bridge: any MTPBridgeProtocol = KalamBridge.shared
        _ = bridge
    }
}
```

- [ ] **Step 5: Run test**

Run:

```bash
swift test --filter MTPBridgeProtocolTests
```

Expected: test compiles and passes. If link fails because `Sources/CKalam/libkalam.a` is missing, run:

```bash
./scripts/build.sh --debug
swift test --filter MTPBridgeProtocolTests
```

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/macmtp/MTP/MTPBridgeProtocol.swift Sources/macmtp/MTP/KalamBridge.swift Tests/macmtpTests/MTPBridgeProtocolTests.swift
git commit -m "新增 MTP 后端协议"
```

---

### Task 2: 新增后端选择工厂但默认仍使用 Kalam

**Files:**
- Create: `Sources/macmtp/MTP/MTPBridgeFactory.swift`
- Modify: `Sources/macmtp/MTP/MTPDeviceManager.swift`
- Modify: `Sources/macmtp/Services/FileTransferService.swift`
- Create: `Tests/macmtpTests/MTPBridgeFactoryTests.swift`

**Interfaces:**
- Consumes: `MTPBridgeProtocol`
- Produces:
  - `public enum MTPBridgeEngine: String, CaseIterable, Sendable`
  - `public enum MTPBridgeFactory`
  - `public static func sharedBridge() -> any MTPBridgeProtocol`

- [ ] **Step 1: Create failing factory test**

Create `Tests/macmtpTests/MTPBridgeFactoryTests.swift`:

```swift
import XCTest
@testable import macmtp

final class MTPBridgeFactoryTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "mtpEngine")
        super.tearDown()
    }

    func testDefaultEngineIsKalam() {
        XCTAssertEqual(MTPBridgeFactory.selectedEngine(), .kalam)
    }

    func testUnknownEngineFallsBackToKalam() {
        UserDefaults.standard.set("missing", forKey: "mtpEngine")
        XCTAssertEqual(MTPBridgeFactory.selectedEngine(), .kalam)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter MTPBridgeFactoryTests
```

Expected: FAIL with `cannot find 'MTPBridgeFactory' in scope`.

- [ ] **Step 3: Create `MTPBridgeFactory.swift`**

```swift
import Foundation

public enum MTPBridgeEngine: String, CaseIterable, Sendable {
    case kalam
    case libmtp
}

public enum MTPBridgeFactory {
    public static func selectedEngine(defaults: UserDefaults = .standard) -> MTPBridgeEngine {
        guard let raw = defaults.string(forKey: "mtpEngine"),
              let engine = MTPBridgeEngine(rawValue: raw) else {
            return .kalam
        }
        return engine
    }

    public static func sharedBridge(defaults: UserDefaults = .standard) -> any MTPBridgeProtocol {
        switch selectedEngine(defaults: defaults) {
        case .kalam:
            return KalamBridge.shared
        case .libmtp:
            return KalamBridge.shared
        }
    }
}
```

The `.libmtp` branch intentionally returns Kalam until Task 7 adds `LibMTPBridge`.

- [ ] **Step 4: Inject factory into managers**

In `Sources/macmtp/MTP/MTPDeviceManager.swift`, change:

```swift
private let bridge = KalamBridge.shared
```

To:

```swift
private let bridge: any MTPBridgeProtocol = MTPBridgeFactory.sharedBridge()
```

In `Sources/macmtp/Services/FileTransferService.swift`, change:

```swift
private let bridge = KalamBridge.shared
```

To:

```swift
private let bridge: any MTPBridgeProtocol = MTPBridgeFactory.sharedBridge()
```

- [ ] **Step 5: Run tests and build**

Run:

```bash
swift test --filter MTPBridgeFactoryTests
swift build
```

Expected: both commands pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/macmtp/MTP/MTPBridgeFactory.swift Sources/macmtp/MTP/MTPDeviceManager.swift Sources/macmtp/Services/FileTransferService.swift Tests/macmtpTests/MTPBridgeFactoryTests.swift
git commit -m "新增 MTP 后端选择工厂"
```

---

### Task 3: 实现 Swift 侧路径工具

**Files:**
- Create: `Sources/macmtp/MTP/MTPPathResolver.swift`
- Create: `Tests/macmtpTests/MTPPathResolverTests.swift`

**Interfaces:**
- Produces:
  - `enum MTPPathResolver`
  - `static func normalize(_ path: String) -> String`
  - `static func parentPath(of path: String) -> String`
  - `static func fileName(of path: String) -> String`
  - `static func join(parent: String, name: String) -> String`

- [ ] **Step 1: Write failing tests**

Create `Tests/macmtpTests/MTPPathResolverTests.swift`:

```swift
import XCTest
@testable import macmtp

final class MTPPathResolverTests: XCTestCase {
    func testNormalizeRootAndRepeatedSlashes() {
        XCTAssertEqual(MTPPathResolver.normalize(""), "/")
        XCTAssertEqual(MTPPathResolver.normalize("/"), "/")
        XCTAssertEqual(MTPPathResolver.normalize("//Music///Rock/"), "/Music/Rock")
    }

    func testParentPath() {
        XCTAssertEqual(MTPPathResolver.parentPath(of: "/Music/Rock/song.mp3"), "/Music/Rock")
        XCTAssertEqual(MTPPathResolver.parentPath(of: "/Music"), "/")
        XCTAssertEqual(MTPPathResolver.parentPath(of: "/"), "/")
    }

    func testFileName() {
        XCTAssertEqual(MTPPathResolver.fileName(of: "/Music/Rock/song.mp3"), "song.mp3")
        XCTAssertEqual(MTPPathResolver.fileName(of: "/Music"), "Music")
        XCTAssertEqual(MTPPathResolver.fileName(of: "/"), "")
    }

    func testJoin() {
        XCTAssertEqual(MTPPathResolver.join(parent: "/", name: "Music"), "/Music")
        XCTAssertEqual(MTPPathResolver.join(parent: "/Music", name: "Rock"), "/Music/Rock")
        XCTAssertEqual(MTPPathResolver.join(parent: "/Music/", name: "/Rock/"), "/Music/Rock")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter MTPPathResolverTests
```

Expected: FAIL with `cannot find 'MTPPathResolver' in scope`.

- [ ] **Step 3: Implement `MTPPathResolver.swift`**

```swift
import Foundation

public enum MTPPathResolver {
    public static func normalize(_ path: String) -> String {
        let parts = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !parts.isEmpty else { return "/" }
        return "/" + parts.joined(separator: "/")
    }

    public static func parentPath(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/" else { return "/" }
        let ns = normalized as NSString
        let parent = ns.deletingLastPathComponent
        return normalize(parent.isEmpty ? "/" : parent)
    }

    public static func fileName(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/" else { return "" }
        return (normalized as NSString).lastPathComponent
    }

    public static func join(parent: String, name: String) -> String {
        let cleanParent = normalize(parent)
        let cleanName = name
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
        guard !cleanName.isEmpty else { return cleanParent }
        if cleanParent == "/" {
            return "/" + cleanName
        }
        return cleanParent + "/" + cleanName
    }
}
```

- [ ] **Step 4: Run test**

Run:

```bash
swift test --filter MTPPathResolverTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/macmtp/MTP/MTPPathResolver.swift Tests/macmtpTests/MTPPathResolverTests.swift
git commit -m "新增 MTP 路径解析工具"
```

---

### Task 4: 新增 CLibMTPBridge C target 骨架

**Files:**
- Create: `Sources/CLibMTPBridge/include/libmtp_bridge.h`
- Create: `Sources/CLibMTPBridge/libmtp_bridge.c`
- Create: `Sources/CLibMTPBridge/module.modulemap`
- Modify: `Package.swift`

**Interfaces:**
- Produces C API:
  - `mtp_bridge_handle_t *mtp_bridge_create(void)`
  - `void mtp_bridge_destroy(mtp_bridge_handle_t *handle)`
  - `const char *mtp_bridge_last_error(mtp_bridge_handle_t *handle)`
  - `void mtp_bridge_free_string(char *value)`

- [ ] **Step 1: Add C target to `Package.swift`**

Add libmtp path constants near existing linker flag constants:

```swift
let libmtpRoot = env["MACMTP_LIBMTP_ROOT"] ?? "\(packageDir)/../libmtp-1.1.23"
let libmtpIncludeDir = "\(libmtpRoot)/src"
let libmtpLibDir = env["MACMTP_LIBMTP_LIB_DIR"] ?? "\(libmtpRoot)/src/.libs"
let libmtpLinkerFlags = [
    "-L\(libmtpLibDir)",
    "-lmtp",
    "-L/opt/homebrew/opt/libusb/lib",
    "-lusb-1.0",
    "-L/opt/homebrew/opt/libgcrypt/lib",
    "-lgcrypt",
    "-L/opt/homebrew/opt/libgpg-error/lib",
    "-lgpg-error",
    "-liconv",
]
```

Add target before `CKalam`:

```swift
.target(
    name: "CLibMTPBridge",
    path: "Sources/CLibMTPBridge",
    sources: ["libmtp_bridge.c"],
    publicHeadersPath: "include",
    cSettings: [
        .unsafeFlags(["-I\(libmtpIncludeDir)"])
    ],
    linkerSettings: [
        .unsafeFlags(libmtpLinkerFlags),
        .linkedFramework("IOKit")
    ]
),
```

Add `"CLibMTPBridge"` to `macmtp` executable dependencies.

- [ ] **Step 2: Create `libmtp_bridge.h`**

```c
#ifndef MACMTP_LIBMTP_BRIDGE_H
#define MACMTP_LIBMTP_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mtp_bridge_handle mtp_bridge_handle_t;

mtp_bridge_handle_t *mtp_bridge_create(void);
void mtp_bridge_destroy(mtp_bridge_handle_t *handle);
const char *mtp_bridge_last_error(mtp_bridge_handle_t *handle);
void mtp_bridge_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif
```

- [ ] **Step 3: Create `module.modulemap`**

```text
module CLibMTPBridge {
    header "include/libmtp_bridge.h"
    export *
}
```

- [ ] **Step 4: Create minimal `libmtp_bridge.c`**

```c
#include "libmtp_bridge.h"

#include <stdlib.h>
#include <string.h>
#include <libmtp.h>

struct mtp_bridge_handle {
    LIBMTP_mtpdevice_t *device;
    char last_error[1024];
};

static void mtp_bridge_set_error(mtp_bridge_handle_t *handle, const char *message) {
    if (handle == NULL) {
        return;
    }
    if (message == NULL) {
        handle->last_error[0] = '\0';
        return;
    }
    snprintf(handle->last_error, sizeof(handle->last_error), "%s", message);
}

mtp_bridge_handle_t *mtp_bridge_create(void) {
    LIBMTP_Init();
    mtp_bridge_handle_t *handle = calloc(1, sizeof(mtp_bridge_handle_t));
    if (handle == NULL) {
        return NULL;
    }
    handle->device = NULL;
    handle->last_error[0] = '\0';
    return handle;
}

void mtp_bridge_destroy(mtp_bridge_handle_t *handle) {
    if (handle == NULL) {
        return;
    }
    if (handle->device != NULL) {
        LIBMTP_Release_Device(handle->device);
        handle->device = NULL;
    }
    free(handle);
}

const char *mtp_bridge_last_error(mtp_bridge_handle_t *handle) {
    if (handle == NULL) {
        return "libmtp bridge handle is null";
    }
    return handle->last_error;
}

void mtp_bridge_free_string(char *value) {
    free(value);
}
```

- [ ] **Step 5: Build**

Run:

```bash
MACMTP_LIBMTP_ROOT="$PWD/../libmtp-1.1.23" swift build
```

Expected: build passes and imports C target.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/CLibMTPBridge
git commit -m "新增 libmtp C 桥接骨架"
```

---

### Task 5: C bridge 实现连接、设备信息和存储列表

**Files:**
- Modify: `Sources/CLibMTPBridge/include/libmtp_bridge.h`
- Modify: `Sources/CLibMTPBridge/libmtp_bridge.c`

**Interfaces:**
- Produces:
  - `int mtp_bridge_connect(mtp_bridge_handle_t *handle)`
  - `void mtp_bridge_disconnect(mtp_bridge_handle_t *handle)`
  - `char *mtp_bridge_device_info_json(mtp_bridge_handle_t *handle)`
  - `char *mtp_bridge_storages_json(mtp_bridge_handle_t *handle)`

- [ ] **Step 1: Extend header**

Add:

```c
int mtp_bridge_connect(mtp_bridge_handle_t *handle);
void mtp_bridge_disconnect(mtp_bridge_handle_t *handle);
char *mtp_bridge_device_info_json(mtp_bridge_handle_t *handle);
char *mtp_bridge_storages_json(mtp_bridge_handle_t *handle);
```

- [ ] **Step 2: Implement JSON escaping helper**

Add to `libmtp_bridge.c`:

```c
static char *mtp_bridge_strdup_or_empty(const char *value) {
    return strdup(value == NULL ? "" : value);
}

static char *mtp_bridge_json_escape(const char *value) {
    const char *src = value == NULL ? "" : value;
    size_t extra = 0;
    for (const char *p = src; *p; p++) {
        if (*p == '"' || *p == '\\') {
            extra++;
        }
    }
    size_t len = strlen(src);
    char *out = malloc(len + extra + 1);
    if (out == NULL) {
        return NULL;
    }
    char *w = out;
    for (const char *p = src; *p; p++) {
        if (*p == '"' || *p == '\\') {
            *w++ = '\\';
        }
        *w++ = *p;
    }
    *w = '\0';
    return out;
}

static char *mtp_bridge_format_alloc(const char *format, ...) {
    va_list args;
    va_start(args, format);
    va_list copy;
    va_copy(copy, args);
    int needed = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (needed < 0) {
        va_end(args);
        return NULL;
    }
    char *buffer = malloc((size_t)needed + 1);
    if (buffer == NULL) {
        va_end(args);
        return NULL;
    }
    vsnprintf(buffer, (size_t)needed + 1, format, args);
    va_end(args);
    return buffer;
}
```

Also add includes:

```c
#include <stdarg.h>
#include <stdio.h>
```

- [ ] **Step 3: Implement connect and disconnect**

```c
int mtp_bridge_connect(mtp_bridge_handle_t *handle) {
    if (handle == NULL) {
        return -1;
    }
    if (handle->device != NULL) {
        return 0;
    }

    LIBMTP_raw_device_t *rawdevices = NULL;
    int numrawdevices = 0;
    LIBMTP_error_number_t err = LIBMTP_Detect_Raw_Devices(&rawdevices, &numrawdevices);
    if (err == LIBMTP_ERROR_NO_DEVICE_ATTACHED || numrawdevices == 0) {
        mtp_bridge_set_error(handle, "No MTP device attached");
        return -1;
    }
    if (err != LIBMTP_ERROR_NONE) {
        mtp_bridge_set_error(handle, "Failed to detect MTP devices");
        if (rawdevices != NULL) {
            LIBMTP_FreeMemory(rawdevices);
        }
        return -1;
    }

    handle->device = LIBMTP_Open_Raw_Device_Uncached(&rawdevices[0]);
    LIBMTP_FreeMemory(rawdevices);

    if (handle->device == NULL) {
        mtp_bridge_set_error(handle, "Failed to open MTP device");
        return -1;
    }
    mtp_bridge_set_error(handle, "");
    return 0;
}

void mtp_bridge_disconnect(mtp_bridge_handle_t *handle) {
    if (handle == NULL || handle->device == NULL) {
        return;
    }
    LIBMTP_Release_Device(handle->device);
    handle->device = NULL;
    mtp_bridge_set_error(handle, "");
}
```

- [ ] **Step 4: Implement device JSON**

```c
char *mtp_bridge_device_info_json(mtp_bridge_handle_t *handle) {
    if (handle == NULL || handle->device == NULL) {
        mtp_bridge_set_error(handle, "Device is not connected");
        return NULL;
    }

    char *manufacturer_raw = LIBMTP_Get_Manufacturername(handle->device);
    char *model_raw = LIBMTP_Get_Modelname(handle->device);
    char *serial_raw = LIBMTP_Get_Serialnumber(handle->device);
    char *version_raw = LIBMTP_Get_Deviceversion(handle->device);

    char *manufacturer = mtp_bridge_json_escape(manufacturer_raw);
    char *model = mtp_bridge_json_escape(model_raw);
    char *serial = mtp_bridge_json_escape(serial_raw);
    char *version = mtp_bridge_json_escape(version_raw);

    char *json = mtp_bridge_format_alloc(
        "{\"error\":null,\"data\":{\"mtpDeviceInfo\":{\"Manufacturer\":\"%s\",\"Model\":\"%s\",\"DeviceVersion\":\"%s\",\"SerialNumber\":\"%s\",\"StandardVersion\":null,\"MTPVendorExtensionID\":null,\"MTPVersion\":null,\"MTPExtension\":null,\"FunctionalMode\":null},\"usbDeviceInfo\":null}}",
        manufacturer ? manufacturer : "",
        model ? model : "",
        version ? version : "",
        serial ? serial : ""
    );

    LIBMTP_FreeMemory(manufacturer_raw);
    LIBMTP_FreeMemory(model_raw);
    LIBMTP_FreeMemory(serial_raw);
    LIBMTP_FreeMemory(version_raw);
    free(manufacturer);
    free(model);
    free(serial);
    free(version);

    return json;
}
```

- [ ] **Step 5: Implement storages JSON**

```c
char *mtp_bridge_storages_json(mtp_bridge_handle_t *handle) {
    if (handle == NULL || handle->device == NULL) {
        mtp_bridge_set_error(handle, "Device is not connected");
        return NULL;
    }
    if (LIBMTP_Get_Storage(handle->device, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0) {
        mtp_bridge_set_error(handle, "Failed to read MTP storage list");
        LIBMTP_Clear_Errorstack(handle->device);
        return NULL;
    }

    char *json = strdup("{\"error\":null,\"data\":[");
    size_t json_len = strlen(json);
    int first = 1;
    for (LIBMTP_devicestorage_t *storage = handle->device->storage; storage != NULL; storage = storage->next) {
        char *description = mtp_bridge_json_escape(storage->StorageDescription);
        char *volume = mtp_bridge_json_escape(storage->VolumeLabel);
        char *entry = mtp_bridge_format_alloc(
            "%s{\"Sid\":%u,\"Info\":{\"StorageType\":%u,\"FilesystemType\":%u,\"AccessCapability\":%u,\"MaxCapability\":%llu,\"FreeSpaceInBytes\":%llu,\"FreeSpaceInImages\":%u,\"StorageDescription\":\"%s\",\"VolumeLabel\":\"%s\"}}",
            first ? "" : ",",
            storage->id,
            storage->StorageType,
            storage->FilesystemType,
            storage->AccessCapability,
            (unsigned long long)storage->MaxCapacity,
            (unsigned long long)storage->FreeSpaceInBytes,
            storage->FreeSpaceInImages,
            description ? description : "",
            volume ? volume : ""
        );
        first = 0;
        size_t entry_len = strlen(entry);
        char *next = realloc(json, json_len + entry_len + 3);
        if (next == NULL) {
            free(json);
            free(entry);
            free(description);
            free(volume);
            return NULL;
        }
        json = next;
        memcpy(json + json_len, entry, entry_len + 1);
        json_len += entry_len;
        free(entry);
        free(description);
        free(volume);
    }

    char *next = realloc(json, json_len + 3);
    if (next == NULL) {
        free(json);
        return NULL;
    }
    json = next;
    memcpy(json + json_len, "]}", 3);
    return json;
}
```

- [ ] **Step 6: Build**

Run:

```bash
MACMTP_LIBMTP_ROOT="$PWD/../libmtp-1.1.23" swift build
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/CLibMTPBridge/include/libmtp_bridge.h Sources/CLibMTPBridge/libmtp_bridge.c
git commit -m "实现 libmtp 连接和存储查询"
```

---

### Task 6: 实现 Swift LibMTPBridge 初始化和存储读取

**Files:**
- Create: `Sources/macmtp/MTP/LibMTPBridge.swift`
- Modify: `Sources/macmtp/MTP/MTPBridgeFactory.swift`
- Create: `Tests/macmtpTests/LibMTPBridgeDecodeTests.swift`

**Interfaces:**
- Consumes: C API from Task 5
- Produces: `public actor LibMTPBridge: MTPBridgeProtocol`

- [ ] **Step 1: Create decode test for bridge helper**

Create `Tests/macmtpTests/LibMTPBridgeDecodeTests.swift`:

```swift
import XCTest
@testable import macmtp

final class LibMTPBridgeDecodeTests: XCTestCase {
    func testDecodeDeviceInfoJSON() throws {
        let json = #"{"error":null,"data":{"mtpDeviceInfo":{"Manufacturer":"iFlytek","Model":"iFlytek AiNote Air2","DeviceVersion":"1.0","SerialNumber":"123","StandardVersion":null,"MTPVendorExtensionID":null,"MTPVersion":null,"MTPExtension":null,"FunctionalMode":null},"usbDeviceInfo":null}}"#
        let data: GoDeviceInfoResult = try LibMTPBridge.decode(json)
        XCTAssertEqual(data.data?.mtpDeviceInfo?.Model, "iFlytek AiNote Air2")
    }
}
```

- [ ] **Step 2: Create `LibMTPBridge.swift`**

```swift
import Foundation
import CLibMTPBridge

public actor LibMTPBridge: MTPBridgeProtocol {
    public static let shared = LibMTPBridge()

    private let handle: OpaquePointer?
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "com.macmtp.libmtp", qos: .userInitiated)

    private init() {
        self.handle = mtp_bridge_create()
    }

    deinit {
        if let handle {
            mtp_bridge_destroy(handle)
        }
    }

    internal static func decode<T: Decodable>(_ json: String) throws -> T {
        let decoder = JSONDecoder()
        guard let data = json.data(using: .utf8) else {
            throw KalamError.invalidResponse
        }
        return try decoder.decode(T.self, from: data)
    }

    private func lastError() -> String {
        guard let handle, let ptr = mtp_bridge_last_error(handle) else {
            return "libmtp bridge is not initialized"
        }
        let message = String(cString: ptr)
        return message.isEmpty ? "Unknown libmtp error" : message
    }

    private func takeString(_ ptr: UnsafeMutablePointer<CChar>?) throws -> String {
        guard let ptr else {
            throw KalamError.operationFailed(lastError())
        }
        let value = String(cString: ptr)
        mtp_bridge_free_string(ptr)
        return value
    }

    public func initialize() async throws -> GoDeviceInfoData {
        guard let handle else {
            throw KalamError.operationFailed("libmtp bridge is not initialized")
        }
        if mtp_bridge_connect(handle) != 0 {
            throw KalamError.deviceNotConnected
        }
        let json = try takeString(mtp_bridge_device_info_json(handle))
        let result: GoDeviceInfoResult = try Self.decode(json)
        guard let data = result.data else {
            throw KalamError.operationFailed(result.error ?? "Failed to initialize libmtp device")
        }
        return data
    }

    public func fetchStorages() async throws -> [GoStorageData] {
        guard let handle else {
            throw KalamError.operationFailed("libmtp bridge is not initialized")
        }
        let json = try takeString(mtp_bridge_storages_json(handle))
        let result: GoStoragesResult = try Self.decode(json)
        guard let data = result.data else {
            throw KalamError.operationFailed(result.error ?? "Failed to fetch libmtp storages")
        }
        return data
    }

    public func listDirectory(storageId: UInt32, path: String, recursive: Bool = false) async throws -> [GoFileInfo] {
        throw KalamError.operationFailed("LibMTP listDirectory is not implemented")
    }

    public func makeDirectory(storageId: UInt32, path: String) async throws {
        throw KalamError.operationFailed("LibMTP makeDirectory is not implemented")
    }

    public func deleteFiles(storageId: UInt32, paths: [String]) async throws {
        throw KalamError.operationFailed("LibMTP deleteFiles is not implemented")
    }

    public func renameFile(storageId: UInt32, path: String, newName: String) async throws {
        throw KalamError.operationFailed("LibMTP renameFile is not implemented")
    }

    public func checkFilesExist(storageId: UInt32, paths: [String]) async throws -> [Bool] {
        throw KalamError.operationFailed("LibMTP checkFilesExist is not implemented")
    }

    public func uploadFiles(
        storageId: UInt32,
        sources: [String],
        destination: String,
        onPreprocess: @escaping @Sendable (GoTransferPreprocessData) -> Void,
        onProgress: @escaping @Sendable (GoTransferProgressInfo) -> Void
    ) async throws {
        throw KalamError.operationFailed("LibMTP uploadFiles is not implemented")
    }

    public func downloadFiles(
        storageId: UInt32,
        sources: [String],
        destination: String,
        onPreprocess: @escaping @Sendable (GoTransferPreprocessData) -> Void,
        onProgress: @escaping @Sendable (GoTransferProgressInfo) -> Void
    ) async throws {
        throw KalamError.operationFailed("LibMTP downloadFiles is not implemented")
    }

    public func walk(storageId: UInt32, path: String, recursive: Bool, skipHidden: Bool) async throws -> [GoFileInfo] {
        try await listDirectory(storageId: storageId, path: path, recursive: recursive)
    }

    public func dispose() async throws {
        guard let handle else { return }
        mtp_bridge_disconnect(handle)
    }
}
```

- [ ] **Step 3: Update factory**

Change `.libmtp` branch:

```swift
case .libmtp:
    return LibMTPBridge.shared
```

- [ ] **Step 4: Run tests**

Run:

```bash
MACMTP_LIBMTP_ROOT="$PWD/../libmtp-1.1.23" swift test --filter LibMTPBridgeDecodeTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/macmtp/MTP/LibMTPBridge.swift Sources/macmtp/MTP/MTPBridgeFactory.swift Tests/macmtpTests/LibMTPBridgeDecodeTests.swift
git commit -m "新增 LibMTPBridge 初始化骨架"
```

---

### Task 7: 实现目录列表和路径到 object id 解析

**Files:**
- Modify: `Sources/CLibMTPBridge/include/libmtp_bridge.h`
- Modify: `Sources/CLibMTPBridge/libmtp_bridge.c`
- Modify: `Sources/macmtp/MTP/LibMTPBridge.swift`

**Interfaces:**
- Produces:
  - `char *mtp_bridge_list_directory_json(mtp_bridge_handle_t *handle, uint32_t storage_id, const char *path, int recursive)`
  - `int mtp_bridge_resolve_object_id(mtp_bridge_handle_t *handle, uint32_t storage_id, const char *path, uint32_t *object_id, int *is_folder)`

- [ ] **Step 1: Extend header**

```c
char *mtp_bridge_list_directory_json(mtp_bridge_handle_t *handle, uint32_t storage_id, const char *path, int recursive);
int mtp_bridge_resolve_object_id(mtp_bridge_handle_t *handle, uint32_t storage_id, const char *path, uint32_t *object_id, int *is_folder);
```

- [ ] **Step 2: Implement path lookup algorithm**

Add C helper functions:

```c
static uint32_t mtp_bridge_root_parent_for_path(const char *path) {
    return (path == NULL || strcmp(path, "/") == 0 || strlen(path) == 0)
        ? LIBMTP_FILES_AND_FOLDERS_ROOT
        : 0;
}

static int mtp_bridge_split_path(const char *path, char ***parts_out, size_t *count_out) {
    *parts_out = NULL;
    *count_out = 0;
    if (path == NULL || strcmp(path, "/") == 0 || strlen(path) == 0) {
        return 0;
    }
    char *copy = strdup(path);
    if (copy == NULL) {
        return -1;
    }
    size_t capacity = 8;
    char **parts = calloc(capacity, sizeof(char *));
    if (parts == NULL) {
        free(copy);
        return -1;
    }
    char *save = NULL;
    char *token = strtok_r(copy, "/", &save);
    while (token != NULL) {
        if (*count_out == capacity) {
            capacity *= 2;
            char **next = realloc(parts, capacity * sizeof(char *));
            if (next == NULL) {
                free(copy);
                free(parts);
                return -1;
            }
            parts = next;
        }
        parts[*count_out] = strdup(token);
        (*count_out)++;
        token = strtok_r(NULL, "/", &save);
    }
    free(copy);
    *parts_out = parts;
    return 0;
}

static void mtp_bridge_free_parts(char **parts, size_t count) {
    if (parts == NULL) {
        return;
    }
    for (size_t i = 0; i < count; i++) {
        free(parts[i]);
    }
    free(parts);
}
```

Implement `mtp_bridge_resolve_object_id` by walking each path segment with `LIBMTP_Get_Files_And_Folders(handle->device, storage_id, parent_id)`, matching `filename`, then using `item_id` as the next `parent_id`.

- [ ] **Step 3: Implement directory JSON**

`mtp_bridge_list_directory_json` must:

1. Resolve `path` to `parent_id`; `/` maps to `LIBMTP_FILES_AND_FOLDERS_ROOT`.
2. Call `LIBMTP_Get_Files_And_Folders(device, storage_id, parent_id)`.
3. Return JSON compatible with `GoWalkResult`.
4. Use `filetype == LIBMTP_FILETYPE_FOLDER` to set `isFolder`.
5. Emit `parentPath` using the requested path and `path` using requested path + filename.
6. For recursive mode, recursively append children for folders.

Expected JSON entry shape:

```json
{
  "size": 123,
  "isFolder": false,
  "dateAdded": "2026-07-14T00:00:00.000Z",
  "name": "demo.txt",
  "path": "/Documents/demo.txt",
  "parentPath": "/Documents",
  "extension": "txt",
  "parentId": 4294967295,
  "objectId": 42
}
```

- [ ] **Step 4: Wire Swift `listDirectory`**

Replace placeholder in `LibMTPBridge.swift`:

```swift
public func listDirectory(storageId: UInt32, path: String, recursive: Bool = false) async throws -> [GoFileInfo] {
    guard let handle else {
        throw KalamError.operationFailed("libmtp bridge is not initialized")
    }
    let normalized = MTPPathResolver.normalize(path)
    let json = try normalized.withCString { cPath in
        try takeString(mtp_bridge_list_directory_json(handle, storageId, cPath, recursive ? 1 : 0))
    }
    let result: GoWalkResult = try Self.decode(json)
    guard let data = result.data else {
        throw KalamError.operationFailed(result.error ?? "Failed to list libmtp directory")
    }
    return data
}
```

- [ ] **Step 5: Manual device verification**

Run app with libmtp selected:

```bash
MACMTP_LIBMTP_ROOT="$PWD/../libmtp-1.1.23" swift run macmtp
```

Expected:
- App connects to the device.
- Sidebar shows storage.
- Root directory lists files and folders.
- Navigating into one folder lists children.

- [ ] **Step 6: Commit**

```bash
git add Sources/CLibMTPBridge/include/libmtp_bridge.h Sources/CLibMTPBridge/libmtp_bridge.c Sources/macmtp/MTP/LibMTPBridge.swift
git commit -m "实现 libmtp 目录浏览"
```

---

### Task 8: 实现创建、删除、重命名、存在性检查

**Files:**
- Modify: `Sources/CLibMTPBridge/include/libmtp_bridge.h`
- Modify: `Sources/CLibMTPBridge/libmtp_bridge.c`
- Modify: `Sources/macmtp/MTP/LibMTPBridge.swift`

**Interfaces:**
- Produces:
  - `int mtp_bridge_create_folder(...)`
  - `int mtp_bridge_delete_path(...)`
  - `int mtp_bridge_rename_path(...)`
  - `char *mtp_bridge_file_exists_json(...)`

- [ ] **Step 1: Extend header**

```c
int mtp_bridge_create_folder(mtp_bridge_handle_t *handle, uint32_t storage_id, const char *path);
int mtp_bridge_delete_path(mtp_bridge_handle_t *handle, uint32_t storage_id, const char *path);
int mtp_bridge_rename_path(mtp_bridge_handle_t *handle, uint32_t storage_id, const char *path, const char *new_name);
char *mtp_bridge_file_exists_json(mtp_bridge_handle_t *handle, uint32_t storage_id, const char **paths, int count);
```

- [ ] **Step 2: Implement C operations**

Rules:
- Create folder: resolve parent path, pass `name`, `parent_id`, `storage_id` to `LIBMTP_Create_Folder`.
- Delete: resolve path to object id, call `LIBMTP_Delete_Object`.
- Rename: resolve path to object id, fetch metadata with `LIBMTP_Get_Filemetadata`, call `LIBMTP_Set_Object_Filename`.
- Exists: for each path, resolve path; return `true` if found, `false` if not found.

Expected exists JSON:

```json
{
  "error": null,
  "data": [
    { "fullpath": "/Documents/demo.txt", "exists": true },
    { "fullpath": "/Documents/missing.txt", "exists": false }
  ]
}
```

- [ ] **Step 3: Wire Swift operations**

Replace placeholders in `LibMTPBridge.swift`:

```swift
public func makeDirectory(storageId: UInt32, path: String) async throws {
    guard let handle else { throw KalamError.operationFailed("libmtp bridge is not initialized") }
    let normalized = MTPPathResolver.normalize(path)
    let result = normalized.withCString { mtp_bridge_create_folder(handle, storageId, $0) }
    if result != 0 { throw KalamError.operationFailed(lastError()) }
}

public func deleteFiles(storageId: UInt32, paths: [String]) async throws {
    guard let handle else { throw KalamError.operationFailed("libmtp bridge is not initialized") }
    for path in paths {
        let normalized = MTPPathResolver.normalize(path)
        let result = normalized.withCString { mtp_bridge_delete_path(handle, storageId, $0) }
        if result != 0 { throw KalamError.operationFailed(lastError()) }
    }
}

public func renameFile(storageId: UInt32, path: String, newName: String) async throws {
    guard let handle else { throw KalamError.operationFailed("libmtp bridge is not initialized") }
    let normalized = MTPPathResolver.normalize(path)
    let result = normalized.withCString { cPath in
        newName.withCString { cName in
            mtp_bridge_rename_path(handle, storageId, cPath, cName)
        }
    }
    if result != 0 { throw KalamError.operationFailed(lastError()) }
}
```

Implement `checkFilesExist` using `withUnsafeBufferPointer` over duplicated C strings; free all temporary C strings after the C call returns.

- [ ] **Step 4: Manual device verification**

In app with libmtp selected:
- Create folder `macmtp-libmtp-test`.
- Rename it to `macmtp-libmtp-test-renamed`.
- Delete it.
- Upload conflict scan should detect existing file after manually placing one in the target directory.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLibMTPBridge/include/libmtp_bridge.h Sources/CLibMTPBridge/libmtp_bridge.c Sources/macmtp/MTP/LibMTPBridge.swift
git commit -m "实现 libmtp 文件管理操作"
```

---

### Task 9: 实现下载、上传和进度模型转换

**Files:**
- Modify: `Sources/CLibMTPBridge/include/libmtp_bridge.h`
- Modify: `Sources/CLibMTPBridge/libmtp_bridge.c`
- Modify: `Sources/macmtp/MTP/LibMTPBridge.swift`
- Create: `Tests/macmtpTests/LibMTPProgressTests.swift`

**Interfaces:**
- Produces:
  - `typedef void (*mtp_bridge_progress_callback_t)(const char *full_path, const char *name, uint64_t sent, uint64_t total, void *context)`
  - `int mtp_bridge_download_file(...)`
  - `int mtp_bridge_upload_file(...)`
  - `LibMTPTransferProgressMapper.makeProgress(...) -> GoTransferProgressInfo`

- [ ] **Step 1: Add progress mapper test**

Create `Tests/macmtpTests/LibMTPProgressTests.swift`:

```swift
import XCTest
@testable import macmtp

final class LibMTPProgressTests: XCTestCase {
    func testProgressMapperBuildsExistingModel() {
        let info = LibMTPTransferProgressMapper.makeProgress(
            fullPath: "/Music/song.mp3",
            name: "song.mp3",
            sent: 50,
            total: 100,
            startedAt: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 2),
            totalFiles: 1,
            filesSent: 0
        )

        XCTAssertEqual(info.fullPath, "/Music/song.mp3")
        XCTAssertEqual(info.name, "song.mp3")
        XCTAssertEqual(info.activeFileSize.sent, 50)
        XCTAssertEqual(info.activeFileSize.total, 100)
        XCTAssertEqual(info.activeFileSize.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(info.status, "transferring")
    }
}
```

- [ ] **Step 2: Implement Swift mapper**

Add to `LibMTPBridge.swift`:

```swift
public enum LibMTPTransferProgressMapper {
    public static func makeProgress(
        fullPath: String,
        name: String,
        sent: UInt64,
        total: UInt64,
        startedAt: Date,
        now: Date = Date(),
        totalFiles: Int64,
        filesSent: Int64
    ) -> GoTransferProgressInfo {
        let elapsed = max(now.timeIntervalSince(startedAt), 0.001)
        let speedMB = Double(sent) / elapsed / 1024.0 / 1024.0
        let progress = total == 0 ? Float(0) : Float(Double(sent) / Double(total))
        let size = GoTransferSizeInfo(total: Int64(total), sent: Int64(sent), progress: progress)
        return GoTransferProgressInfo(
            fullPath: fullPath,
            name: name,
            elapsedTime: Int64(elapsed),
            speed: speedMB,
            totalFiles: totalFiles,
            totalDirectories: 0,
            filesSent: filesSent,
            filesSentProgress: totalFiles == 0 ? 0 : Float(Double(filesSent) / Double(totalFiles)),
            activeFileSize: size,
            bulkFileSize: size,
            status: "transferring"
        )
    }
}
```

- [ ] **Step 3: Extend C header**

```c
typedef void (*mtp_bridge_progress_callback_t)(const char *full_path, const char *name, uint64_t sent, uint64_t total, void *context);

int mtp_bridge_download_file(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    const char *source_path,
    const char *destination_path,
    mtp_bridge_progress_callback_t callback,
    void *context
);

int mtp_bridge_upload_file(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    const char *source_path,
    const char *destination_dir,
    mtp_bridge_progress_callback_t callback,
    void *context
);
```

- [ ] **Step 4: Implement C transfers**

Rules:
- Download resolves source path to object id and calls `LIBMTP_Get_File_To_File`.
- Upload resolves destination directory to parent id, creates `LIBMTP_file_t`, sets `filename`, `filesize`, `parent_id`, `storage_id`, `filetype = LIBMTP_FILETYPE_UNKNOWN`, then calls `LIBMTP_Send_File_From_File`.
- The libmtp progress callback returns `0` to continue.
- For each callback, invoke `mtp_bridge_progress_callback_t` with source path, basename, sent, total.

- [ ] **Step 5: Wire Swift transfer methods**

Implement `uploadFiles` and `downloadFiles` as loops over `sources`, calling preprocess before each file and mapping C progress into `GoTransferProgressInfo`.

Constraints:
- Directories are already expanded by `FileTransferService`; skip directory entries for download/upload if size is 0 and path has no file extension only when caller already created directories.
- On first failed file, throw `KalamError.transferFailed(lastError())`.
- Preserve existing chunk semantics in `FileTransferService`.

- [ ] **Step 6: Run tests**

Run:

```bash
MACMTP_LIBMTP_ROOT="$PWD/../libmtp-1.1.23" swift test --filter LibMTPProgressTests
```

Expected: PASS.

- [ ] **Step 7: Manual device verification**

With libmtp selected:
- Download a small file to local panel.
- Upload a small file to device.
- Upload and download a file larger than 4 GB if device storage permits.
- Confirm progress bar moves and completed files are marked complete.

- [ ] **Step 8: Commit**

```bash
git add Sources/CLibMTPBridge/include/libmtp_bridge.h Sources/CLibMTPBridge/libmtp_bridge.c Sources/macmtp/MTP/LibMTPBridge.swift Tests/macmtpTests/LibMTPProgressTests.swift
git commit -m "实现 libmtp 文件传输"
```

---

### Task 10: 偏好设置启用 LibMTP 选项

**Files:**
- Modify: `Sources/macmtp/Views/PreferencesView.swift`
- Modify: `Resources/en.lproj/Localizable.strings`
- Modify: `Resources/zh-Hans.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `UserDefaults` key `mtpEngine`
- Produces: UI option value `libmtp`

- [ ] **Step 1: Locate current engine picker**

Run:

```bash
rg -n "MTP Engine|Kalam|mtpEngine" Sources/macmtp/Views/PreferencesView.swift Resources
```

Expected: find existing preference row and localization keys.

- [ ] **Step 2: Add LibMTP option**

If current picker is a `Picker`, add:

```swift
Text(L10n.t("LibMTP (Experimental)")).tag("libmtp")
```

Keep existing Kalam option tagged as `"kalam"`.

- [ ] **Step 3: Add localizations**

In `Resources/en.lproj/Localizable.strings`:

```text
"LibMTP (Experimental)" = "LibMTP (Experimental)";
```

In `Resources/zh-Hans.lproj/Localizable.strings`:

```text
"LibMTP (Experimental)" = "LibMTP（实验性）";
```

- [ ] **Step 4: Build**

Run:

```bash
MACMTP_LIBMTP_ROOT="$PWD/../libmtp-1.1.23" swift build
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/macmtp/Views/PreferencesView.swift Resources/en.lproj/Localizable.strings Resources/zh-Hans.lproj/Localizable.strings
git commit -m "在偏好设置中加入 LibMTP 后端选项"
```

---

### Task 11: 构建脚本支持 libmtp 动态库打包

**Files:**
- Modify: `scripts/build.sh`
- Modify: `Package.swift`

**Interfaces:**
- Consumes:
  - `MACMTP_LIBMTP_ROOT`
  - `MACMTP_LIBMTP_LIB_DIR`
- Produces app bundle dylibs:
  - `macMTP.app/Contents/MacOS/libmtp.9.dylib`
  - `macMTP.app/Contents/MacOS/libgcrypt.20.dylib`
  - `macMTP.app/Contents/MacOS/libgpg-error.0.dylib`

- [ ] **Step 1: Add helper variables to `scripts/build.sh`**

Near existing `KALAM_DIR` definitions, add:

```bash
LIBMTP_ROOT="${MACMTP_LIBMTP_ROOT:-$PROJECT_ROOT/../libmtp-1.1.23}"
LIBMTP_LIB_DIR="${MACMTP_LIBMTP_LIB_DIR:-$LIBMTP_ROOT/src/.libs}"
```

- [ ] **Step 2: Pass libmtp env to Swift build**

In `build_swift_arch`, add these env vars to both release and debug `swift build` calls:

```bash
MACMTP_LIBMTP_ROOT="$LIBMTP_ROOT" \
MACMTP_LIBMTP_LIB_DIR="$LIBMTP_LIB_DIR" \
```

- [ ] **Step 3: Copy libmtp runtime dylibs into app bundle**

After libusb copy, add:

```bash
copy_runtime_dylib() {
    local source="$1"
    local dest_name="$2"
    if [[ ! -f "$source" ]]; then
        echo "ERROR: Runtime dylib not found: $source" >&2
        exit 1
    fi
    cp "$source" "$APP_BUNDLE/Contents/MacOS/$dest_name"
    chmod +w "$APP_BUNDLE/Contents/MacOS/$dest_name"
    install_name_tool -id "@executable_path/$dest_name" "$APP_BUNDLE/Contents/MacOS/$dest_name"
}

copy_runtime_dylib "$LIBMTP_LIB_DIR/libmtp.9.dylib" "libmtp.9.dylib"
copy_runtime_dylib "/opt/homebrew/opt/libgcrypt/lib/libgcrypt.20.dylib" "libgcrypt.20.dylib"
copy_runtime_dylib "/opt/homebrew/opt/libgpg-error/lib/libgpg-error.0.dylib" "libgpg-error.0.dylib"
```

- [ ] **Step 4: Rewrite binary dylib references**

Add calls:

```bash
install_name_tool -change "$LIBMTP_LIB_DIR/libmtp.9.dylib" "@executable_path/libmtp.9.dylib" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" || true
install_name_tool -change "/path/to/libmtp-1.1.23/local-install/lib/libmtp.9.dylib" "@executable_path/libmtp.9.dylib" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" || true
install_name_tool -change "/opt/homebrew/opt/libgcrypt/lib/libgcrypt.20.dylib" "@executable_path/libgcrypt.20.dylib" "$APP_BUNDLE/Contents/MacOS/libmtp.9.dylib" || true
install_name_tool -change "/opt/homebrew/opt/libgpg-error/lib/libgpg-error.0.dylib" "@executable_path/libgpg-error.0.dylib" "$APP_BUNDLE/Contents/MacOS/libmtp.9.dylib" || true
install_name_tool -change "/opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib" "@executable_path/libusb.dylib" "$APP_BUNDLE/Contents/MacOS/libmtp.9.dylib" || true
```

- [ ] **Step 5: Sign new dylibs**

Before deep signing app:

```bash
codesign -s - --force "$APP_BUNDLE/Contents/MacOS/libmtp.9.dylib"
codesign -s - --force "$APP_BUNDLE/Contents/MacOS/libgcrypt.20.dylib"
codesign -s - --force "$APP_BUNDLE/Contents/MacOS/libgpg-error.0.dylib"
```

- [ ] **Step 6: Verify**

Run:

```bash
MACMTP_LIBMTP_ROOT="$PWD/../libmtp-1.1.23" ./scripts/build.sh --release
otool -L macMTP.app/Contents/MacOS/macMTP | rg "libmtp|libusb|libgcrypt|libgpg-error"
otool -L macMTP.app/Contents/MacOS/libmtp.9.dylib | rg "libusb|libgcrypt|libgpg-error"
```

Expected: all bundled runtime references use `@executable_path`.

- [ ] **Step 7: Commit**

```bash
git add scripts/build.sh Package.swift
git commit -m "打包 libmtp 运行时依赖"
```

---

### Task 12: 真实设备回归和文档更新

**Files:**
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Create: `docs/libmtp-backend-verification.md`

**Interfaces:**
- Produces verification report with exact device, date, commands, results.

- [ ] **Step 1: Create verification checklist**

Create `docs/libmtp-backend-verification.md`:

```markdown
# LibMTP Backend Verification

Date: 2026-07-14
Device: iFlytek AiNote Air2
Host: macOS arm64
Backend: LibMTP

## Commands

```bash
MACMTP_LIBMTP_ROOT="$PWD/../libmtp-1.1.23" ./scripts/build.sh --release
open macMTP.app
```

## Checklist

- [ ] Detects connected device.
- [ ] Displays manufacturer and model.
- [ ] Lists internal storage.
- [ ] Lists root directory.
- [ ] Navigates into a folder.
- [ ] Creates a folder.
- [ ] Renames the folder.
- [ ] Deletes the folder.
- [ ] Downloads a small file.
- [ ] Uploads a small file.
- [ ] Detects upload conflict.
- [ ] Downloads a folder recursively.
- [ ] Uploads a folder recursively.
- [ ] Transfers a file larger than 4 GB.
- [ ] Fix MTP Connection still works when macOS camera services hold the interface.

## Results

Record exact pass/fail notes here after running the checklist.
```
```

- [ ] **Step 2: Update English README**

Add a short section under development notes:

```markdown
### Experimental LibMTP backend

macMTP can be built with an experimental `libmtp` backend. Keep `../libmtp-1.1.23` next to this repository, then build with:

```bash
MACMTP_LIBMTP_ROOT="$PWD/../libmtp-1.1.23" ./scripts/build.sh --release
```

The Kalam backend remains the default until the LibMTP backend passes the device regression checklist in `docs/libmtp-backend-verification.md`.
```

- [ ] **Step 3: Update Chinese README**

Add:

```markdown
### 实验性 LibMTP 后端

macMTP 可以构建实验性的 `libmtp` 后端。将 `../libmtp-1.1.23` 放在本仓库同级目录，然后执行：

```bash
MACMTP_LIBMTP_ROOT="$PWD/../libmtp-1.1.23" ./scripts/build.sh --release
```

在 `docs/libmtp-backend-verification.md` 的设备回归清单通过之前，Kalam 后端仍然保持默认。
```

- [ ] **Step 4: Run final verification commands**

Run:

```bash
MACMTP_LIBMTP_ROOT="$PWD/../libmtp-1.1.23" swift test
MACMTP_LIBMTP_ROOT="$PWD/../libmtp-1.1.23" swift build
MACMTP_LIBMTP_ROOT="$PWD/../libmtp-1.1.23" ./scripts/build.sh --release
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add README.md README.zh-CN.md docs/libmtp-backend-verification.md
git commit -m "补充 LibMTP 后端验证文档"
```

---

## Acceptance Criteria

- `swift test` passes.
- `swift build` passes with `MACMTP_LIBMTP_ROOT="$PWD/../libmtp-1.1.23"`.
- `./scripts/build.sh --release` produces a signed app bundle.
- `otool -L macMTP.app/Contents/MacOS/macMTP` does not reference absolute libmtp, libusb, libgcrypt, or libgpg-error paths.
- Kalam remains selectable and functional.
- LibMTP backend can connect to `iFlytek AiNote Air2`.
- LibMTP backend supports browse, create folder, rename, delete, upload, download, conflict scan.
- Transfer progress updates during upload and download.
- Verification results are recorded in `docs/libmtp-backend-verification.md`.

## Known Implementation Risks

- libmtp exposes object ID semantics, while current app uses path semantics. The C bridge must resolve every path against current device contents and should avoid stale object IDs after create/delete/rename.
- Recursive transfer behavior currently depends on `FileTransferService.expandMTPPath`; directory listing must return accurate `isFolder`, `path`, `parentPath`, `objectId`, and `parentId`.
- Dynamic library packaging must rewrite both the main executable and `libmtp.9.dylib` dependency references.
- `LIBMTP_Set_Object_Filename` may behave differently across Android devices; verify rename for files and folders separately.
- Some devices may return zero or missing modification dates; Swift must tolerate invalid date strings.
- Cancellation is not fully specified in the existing `MTPBridgeProtocol`; initial libmtp backend can match Kalam behavior, then add explicit cancellation in a later feature.

## Self-Review

- Spec coverage: The plan covers protocol extraction, backend selection, C bridge, Swift actor, path resolution, directory browsing, file operations, transfer progress, packaging, documentation, and device verification.
- Placeholder scan: No task uses `TBD`, `TODO`, or unspecified “handle edge cases” instructions as deliverables.
- Type consistency: `MTPBridgeProtocol`, `LibMTPBridge`, `MTPBridgeFactory`, `MTPPathResolver`, and `LibMTPTransferProgressMapper` names are introduced before use in later tasks.

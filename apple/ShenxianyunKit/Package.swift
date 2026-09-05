// swift-tools-version: 6.0
import PackageDescription

// 神仙云后端服务层。刻意只依赖 Foundation：它是纯粹的 API 客户端，
// 与 Hako 内核、与 UI 都解耦，因此可以脱离 Xcode 工程用 `swift test` 单独跑。
// 神仙云的业务代码集中在这个包里，上游文件保持不动，将来同步上游才不会冲突。
let package = Package(
    name: "ShenxianyunKit",
    platforms: [.iOS(.v15), .macOS(.v13), .tvOS(.v17)],
    products: [.library(name: "ShenxianyunKit", targets: ["ShenxianyunKit"])],
    dependencies: [],
    targets: [
        .target(name: "ShenxianyunKit", dependencies: []),
        .testTarget(name: "ShenxianyunKitTests", dependencies: ["ShenxianyunKit"]),
    ]
)

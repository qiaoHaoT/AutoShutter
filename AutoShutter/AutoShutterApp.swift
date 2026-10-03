import SwiftUI

@main
struct AutoShutterApp: App {
    init() {
        // 最先安装崩溃捕获：AVFoundation 抛 NSException 时记录堆栈到 Documents/crash.log
        CrashReporter.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

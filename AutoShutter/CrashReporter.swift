import Foundation

/// 崩溃与运行时日志收集（无 Xcode 时用于定位闪退）。
///
/// - `install()` 在 App 启动时安装未捕获异常处理器：AVFoundation 抛出的
///   `NSInvalidArgumentException` 会被捕获，异常名/原因/堆栈写入 crash.log，
///   下次启动 `diagnosticReport()` 读取并弹出。
/// - `trace(_:)` 在拍照关键路径打点，同步落盘；崩溃后末尾几行能定位崩在哪步之后。
enum CrashReporter {

    private static let documents = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
    /// 未捕获 NSException 堆栈（崩溃后留存，下次启动读取）
    static let crashLogURL = documents.appendingPathComponent("crash.log")
    /// 拍照流程打点日志
    static let traceLogURL = documents.appendingPathComponent("trace.log")

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 安装未捕获异常处理器：崩溃时把异常名/原因/堆栈写入 crash.log
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let report = """
            ===== 未捕获异常 =====
            时间: \(Date())

            异常: \(exception.name.rawValue)
            原因: \(exception.reason ?? "(无)")

            堆栈:
            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            try? report.write(to: crashLogURL, atomically: true, encoding: .utf8)
        }
        // trace.log 超过 1MB 则清空，避免无限增长
        if let attrs = try? FileManager.default.attributesOfItem(atPath: traceLogURL.path),
           let size = attrs[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: traceLogURL)
        }
    }

    /// 记录一条打点日志（同步写入，崩溃前已落盘）
    static func trace(_ message: String, function: String = #function) {
        let line = "[\(timeFormatter.string(from: Date()))] \(function): \(message)\n"
        let data = line.data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: traceLogURL.path) {
            if let handle = try? FileHandle(forWritingTo: traceLogURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: traceLogURL)
        }
    }

    /// 综合诊断报告：崩溃堆栈 + 打点末尾。无任何记录时返回 nil。
    static func diagnosticReport() -> String? {
        let crash = (try? String(contentsOf: crashLogURL, encoding: .utf8)) ?? ""
        let trace = (try? String(contentsOf: traceLogURL, encoding: .utf8)) ?? ""
        if crash.isEmpty && trace.isEmpty { return nil }
        let traceTail = trace.split(separator: "\n").suffix(40).joined(separator: "\n")
        return """
        ===== 未捕获异常（若有）=====
        \(crash.isEmpty ? "(无——可能是 Swift precondition 崩溃或被系统终止)" : crash)

        ===== 拍照流程打点（最后 40 行）=====
        \(traceTail)
        """
    }

    /// 清空崩溃日志（用户已查看后调用）
    static func clearCrashReport() {
        try? FileManager.default.removeItem(at: crashLogURL)
    }
}

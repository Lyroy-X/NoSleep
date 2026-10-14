import Foundation
import Virtualization

// Public Apple metadata API. Build with com.apple.security.virtualization;
// an unsigned plain Swift REPL cannot connect to the installation XPC service.
guard CommandLine.arguments.count == 2 else { exit(64) }
VZMacOSRestoreImage.load(from: URL(fileURLWithPath: CommandLine.arguments[1])) { result in
    switch result {
    case .success(let image):
        let version = image.operatingSystemVersion
        var value: [String: Any] = ["major": version.majorVersion,
                                    "minor": version.minorVersion,
                                    "patch": version.patchVersion]
        if let config = image.mostFeaturefulSupportedConfiguration {
            value["supported"] = true
            value["cpuMinimum"] = config.minimumSupportedCPUCount
            value["memoryMinimumMiB"] = config.minimumSupportedMemorySize / 1048576
            value["hardwareSupported"] = config.hardwareModel.isSupported
        } else {
            value["supported"] = false
        }
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        exit(0)
    case .failure(let error):
        let value = error as NSError
        print("ERROR domain=\(value.domain) code=\(value.code) \(value.localizedDescription)")
        exit(1)
    }
}
RunLoop.main.run()

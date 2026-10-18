import AppKit

// Separated from the report itself so a test can compile `Diagnostics.report`
// on its own. Everything below reaches into a reader, and pulling one in
// pulls in all of them -- which is how the redaction test, the only part of
// this that can do harm if it is wrong, ended up unable to run at all.
extension Diagnostics {

    /// Everything the readers answer right now.
    ///
    /// The identifying fields on `Input` are deliberately not filled in here.
    /// They exist so a test can put something recognisable in them and prove
    /// it does not reach the text; leaving them empty in the live path means
    /// there is nothing to leak even if `report` is changed carelessly later.
    static func live() -> Input {
        var input = Input()
        input.appVersion = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        input.build = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        input.macOS = DeviceInfo.os.version
        input.modelIdentifier = DeviceInfo.model.identifier
        input.chip = DeviceInfo.cpu.name
        input.physicalCores = DeviceInfo.cpu.physicalCores
        input.perfLevels = CPUReadings.perfLevels.map { ($0.name, $0.logicalCores) }
        input.memoryBytes = DeviceInfo.memory
        input.gpuName = DeviceInfo.gpu

        let smc = SMCKit.shared
        input.smcAvailable = smc.isAvailable
        input.smcKeyCount = smc.isAvailable ? smc.allKeys().count : nil

        let sensors = SensorReadings.all()
        input.sensorCount = sensors.isEmpty ? nil : sensors.count
        let hid = sensors.filter { $0.id.hasPrefix("hid:") }.count
        input.hidSensorCount = hid == 0 ? nil : hid
        let fans = sensors.filter { $0.family == .fan }.count
        input.fanCount = fans == 0 ? nil : fans

        if let gpu = GPUStats.busiest() {
            input.gpuUtilization = gpu.utilization
            input.gpuRenderer = gpu.renderer
            input.gpuMemoryUsed = gpu.memoryUsed
        }

        let volumes = DiskReadings.volumes()
        input.volumeCount = volumes.isEmpty ? nil : volumes.count
        let devices = DiskReadings.counters().byDevice.count
        input.blockDeviceCount = devices == 0 ? nil : devices

        let network = NetworkInfo.current()
        input.hasPrimaryInterface = network.primaryInterface != nil
        input.isWiFi = network.wifiInterface != nil
            && network.primaryInterface == network.wifiInterface
        input.hasPublicAddressLookup = NetworkSettings.looksUpPublicIP
        input.menuBar = MonitorBar.shared.moduleReport
        return input
    }

    /// Puts the report on the pasteboard and says so.
    static func copyToPasteboard() {
        let text = report(live())
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

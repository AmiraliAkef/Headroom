import Foundation

/// DisplayLink Manager drives monitors on DisplayLink docks and adapters. Quitting
/// it blanks those screens, so prep only quits it while no DisplayLink device is
/// plugged in (it then just idles in the background).
public enum DisplayLink {
    public static let bundleId = "com.displaylink.DisplayLinkUserAgent"
    /// DisplayLink Corp's USB vendor id (0x17E9).
    static let vendorId = 0x17E9

    /// Pure part, tested: whether `ioreg -p IOUSB -l -w0` lists a DisplayLink device.
    static func deviceConnected(ioregOutput: String) -> Bool {
        ioregOutput.split(separator: "\n").contains { line in
            let t = line.replacingOccurrences(of: " ", with: "")
            return t.hasSuffix("\"idVendor\"=\(vendorId)")
        }
    }

    /// Whether a DisplayLink dock or adapter is plugged in now. If USB can't be read,
    /// assumes it is, so the monitor is never blanked by mistake.
    public static func isDeviceConnected() -> Bool {
        guard let r = Shell.run("/usr/sbin/ioreg", ["-p", "IOUSB", "-l", "-w0"], timeout: 10), r.status == 0
        else { return true }
        return deviceConnected(ioregOutput: r.stdout)
    }
}

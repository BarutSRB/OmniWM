import CoreGraphics

struct MonitorOrientationSettings: MonitorSettingsType {
    var id: String { monitorDisplayId.map(String.init) ?? monitorName }
    var monitorName: String
    var monitorDisplayId: CGDirectDisplayID? = nil
    var orientation: Monitor.Orientation?
}

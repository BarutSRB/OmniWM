struct MonitorOrientationSettings: MonitorSettingsType {
    var id: String { monitorName }
    let monitorName: String
    var orientation: Monitor.Orientation?
}

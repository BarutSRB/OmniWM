// SPDX-License-Identifier: GPL-2.0-only
import ApplicationServices
import Foundation

typealias SLPSMode = UInt32
let kCPSUserGenerated: SLPSMode = 0x200

@_silgen_name("_SLPSSetFrontProcessWithOptions")
func _SLPSSetFrontProcessWithOptions(
    _ psn: inout ProcessSerialNumber,
    _ wid: UInt32,
    _ mode: SLPSMode
) -> OSStatus

@_silgen_name("SLPSPostEventRecordTo")
func SLPSPostEventRecordTo(
    _ psn: inout ProcessSerialNumber,
    _ bytes: UnsafeMutablePointer<UInt8>
) -> OSStatus

@_silgen_name("GetProcessForPID")
func getProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowId: inout CGWindowID) -> AXError

func getWindowId(from windowRef: AXUIElement) -> CGWindowID? {
    var windowId: CGWindowID = 0
    let result = _AXUIElementGetWindow(windowRef, &windowId)
    return result == .success ? windowId : nil
}

func makeKeyWindow(psn: inout ProcessSerialNumber, windowId: UInt32) {
    var eventBytes = [UInt8](repeating: 0, count: 0xF8)
    eventBytes[0x04] = 0xF8
    eventBytes[0x08] = 0x01
    eventBytes[0x3A] = 0x10

    withUnsafeBytes(of: windowId) { ptr in
        eventBytes[0x3C] = ptr[0]
        eventBytes[0x3D] = ptr[1]
        eventBytes[0x3E] = ptr[2]
        eventBytes[0x3F] = ptr[3]
    }

    for i in 0x20 ..< 0x30 {
        eventBytes[i] = 0xFF
    }

    _ = SLPSPostEventRecordTo(&psn, &eventBytes)
    eventBytes[0x08] = 0x02
    _ = SLPSPostEventRecordTo(&psn, &eventBytes)
}

func focusWindow(pid: pid_t, windowId: UInt32, windowRef _: AXUIElement) {
    var psn = ProcessSerialNumber()
    guard getProcessForPID(pid, &psn) == noErr else { return }

    _ = _SLPSSetFrontProcessWithOptions(&psn, windowId, kCPSUserGenerated)
    makeKeyWindow(psn: &psn, windowId: windowId)
}

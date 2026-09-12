// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

public enum IPCFullscreenCommand: String, CaseIterable, Hashable, Sendable {
    case managed = "toggle-fullscreen"
    case native = "toggle-native-fullscreen"
}

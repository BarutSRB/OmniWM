// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import OmniWMIPC

extension ActionCatalog {
    static func appendScratchpadBindings(_ specs: inout [ActionSpec]) {
        for index in ScratchpadIndex.range {
            specs.append(
                action(
                    id: "toggleScratchpad.\(index)",
                    command: .scratchpad(.toggle(index)),
                    category: .layout,
                    binding: .unassigned,
                    keywords: ["scratchpad"]
                )
            )
            specs.append(
                action(
                    id: "assignFocusedWindowToScratchpad.\(index)",
                    command: .scratchpad(.assign(index)),
                    category: .layout,
                    binding: .unassigned,
                    keywords: ["scratchpad"]
                )
            )
        }
    }
}

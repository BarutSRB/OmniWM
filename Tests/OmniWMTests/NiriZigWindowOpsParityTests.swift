import Foundation
import QuartzCore
import Testing

@testable import OmniWM

private struct MutationLCG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1
        return state
    }

    mutating func nextBool(_ trueProbability: Double = 0.5) -> Bool {
        let value = Double(next() % 10_000) / 10_000.0
        return value < trueProbability
    }

    mutating func nextInt(_ range: ClosedRange<Int>) -> Int {
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % width)
    }
}

private func percentile(_ samples: [Double], _ p: Double) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.sorted()
    let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * p)))
    return sorted[idx]
}

private func proportionalSignature(_ value: ProportionalSize) -> (kind: Int, value: Double) {
    switch value {
    case let .proportion(v):
        return (0, Double(v))
    case let .fixed(v):
        return (1, Double(v))
    }
}

private func weightedSignature(_ value: WeightedSize) -> (kind: Int, value: Double) {
    switch value {
    case let .auto(weight: w):
        return (0, Double(w))
    case let .fixed(v):
        return (1, Double(v))
    }
}

private struct WindowSignature: Equatable {
    let pid: Int32
    let size: Double
    let heightKind: Int
    let heightValue: Double
}

private struct ColumnSignature: Equatable {
    let isTabbed: Bool
    let activeTileIdx: Int
    let widthKind: Int
    let widthValue: Double
    let isFullWidth: Bool
    let savedWidthKind: Int
    let savedWidthValue: Double
    let windows: [WindowSignature]
}

private struct LayoutSignature: Equatable {
    let columns: [ColumnSignature]
}

private func layoutSignature(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) -> LayoutSignature {
    let columns = engine.columns(in: workspaceId).map { column -> ColumnSignature in
        let width = proportionalSignature(column.width)
        let savedWidth = proportionalSignature(column.savedWidth ?? .proportion(-1))
        let windows = column.windowNodes.map { window in
            let height = weightedSignature(window.height)
            return WindowSignature(
                pid: window.handle.pid,
                size: Double(window.size),
                heightKind: height.kind,
                heightValue: height.value
            )
        }

        return ColumnSignature(
            isTabbed: column.isTabbed,
            activeTileIdx: column.activeTileIdx,
            widthKind: width.kind,
            widthValue: width.value,
            isFullWidth: column.isFullWidth,
            savedWidthKind: savedWidth.kind,
            savedWidthValue: savedWidth.value,
            windows: windows
        )
    }

    return LayoutSignature(columns: columns)
}

private func assertMutationOutcomeParity(
    zig: NiriStateZigKernel.MutationOutcome,
    reference: NiriStateZigKernel.MutationOutcome
) {
    #expect(zig.rc == reference.rc)
    #expect(zig.applied == reference.applied)
    #expect(zig.targetWindowIndex == reference.targetWindowIndex)
    #expect(zig.edits.count == reference.edits.count)
    guard zig.edits.count == reference.edits.count else { return }

    for idx in 0 ..< zig.edits.count {
        let lhs = zig.edits[idx]
        let rhs = reference.edits[idx]
        #expect(lhs.kind == rhs.kind)
        #expect(lhs.subjectIndex == rhs.subjectIndex)
        #expect(lhs.relatedIndex == rhs.relatedIndex)
        #expect(lhs.valueA == rhs.valueA)
        #expect(lhs.valueB == rhs.valueB)
    }
}

private func applyMutationOutcome(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    state: inout ViewportState,
    snapshot: NiriStateZigKernel.Snapshot,
    outcome: NiriStateZigKernel.MutationOutcome,
    workingFrame: CGRect,
    gaps: CGFloat
) -> Bool {
    guard outcome.rc == 0 else { return false }
    guard outcome.applied else { return false }

    let applyOutcome = NiriStateZigMutationApplier.apply(
        outcome: outcome,
        snapshot: snapshot,
        engine: engine
    )
    guard applyOutcome.applied else { return false }

    if let delegated = applyOutcome.delegatedMoveColumn {
        return engine.moveColumn(
            delegated.column,
            direction: delegated.direction,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    return true
}

private func assertMutationInvariants(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) {
    let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspaceId))
    let validation = NiriStateZigKernel.validate(snapshot: snapshot)
    #expect(validation.isValid)

    if let root = engine.root(for: workspaceId) {
        #expect(root.allWindows.count == snapshot.windowEntries.count)
        for column in root.columns {
            if column.windowNodes.isEmpty {
                #expect(column.activeTileIdx == 0)
            } else {
                #expect(column.activeTileIdx >= 0)
                #expect(column.activeTileIdx < column.windowNodes.count)
            }
        }
    }
}

private struct DualEngines {
    let zigEngine: NiriLayoutEngine
    let referenceEngine: NiriLayoutEngine
    let workspaceId: WorkspaceDescriptor.ID
    let workingFrame: CGRect
    let gaps: CGFloat
}

private func makeDualEngines(seed: UInt64) -> DualEngines {
    var rng = MutationLCG(seed: seed)
    let workspaceId = WorkspaceDescriptor.ID()
    let maxWindowsPerColumn = 8
    let infiniteLoop = rng.nextBool(0.5)

    let zigEngine = NiriLayoutEngine(maxWindowsPerColumn: maxWindowsPerColumn, infiniteLoop: infiniteLoop)
    let referenceEngine = NiriLayoutEngine(maxWindowsPerColumn: maxWindowsPerColumn, infiniteLoop: infiniteLoop)
    let zigRoot = NiriRoot(workspaceId: workspaceId)
    let refRoot = NiriRoot(workspaceId: workspaceId)
    zigEngine.roots[workspaceId] = zigRoot
    referenceEngine.roots[workspaceId] = refRoot

    let columnCount = rng.nextInt(2 ... 5)
    for columnIndex in 0 ..< columnCount {
        let zigColumn = NiriContainer()
        let refColumn = NiriContainer()
        let isTabbed = rng.nextBool(0.35)
        zigColumn.displayMode = isTabbed ? .tabbed : .normal
        refColumn.displayMode = isTabbed ? .tabbed : .normal

        let fullWidth = rng.nextBool(0.25)
        let widthValue = CGFloat(rng.nextInt(2 ... 8)) / 10.0
        let savedWidthValue = CGFloat(rng.nextInt(2 ... 8)) / 10.0
        zigColumn.width = .proportion(widthValue)
        refColumn.width = .proportion(widthValue)
        zigColumn.isFullWidth = fullWidth
        refColumn.isFullWidth = fullWidth
        if rng.nextBool(0.5) {
            zigColumn.savedWidth = .proportion(savedWidthValue)
            refColumn.savedWidth = .proportion(savedWidthValue)
        }

        zigRoot.appendChild(zigColumn)
        refRoot.appendChild(refColumn)

        let windowCount = rng.nextInt(1 ... 4)
        for row in 0 ..< windowCount {
            let pid = pid_t(70_000 + columnIndex * 100 + row)
            let zigHandle = makeTestHandle(pid: pid)
            let refHandle = makeTestHandle(pid: pid)
            let zigWindow = NiriWindow(handle: zigHandle)
            let refWindow = NiriWindow(handle: refHandle)

            let size = CGFloat(rng.nextInt(5 ... 20)) / 10.0
            zigWindow.size = size
            refWindow.size = size
            if rng.nextBool(0.3) {
                let fixedHeight = CGFloat(rng.nextInt(3 ... 12)) / 10.0
                zigWindow.height = .fixed(fixedHeight)
                refWindow.height = .fixed(fixedHeight)
            } else {
                let autoWeight = CGFloat(rng.nextInt(5 ... 20)) / 10.0
                zigWindow.height = .auto(weight: autoWeight)
                refWindow.height = .auto(weight: autoWeight)
            }

            zigColumn.appendChild(zigWindow)
            refColumn.appendChild(refWindow)
            zigEngine.handleToNode[zigHandle] = zigWindow
            referenceEngine.handleToNode[refHandle] = refWindow
        }

        let activeTile = rng.nextInt(0 ... max(0, windowCount - 1))
        zigColumn.setActiveTileIdx(activeTile)
        refColumn.setActiveTileIdx(activeTile)
    }

    return DualEngines(
        zigEngine: zigEngine,
        referenceEngine: referenceEngine,
        workspaceId: workspaceId,
        workingFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        gaps: 8
    )
}

private func appendMirroredWindow(
    pid: pid_t,
    zigColumn: NiriContainer,
    referenceColumn: NiriContainer,
    zigEngine: NiriLayoutEngine,
    referenceEngine: NiriLayoutEngine
) {
    let zigHandle = makeTestHandle(pid: pid)
    let referenceHandle = makeTestHandle(pid: pid)
    let zigWindow = NiriWindow(handle: zigHandle)
    let referenceWindow = NiriWindow(handle: referenceHandle)
    zigColumn.appendChild(zigWindow)
    referenceColumn.appendChild(referenceWindow)
    zigEngine.handleToNode[zigHandle] = zigWindow
    referenceEngine.handleToNode[referenceHandle] = referenceWindow
}

private func makePhase3SingleWindowColumnsScenario() -> DualEngines {
    let workspaceId = WorkspaceDescriptor.ID()
    let zigEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, infiniteLoop: false)
    let referenceEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, infiniteLoop: false)
    let zigRoot = NiriRoot(workspaceId: workspaceId)
    let refRoot = NiriRoot(workspaceId: workspaceId)
    zigEngine.roots[workspaceId] = zigRoot
    referenceEngine.roots[workspaceId] = refRoot

    let zigLeft = NiriContainer()
    let zigRight = NiriContainer()
    let refLeft = NiriContainer()
    let refRight = NiriContainer()
    zigRoot.appendChild(zigLeft)
    zigRoot.appendChild(zigRight)
    refRoot.appendChild(refLeft)
    refRoot.appendChild(refRight)

    appendMirroredWindow(
        pid: 81_001,
        zigColumn: zigLeft,
        referenceColumn: refLeft,
        zigEngine: zigEngine,
        referenceEngine: referenceEngine
    )
    appendMirroredWindow(
        pid: 81_002,
        zigColumn: zigRight,
        referenceColumn: refRight,
        zigEngine: zigEngine,
        referenceEngine: referenceEngine
    )
    zigLeft.setActiveTileIdx(0)
    zigRight.setActiveTileIdx(0)
    refLeft.setActiveTileIdx(0)
    refRight.setActiveTileIdx(0)

    return DualEngines(
        zigEngine: zigEngine,
        referenceEngine: referenceEngine,
        workspaceId: workspaceId,
        workingFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        gaps: 8
    )
}

private func makePhase3TabbedColumnsScenario() -> DualEngines {
    let workspaceId = WorkspaceDescriptor.ID()
    let zigEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, infiniteLoop: false)
    let referenceEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, infiniteLoop: false)
    let zigRoot = NiriRoot(workspaceId: workspaceId)
    let refRoot = NiriRoot(workspaceId: workspaceId)
    zigEngine.roots[workspaceId] = zigRoot
    referenceEngine.roots[workspaceId] = refRoot

    let zigLeft = NiriContainer()
    let zigRight = NiriContainer()
    let refLeft = NiriContainer()
    let refRight = NiriContainer()
    zigLeft.displayMode = .tabbed
    zigRight.displayMode = .tabbed
    refLeft.displayMode = .tabbed
    refRight.displayMode = .tabbed
    zigRoot.appendChild(zigLeft)
    zigRoot.appendChild(zigRight)
    refRoot.appendChild(refLeft)
    refRoot.appendChild(refRight)

    appendMirroredWindow(
        pid: 82_001,
        zigColumn: zigLeft,
        referenceColumn: refLeft,
        zigEngine: zigEngine,
        referenceEngine: referenceEngine
    )
    appendMirroredWindow(
        pid: 82_002,
        zigColumn: zigLeft,
        referenceColumn: refLeft,
        zigEngine: zigEngine,
        referenceEngine: referenceEngine
    )
    appendMirroredWindow(
        pid: 82_003,
        zigColumn: zigLeft,
        referenceColumn: refLeft,
        zigEngine: zigEngine,
        referenceEngine: referenceEngine
    )
    appendMirroredWindow(
        pid: 82_101,
        zigColumn: zigRight,
        referenceColumn: refRight,
        zigEngine: zigEngine,
        referenceEngine: referenceEngine
    )
    appendMirroredWindow(
        pid: 82_102,
        zigColumn: zigRight,
        referenceColumn: refRight,
        zigEngine: zigEngine,
        referenceEngine: referenceEngine
    )

    zigLeft.setActiveTileIdx(1)
    zigRight.setActiveTileIdx(1)
    refLeft.setActiveTileIdx(1)
    refRight.setActiveTileIdx(1)
    zigEngine.updateTabbedColumnVisibility(column: zigLeft)
    zigEngine.updateTabbedColumnVisibility(column: zigRight)
    referenceEngine.updateTabbedColumnVisibility(column: refLeft)
    referenceEngine.updateTabbedColumnVisibility(column: refRight)

    return DualEngines(
        zigEngine: zigEngine,
        referenceEngine: referenceEngine,
        workspaceId: workspaceId,
        workingFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        gaps: 8
    )
}

private func makePhase3WidthStateSwapScenario() -> DualEngines {
    let workspaceId = WorkspaceDescriptor.ID()
    let zigEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, infiniteLoop: false)
    let referenceEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, infiniteLoop: false)
    let zigRoot = NiriRoot(workspaceId: workspaceId)
    let refRoot = NiriRoot(workspaceId: workspaceId)
    zigEngine.roots[workspaceId] = zigRoot
    referenceEngine.roots[workspaceId] = refRoot

    let zigLeft = NiriContainer()
    let zigRight = NiriContainer()
    let refLeft = NiriContainer()
    let refRight = NiriContainer()
    zigRoot.appendChild(zigLeft)
    zigRoot.appendChild(zigRight)
    refRoot.appendChild(refLeft)
    refRoot.appendChild(refRight)

    appendMirroredWindow(
        pid: 83_001,
        zigColumn: zigLeft,
        referenceColumn: refLeft,
        zigEngine: zigEngine,
        referenceEngine: referenceEngine
    )
    appendMirroredWindow(
        pid: 83_002,
        zigColumn: zigLeft,
        referenceColumn: refLeft,
        zigEngine: zigEngine,
        referenceEngine: referenceEngine
    )
    appendMirroredWindow(
        pid: 83_101,
        zigColumn: zigRight,
        referenceColumn: refRight,
        zigEngine: zigEngine,
        referenceEngine: referenceEngine
    )
    zigLeft.setActiveTileIdx(0)
    zigRight.setActiveTileIdx(0)
    refLeft.setActiveTileIdx(0)
    refRight.setActiveTileIdx(0)

    zigLeft.width = .proportion(0.62)
    zigLeft.savedWidth = .proportion(0.41)
    zigLeft.isFullWidth = true
    zigRight.width = .proportion(0.33)
    zigRight.savedWidth = nil
    zigRight.isFullWidth = false

    refLeft.width = .proportion(0.62)
    refLeft.savedWidth = .proportion(0.41)
    refLeft.isFullWidth = true
    refRight.width = .proportion(0.33)
    refRight.savedWidth = nil
    refRight.isFullWidth = false

    return DualEngines(
        zigEngine: zigEngine,
        referenceEngine: referenceEngine,
        workspaceId: workspaceId,
        workingFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        gaps: 8
    )
}

private func windowIndex(
    in snapshot: NiriStateZigKernel.Snapshot,
    pid: Int32
) -> Int? {
    snapshot.windowEntries.firstIndex(where: { $0.window.handle.pid == pid })
}

private func tabbedHiddenSignature(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) -> [[Bool]] {
    engine.columns(in: workspaceId)
        .filter(\.isTabbed)
        .map { column in
            column.windowNodes.map(\.isHiddenInTabbedMode)
        }
}

private func assertTabbedVisibilityConsistency(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) {
    for column in engine.columns(in: workspaceId).filter(\.isTabbed) {
        for (idx, window) in column.windowNodes.enumerated() {
            #expect(window.isHiddenInTabbedMode == (idx != column.activeTileIdx))
        }
    }
}

@discardableResult
private func runMutationParityStep(
    dual: DualEngines,
    request: NiriStateZigKernel.MutationRequest,
    zigState: inout ViewportState,
    referenceState: inout ViewportState
) -> (zig: NiriStateZigKernel.MutationOutcome, reference: NiriStateZigKernel.MutationOutcome) {
    let zigSnapshot = NiriStateZigKernel.makeSnapshot(columns: dual.zigEngine.columns(in: dual.workspaceId))
    let referenceSnapshot = NiriStateZigKernel.makeSnapshot(columns: dual.referenceEngine.columns(in: dual.workspaceId))

    let zigOutcome = NiriStateZigKernel.resolveMutation(snapshot: zigSnapshot, request: request)
    let referenceOutcome = NiriReferenceWindowOps.resolve(snapshot: referenceSnapshot, request: request)
    assertMutationOutcomeParity(zig: zigOutcome, reference: referenceOutcome)

    let zigApplied = applyMutationOutcome(
        engine: dual.zigEngine,
        workspaceId: dual.workspaceId,
        state: &zigState,
        snapshot: zigSnapshot,
        outcome: zigOutcome,
        workingFrame: dual.workingFrame,
        gaps: dual.gaps
    )
    let referenceApplied = applyMutationOutcome(
        engine: dual.referenceEngine,
        workspaceId: dual.workspaceId,
        state: &referenceState,
        snapshot: referenceSnapshot,
        outcome: referenceOutcome,
        workingFrame: dual.workingFrame,
        gaps: dual.gaps
    )
    #expect(zigApplied == referenceApplied)

    assertMutationInvariants(engine: dual.zigEngine, workspaceId: dual.workspaceId)
    assertMutationInvariants(engine: dual.referenceEngine, workspaceId: dual.workspaceId)
    #expect(layoutSignature(engine: dual.zigEngine, workspaceId: dual.workspaceId) == layoutSignature(engine: dual.referenceEngine, workspaceId: dual.workspaceId))

    return (zig: zigOutcome, reference: referenceOutcome)
}

private func executeRuntimeMutation(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    request: NiriStateZigKernel.MutationRequest,
    snapshot: NiriStateZigKernel.Snapshot,
    state: inout ViewportState,
    workingFrame: CGRect,
    gaps: CGFloat
) -> Bool {
    guard snapshot.windowEntries.indices.contains(request.sourceWindowIndex) else {
        return false
    }

    let sourceWindow = snapshot.windowEntries[request.sourceWindowIndex].window

    switch request.op {
    case .moveWindowVertical, .moveWindowHorizontal:
        guard let direction = request.direction else { return false }
        return engine.moveWindow(
            sourceWindow,
            direction: direction,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    case .swapWindowVertical, .swapWindowHorizontal:
        guard let direction = request.direction else { return false }
        return engine.swapWindow(
            sourceWindow,
            direction: direction,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    case .swapWindowsByMove, .insertWindowByMove:
        guard snapshot.windowEntries.count > 1 else { return false }
        var targetWindowIndex = request.targetWindowIndex
        if targetWindowIndex == request.sourceWindowIndex {
            targetWindowIndex = request.targetWindowIndex == 0 ? 1 : 0
        }
        guard snapshot.windowEntries.indices.contains(targetWindowIndex) else {
            return false
        }
        let targetWindow = snapshot.windowEntries[targetWindowIndex].window

        if request.op == .swapWindowsByMove {
            return engine.swapWindowsByMove(
                sourceWindowId: sourceWindow.id,
                targetWindowId: targetWindow.id,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }

        return engine.insertWindowByMove(
            sourceWindowId: sourceWindow.id,
            targetWindowId: targetWindow.id,
            position: request.insertPosition ?? .after,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }
}

private func makeRandomMutationRequest(
    snapshot: NiriStateZigKernel.Snapshot,
    maxWindowsPerColumn: Int,
    infiniteLoop: Bool,
    rng: inout MutationLCG
) -> NiriStateZigKernel.MutationRequest {
    let sourceWindowIndex = rng.nextInt(0 ... snapshot.windowEntries.count - 1)
    let targetWindowIndex = rng.nextInt(0 ... snapshot.windowEntries.count - 1)
    let opChoice = rng.nextInt(0 ... 5)

    switch opChoice {
    case 0:
        return .init(
            op: .moveWindowVertical,
            sourceWindowIndex: sourceWindowIndex,
            direction: rng.nextBool() ? .up : .down,
            infiniteLoop: infiniteLoop,
            maxWindowsPerColumn: maxWindowsPerColumn
        )
    case 1:
        return .init(
            op: .swapWindowVertical,
            sourceWindowIndex: sourceWindowIndex,
            direction: rng.nextBool() ? .up : .down,
            infiniteLoop: infiniteLoop,
            maxWindowsPerColumn: maxWindowsPerColumn
        )
    case 2:
        return .init(
            op: .moveWindowHorizontal,
            sourceWindowIndex: sourceWindowIndex,
            direction: rng.nextBool() ? .left : .right,
            infiniteLoop: infiniteLoop,
            maxWindowsPerColumn: maxWindowsPerColumn
        )
    case 3:
        return .init(
            op: .swapWindowHorizontal,
            sourceWindowIndex: sourceWindowIndex,
            direction: rng.nextBool() ? .left : .right,
            infiniteLoop: infiniteLoop,
            maxWindowsPerColumn: maxWindowsPerColumn
        )
    case 4:
        return .init(
            op: .swapWindowsByMove,
            sourceWindowIndex: sourceWindowIndex,
            targetWindowIndex: targetWindowIndex,
            infiniteLoop: infiniteLoop,
            maxWindowsPerColumn: maxWindowsPerColumn
        )
    default:
        return .init(
            op: .insertWindowByMove,
            sourceWindowIndex: sourceWindowIndex,
            targetWindowIndex: targetWindowIndex,
            infiniteLoop: infiniteLoop,
            insertPosition: rng.nextBool() ? .before : .after,
            maxWindowsPerColumn: maxWindowsPerColumn
        )
    }
}

@Suite(.serialized) struct NiriZigWindowOpsParityTests {
    @Test func phase3ScenarioParitySingleWindowColumnsDelegateSwapHorizontal() {
        let dual = makePhase3SingleWindowColumnsScenario()
        let zigEngine = dual.zigEngine
        let wsId = dual.workspaceId
        var zigState = ViewportState()
        var referenceState = ViewportState()

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: zigEngine.columns(in: wsId))
        guard let sourceIndex = windowIndex(in: snapshot, pid: 81_001) else {
            #expect(Bool(false), "missing source window for single-window delegate scenario")
            return
        }

        let request = NiriStateZigKernel.MutationRequest(
            op: .swapWindowHorizontal,
            sourceWindowIndex: sourceIndex,
            direction: .right,
            infiniteLoop: false,
            maxWindowsPerColumn: zigEngine.maxWindowsPerColumn
        )
        let outcome = runMutationParityStep(
            dual: dual,
            request: request,
            zigState: &zigState,
            referenceState: &referenceState
        )

        #expect(outcome.zig.edits.contains(where: { $0.kind == .delegateMoveColumn }))
        #expect(outcome.reference.edits.contains(where: { $0.kind == .delegateMoveColumn }))
        let leadingPIDs = zigEngine.columns(in: wsId).compactMap { $0.windowNodes.first?.handle.pid }
        #expect(leadingPIDs == [81_002, 81_001])
    }

    @Test func phase3ScenarioParityTabbedColumnsActiveTileAndVisibilityRefresh() {
        let dual = makePhase3TabbedColumnsScenario()
        let zigEngine = dual.zigEngine
        let referenceEngine = dual.referenceEngine
        let wsId = dual.workspaceId
        var zigState = ViewportState()
        var referenceState = ViewportState()

        let verticalSnapshot = NiriStateZigKernel.makeSnapshot(columns: zigEngine.columns(in: wsId))
        guard let verticalSource = windowIndex(in: verticalSnapshot, pid: 82_002) else {
            #expect(Bool(false), "missing tabbed vertical source window")
            return
        }
        let verticalRequest = NiriStateZigKernel.MutationRequest(
            op: .moveWindowVertical,
            sourceWindowIndex: verticalSource,
            direction: .up,
            infiniteLoop: false,
            maxWindowsPerColumn: zigEngine.maxWindowsPerColumn
        )
        let verticalOutcome = runMutationParityStep(
            dual: dual,
            request: verticalRequest,
            zigState: &zigState,
            referenceState: &referenceState
        )
        #expect(verticalOutcome.zig.edits.contains(where: { $0.kind == .setActiveTile }))
        #expect(verticalOutcome.reference.edits.contains(where: { $0.kind == .setActiveTile }))

        let insertSnapshot = NiriStateZigKernel.makeSnapshot(columns: zigEngine.columns(in: wsId))
        guard let insertSource = windowIndex(in: insertSnapshot, pid: 82_002),
              let insertTarget = windowIndex(in: insertSnapshot, pid: 82_101)
        else {
            #expect(Bool(false), "missing tabbed insert-by-move source/target windows")
            return
        }
        let insertRequest = NiriStateZigKernel.MutationRequest(
            op: .insertWindowByMove,
            sourceWindowIndex: insertSource,
            targetWindowIndex: insertTarget,
            infiniteLoop: false,
            insertPosition: .before,
            maxWindowsPerColumn: zigEngine.maxWindowsPerColumn
        )
        let insertOutcome = runMutationParityStep(
            dual: dual,
            request: insertRequest,
            zigState: &zigState,
            referenceState: &referenceState
        )
        #expect(insertOutcome.zig.edits.contains(where: { $0.kind == .setActiveTile }))
        #expect(insertOutcome.reference.edits.contains(where: { $0.kind == .setActiveTile }))

        let horizontalSnapshot = NiriStateZigKernel.makeSnapshot(columns: zigEngine.columns(in: wsId))
        guard let horizontalSource = windowIndex(in: horizontalSnapshot, pid: 82_001) else {
            #expect(Bool(false), "missing tabbed horizontal source window")
            return
        }
        let horizontalRequest = NiriStateZigKernel.MutationRequest(
            op: .moveWindowHorizontal,
            sourceWindowIndex: horizontalSource,
            direction: .right,
            infiniteLoop: false,
            maxWindowsPerColumn: zigEngine.maxWindowsPerColumn
        )
        let horizontalOutcome = runMutationParityStep(
            dual: dual,
            request: horizontalRequest,
            zigState: &zigState,
            referenceState: &referenceState
        )
        #expect(horizontalOutcome.zig.edits.contains(where: { $0.kind == .refreshTabbedVisibility }))
        #expect(horizontalOutcome.reference.edits.contains(where: { $0.kind == .refreshTabbedVisibility }))

        assertTabbedVisibilityConsistency(engine: zigEngine, workspaceId: wsId)
        assertTabbedVisibilityConsistency(engine: referenceEngine, workspaceId: wsId)
        #expect(
            tabbedHiddenSignature(engine: zigEngine, workspaceId: wsId) ==
                tabbedHiddenSignature(engine: referenceEngine, workspaceId: wsId)
        )
    }

    @Test func phase3ScenarioParityWidthFullWidthSwapState() {
        let dual = makePhase3WidthStateSwapScenario()
        let zigEngine = dual.zigEngine
        let wsId = dual.workspaceId
        var zigState = ViewportState()
        var referenceState = ViewportState()

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: zigEngine.columns(in: wsId))
        guard let sourceIndex = windowIndex(in: snapshot, pid: 83_001) else {
            #expect(Bool(false), "missing width/full-width swap source window")
            return
        }

        let request = NiriStateZigKernel.MutationRequest(
            op: .swapWindowHorizontal,
            sourceWindowIndex: sourceIndex,
            direction: .right,
            infiniteLoop: false,
            maxWindowsPerColumn: zigEngine.maxWindowsPerColumn
        )
        let outcome = runMutationParityStep(
            dual: dual,
            request: request,
            zigState: &zigState,
            referenceState: &referenceState
        )

        #expect(outcome.zig.edits.contains(where: { $0.kind == .swapColumnWidthState }))
        #expect(outcome.reference.edits.contains(where: { $0.kind == .swapColumnWidthState }))

        let columns = zigEngine.columns(in: wsId)
        #expect(columns.count == 2)
        guard columns.count == 2 else { return }
        #expect(columns[0].width == .proportion(0.33))
        #expect(columns[0].isFullWidth == false)
        #expect(columns[0].savedWidth == nil)
        #expect(columns[1].width == .proportion(0.62))
        #expect(columns[1].isFullWidth == true)
        #expect(columns[1].savedWidth == .proportion(0.41))
    }

    @Test func deterministicFixturesMatchReferenceModel() {
        let dual = makeDualEngines(seed: 0xA55A_A55A_1234_5678)
        let zigEngine = dual.zigEngine
        let refEngine = dual.referenceEngine
        let wsId = dual.workspaceId
        var zigState = ViewportState()
        var refState = ViewportState()

        let initialSnapshot = NiriStateZigKernel.makeSnapshot(columns: zigEngine.columns(in: wsId))
        #expect(initialSnapshot.windowEntries.count >= 3)
        guard initialSnapshot.windowEntries.count >= 3 else { return }

        let requests: [NiriStateZigKernel.MutationRequest] = [
            .init(op: .moveWindowVertical, sourceWindowIndex: 0, direction: .up, infiniteLoop: zigEngine.infiniteLoop, maxWindowsPerColumn: zigEngine.maxWindowsPerColumn),
            .init(op: .swapWindowVertical, sourceWindowIndex: 1, direction: .down, infiniteLoop: zigEngine.infiniteLoop, maxWindowsPerColumn: zigEngine.maxWindowsPerColumn),
            .init(op: .moveWindowHorizontal, sourceWindowIndex: 0, direction: .right, infiniteLoop: zigEngine.infiniteLoop, maxWindowsPerColumn: zigEngine.maxWindowsPerColumn),
            .init(op: .swapWindowHorizontal, sourceWindowIndex: 1, direction: .left, infiniteLoop: zigEngine.infiniteLoop, maxWindowsPerColumn: zigEngine.maxWindowsPerColumn),
            .init(op: .swapWindowsByMove, sourceWindowIndex: 0, targetWindowIndex: 2, infiniteLoop: zigEngine.infiniteLoop, maxWindowsPerColumn: zigEngine.maxWindowsPerColumn),
            .init(op: .insertWindowByMove, sourceWindowIndex: 1, targetWindowIndex: 0, infiniteLoop: zigEngine.infiniteLoop, insertPosition: .after, maxWindowsPerColumn: zigEngine.maxWindowsPerColumn),
        ]

        for request in requests {
            let zigSnapshot = NiriStateZigKernel.makeSnapshot(columns: zigEngine.columns(in: wsId))
            let refSnapshot = NiriStateZigKernel.makeSnapshot(columns: refEngine.columns(in: wsId))

            let zig = NiriStateZigKernel.resolveMutation(snapshot: zigSnapshot, request: request)
            let reference = NiriReferenceWindowOps.resolve(snapshot: refSnapshot, request: request)
            assertMutationOutcomeParity(zig: zig, reference: reference)

            let zigApplied = applyMutationOutcome(
                engine: zigEngine,
                workspaceId: wsId,
                state: &zigState,
                snapshot: zigSnapshot,
                outcome: zig,
                workingFrame: dual.workingFrame,
                gaps: dual.gaps
            )
            let refApplied = applyMutationOutcome(
                engine: refEngine,
                workspaceId: wsId,
                state: &refState,
                snapshot: refSnapshot,
                outcome: reference,
                workingFrame: dual.workingFrame,
                gaps: dual.gaps
            )
            #expect(zigApplied == refApplied)

            assertMutationInvariants(engine: zigEngine, workspaceId: wsId)
            assertMutationInvariants(engine: refEngine, workspaceId: wsId)
            #expect(layoutSignature(engine: zigEngine, workspaceId: wsId) == layoutSignature(engine: refEngine, workspaceId: wsId))
        }
    }

    @Test func randomizedMutationTraceParityMatchesReferenceModel() {
        let traceCount = 5_000
        let opsPerTrace = 12
        var rng = MutationLCG(seed: 0x1234_ABCD_5678_EF01)

        for trace in 0 ..< traceCount {
            let dual = makeDualEngines(seed: UInt64(20_000 + trace))
            let zigEngine = dual.zigEngine
            let refEngine = dual.referenceEngine
            let wsId = dual.workspaceId
            var zigState = ViewportState()
            var refState = ViewportState()

            for _ in 0 ..< opsPerTrace {
                let zigSnapshot = NiriStateZigKernel.makeSnapshot(columns: zigEngine.columns(in: wsId))
                let refSnapshot = NiriStateZigKernel.makeSnapshot(columns: refEngine.columns(in: wsId))
                #expect(zigSnapshot.windowEntries.count == refSnapshot.windowEntries.count)
                #expect(!zigSnapshot.windowEntries.isEmpty)
                guard !zigSnapshot.windowEntries.isEmpty else { break }

                let request = makeRandomMutationRequest(
                    snapshot: zigSnapshot,
                    maxWindowsPerColumn: zigEngine.maxWindowsPerColumn,
                    infiniteLoop: zigEngine.infiniteLoop,
                    rng: &rng
                )

                let zig = NiriStateZigKernel.resolveMutation(snapshot: zigSnapshot, request: request)
                let reference = NiriReferenceWindowOps.resolve(snapshot: refSnapshot, request: request)
                assertMutationOutcomeParity(zig: zig, reference: reference)

                let zigApplied = applyMutationOutcome(
                    engine: zigEngine,
                    workspaceId: wsId,
                    state: &zigState,
                    snapshot: zigSnapshot,
                    outcome: zig,
                    workingFrame: dual.workingFrame,
                    gaps: dual.gaps
                )
                let refApplied = applyMutationOutcome(
                    engine: refEngine,
                    workspaceId: wsId,
                    state: &refState,
                    snapshot: refSnapshot,
                    outcome: reference,
                    workingFrame: dual.workingFrame,
                    gaps: dual.gaps
                )
                #expect(zigApplied == refApplied)

                if zig.hasTarget {
                    #expect(zig.targetWindowIndex != nil)
                }

                assertMutationInvariants(engine: zigEngine, workspaceId: wsId)
                assertMutationInvariants(engine: refEngine, workspaceId: wsId)
                #expect(layoutSignature(engine: zigEngine, workspaceId: wsId) == layoutSignature(engine: refEngine, workspaceId: wsId))
            }
        }
    }

    @Test func windowOpsMutationPlannerBenchmarkHarnessP95() throws {
        let dual = makeDualEngines(seed: 0xD00D_BEEF_F00D_1234)
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: dual.zigEngine.columns(in: dual.workspaceId))
        #expect(!snapshot.windowEntries.isEmpty)
        guard !snapshot.windowEntries.isEmpty else { return }

        var rng = MutationLCG(seed: 0xABCDEF0123456789)
        var requests: [NiriStateZigKernel.MutationRequest] = []
        requests.reserveCapacity(10_000)
        for _ in 0 ..< 10_000 {
            requests.append(
                makeRandomMutationRequest(
                    snapshot: snapshot,
                    maxWindowsPerColumn: dual.zigEngine.maxWindowsPerColumn,
                    infiniteLoop: dual.zigEngine.infiniteLoop,
                    rng: &rng
                )
            )
        }

        var samples: [Double] = []
        samples.reserveCapacity(requests.count)

        for request in requests {
            let t0 = CACurrentMediaTime()
            _ = NiriStateZigKernel.resolveMutation(snapshot: snapshot, request: request)
            samples.append(CACurrentMediaTime() - t0)
        }

        let p95 = percentile(samples, 0.95)
        print(String(format: "Niri window-ops mutation planner p95 (zig): %.9f", p95))

        let baseline = try BenchmarkBaselines.loadPhase3WindowOps()
        let perfLimit = baseline.window_ops_planner_p95_sec * 1.10

        #expect(p95 > 0)
        #expect(p95 <= perfLimit)
    }

    @Test func windowOpsRuntimeFullPathBenchmarkHarnessP95() throws {
        let dual = makeDualEngines(seed: 0xCAFE_BABE_1020_3040)
        let engine = dual.zigEngine
        let wsId = dual.workspaceId
        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        var rng = MutationLCG(seed: 0x5566_7788_99AA_BBCC)
        var samples: [Double] = []
        samples.reserveCapacity(10_000)

        for _ in 0 ..< 10_000 {
            let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: wsId))
            #expect(!snapshot.windowEntries.isEmpty)
            guard !snapshot.windowEntries.isEmpty else { break }

            let request = makeRandomMutationRequest(
                snapshot: snapshot,
                maxWindowsPerColumn: engine.maxWindowsPerColumn,
                infiniteLoop: engine.infiniteLoop,
                rng: &rng
            )

            let t0 = CACurrentMediaTime()
            _ = executeRuntimeMutation(
                engine: engine,
                workspaceId: wsId,
                request: request,
                snapshot: snapshot,
                state: &state,
                workingFrame: dual.workingFrame,
                gaps: dual.gaps
            )
            samples.append(CACurrentMediaTime() - t0)
        }

        let p95 = percentile(samples, 0.95)
        print(String(format: "Niri window-ops runtime full-path p95 (zig): %.9f", p95))

        let baseline = try BenchmarkBaselines.loadPhase3WindowOps()
        let perfLimit = baseline.window_ops_full_path_p95_sec * 1.10

        #expect(p95 > 0)
        #expect(p95 <= perfLimit)
    }
}

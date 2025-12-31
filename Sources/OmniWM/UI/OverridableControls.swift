import SwiftUI

struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundColor(.secondary)
    }
}

struct OverridableToggle: View {
    let label: String
    let value: Bool?
    let globalValue: Bool
    let onChange: (Bool) -> Void
    let onReset: () -> Void

    private var effectiveValue: Bool { value ?? globalValue }
    private var isOverridden: Bool { value != nil }

    var body: some View {
        HStack {
            Toggle(label, isOn: Binding(
                get: { effectiveValue },
                set: { onChange($0) }
            ))

            Spacer()

            if isOverridden {
                Button {
                    onReset()
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to global default")
            } else {
                Text("Global")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct OverridablePicker<T: Hashable & Identifiable>: View {
    let label: String
    let value: T?
    let globalValue: T
    let options: [T]
    let displayName: (T) -> String
    let onChange: (T) -> Void
    let onReset: () -> Void

    private var effectiveValue: T { value ?? globalValue }
    private var isOverridden: Bool { value != nil }

    var body: some View {
        HStack {
            Picker(label, selection: Binding(
                get: { effectiveValue },
                set: { onChange($0) }
            )) {
                ForEach(options) { option in
                    Text(displayName(option)).tag(option)
                }
            }

            if isOverridden {
                Button {
                    onReset()
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to global default")
            } else {
                Text("Global")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 45)
            }
        }
    }
}

struct OverridableSlider: View {
    let label: String
    let value: Double?
    let globalValue: Double
    let range: ClosedRange<Double>
    let step: Double
    let formatter: (Double) -> String
    let onChange: (Double) -> Void
    let onReset: () -> Void

    private var effectiveValue: Double { value ?? globalValue }
    private var isOverridden: Bool { value != nil }

    var body: some View {
        HStack {
            Text(label)
            Slider(value: Binding(
                get: { effectiveValue },
                set: { onChange($0) }
            ), in: range, step: step)
            Text(formatter(effectiveValue))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 48, alignment: .trailing)

            if isOverridden {
                Button {
                    onReset()
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to global default")
            } else {
                Text("Global")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 45)
            }
        }
    }
}

struct OverridableStepper: View {
    let label: String
    let value: Double?
    let globalValue: Double
    let range: ClosedRange<Double>
    let step: Double
    let formatter: (Double) -> String
    let onChange: (Double) -> Void
    let onReset: () -> Void

    private var effectiveValue: Double { value ?? globalValue }
    private var isOverridden: Bool { value != nil }

    var body: some View {
        HStack {
            Text(label)
            Spacer()

            HStack(spacing: 4) {
                Button {
                    onChange(max(range.lowerBound, effectiveValue - step))
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.bordered)

                TextField("", value: Binding(
                    get: { effectiveValue },
                    set: { onChange(min(max($0, range.lowerBound), range.upperBound)) }
                ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.center)

                Button {
                    onChange(min(range.upperBound, effectiveValue + step))
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
            }

            Text(formatter(effectiveValue))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 48, alignment: .trailing)

            if isOverridden {
                Button {
                    onReset()
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to global default")
            } else {
                Text("Global")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 45)
            }
        }
    }
}

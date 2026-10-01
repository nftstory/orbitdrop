import SwiftUI
import OrbitCore

/// Parameter sheet generated from a tool's declared options.
struct ToolOptionsSheet: View {
    let tool: ToolDescriptor
    @ObservedObject var model: AppModel

    @State private var texts: [String: String] = [:]
    @State private var toggles: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tool.title)
                .font(.headline)
            Text(tool.summary)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                ForEach(tool.parameters, id: \.key) { parameter in
                    field(for: parameter)
                    if !parameter.help.isEmpty {
                        Text(parameter.help)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Text(model.rows.count == 1 ? "1 file" : "\(model.rows.count) files")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { model.pendingTool = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Run") { run() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: loadDefaults)
    }

    private func textBinding(_ key: String) -> Binding<String> {
        Binding(get: { texts[key] ?? "" }, set: { texts[key] = $0 })
    }

    private func toggleBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { toggles[key] ?? false }, set: { toggles[key] = $0 })
    }

    @ViewBuilder
    private func field(for parameter: ToolParameter) -> some View {
        switch parameter.kind {
        case .number, .text:
            TextField(parameter.label, text: textBinding(parameter.key))
        case .choice(let options, _):
            Picker(parameter.label, selection: textBinding(parameter.key)) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        case .toggle:
            Toggle(parameter.label, isOn: toggleBinding(parameter.key))
        }
    }

    private static func display(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }

    private func loadDefaults() {
        for parameter in tool.parameters {
            switch parameter.kind {
            case .number(let value):
                texts[parameter.key] = value.map(ToolOptionsSheet.display) ?? ""
            case .text(let value):
                texts[parameter.key] = value
            case .choice(_, let value):
                texts[parameter.key] = value
            case .toggle(let value):
                toggles[parameter.key] = value
            }
        }
    }

    private func run() {
        var values: [String: Any] = [:]
        for parameter in tool.parameters {
            if case .toggle = parameter.kind {
                values[parameter.key] = toggles[parameter.key] ?? false
            } else if let text = texts[parameter.key], !text.trimmingCharacters(in: .whitespaces).isEmpty {
                // Numbers travel as strings; ToolOptions validates them and
                // the row status shows any error.
                values[parameter.key] = text
            }
        }
        model.pendingTool = nil
        model.runTool(tool, values: values)
    }
}

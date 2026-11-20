import AnyBrowserCore
import SwiftUI

struct ProfileEditor: View {
    @Binding var draft: ProfileDraft
    let state: BrowserRunState
    let pendingRestart: Bool
    let copyAddress: (Int) -> Void
    let randomize: (Set<FingerprintField>) -> Bool

    @State private var showRandomizer = false
    @State private var randomFields: Set<FingerprintField> = [.seed]
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkbenchCard {
                heading("基本设置", icon: "macwindow")
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    EditorInput("Profile 名称", placeholder: "例如 工作环境",
                                value: $draft.profile.name, identifier: "profile-name")
                    EditorInput("调试端口", placeholder: "9222",
                                value: $draft.portText, identifier: "debug-port", numeric: true)
                }
                Divider()
                debugRow
            }

            WorkbenchCard {
                HStack(alignment: .center, spacing: 12) {
                    heading("浏览器指纹", icon: "switch.2")
                    Spacer(minLength: 1)
                    Button {
                        showRandomizer.toggle()
                    } label: {
                        Label("随机生成", systemImage: "shuffle")
                    }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .accessibilityIdentifier("randomize-profile")
                    .popover(isPresented: $showRandomizer, arrowEdge: .bottom) {
                        randomizer
                    }
                }
                fingerprintFields
            }

            WorkbenchCard {
                heading("指纹改写项", icon: "slider.horizontal.3")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 180), spacing: 12)],
                          alignment: .leading, spacing: 10) {
                    ForEach(FingerprintAdjustment.allCases, id: \.self) { adjustment in
                        Toggle(adjustment.title, isOn: adjustmentBinding(adjustment))
                            .toggleStyle(.checkbox)
                            .disabled(adjustment == .gpu && draft.profile.fingerprint.platform == .linux)
                            .accessibilityIdentifier("adjustment-\(adjustment.rawValue)")
                    }
                }
                Text("设备内存由种子决定。WebGL 默认使用 Windows 档位，选择 Linux 时不可用。")
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.muted)
            }
        }
        .onChange(of: draft.profile.fingerprint.platform) { platform in
            if platform == nil { draft.profile.fingerprint.platformVersion = "" }
        }
        .onChange(of: draft.profile.fingerprint.brand) { brand in
            if brand == nil { draft.profile.fingerprint.brandVersion = "" }
        }
    }

    private var fingerprintFields: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            EditorPicker(title: "平台", identifier: "fingerprint-platform",
                         selection: $draft.profile.fingerprint.platform,
                         choices: [(nil, "引擎默认")] + BrowserPlatform.allCases.map { (Optional($0), $0.title) })
            EditorInput("平台版本",
                        placeholder: draft.profile.fingerprint.platform == nil ? "先选择平台" : "引擎默认",
                        value: $draft.profile.fingerprint.platformVersion, identifier: "platform-version")
                .disabled(draft.profile.fingerprint.platform == nil)
            EditorPicker(title: "浏览器品牌", identifier: "fingerprint-brand",
                         selection: $draft.profile.fingerprint.brand,
                         choices: [(nil, "引擎默认")] + BrowserBrand.allCases.map { (Optional($0), $0.rawValue) })
            EditorInput("品牌版本", placeholder: brandVersionPlaceholder,
                        value: $draft.profile.fingerprint.brandVersion, identifier: "brand-version")
                .disabled(draft.profile.fingerprint.brand == nil)
            EditorInput("指纹种子", placeholder: "输入整数",
                        value: $draft.seedText, identifier: "fingerprint-seed", numeric: true)
            EditorInput("逻辑 CPU", placeholder: "由种子计算",
                        value: $draft.cpuText, identifier: "cpu-count", numeric: true)
            EditorInput("语言", placeholder: "如 zh-CN",
                        value: $draft.profile.fingerprint.language, identifier: "fingerprint-language")
            EditorInput("时区", placeholder: "如 Asia/Shanghai",
                        value: $draft.profile.fingerprint.timeZone, identifier: "fingerprint-time-zone")
        }
    }

    private var brandVersionPlaceholder: String {
        switch draft.profile.fingerprint.brand {
        case nil: return "先选择品牌"
        case .opera, .vivaldi: return "请输入版本"
        case .chrome, .edge: return "引擎默认"
        }
    }

    private var debugRow: some View {
        let session: (port: Int, ready: Bool)?
        if case .running(_, let port, let ready) = state {
            session = (port, ready)
        } else {
            session = nil
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(state.indicator).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(state.statusTitle)
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(WorkbenchPalette.iconSurface, in: Capsule())
                .accessibilityIdentifier("browser-status")
                if pendingRestart {
                    Text("等待重启")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(WorkbenchPalette.amber)
                }
                Spacer(minLength: 0)
                if let session, session.ready {
                    Text(verbatim: "http://127.0.0.1:\(session.port)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(WorkbenchPalette.muted)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("debug-address")
                    Button {
                        copyAddress(session.port)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(WorkbenchButtonStyle(.quiet))
                    .accessibilityLabel("复制调试地址")
                    .accessibilityIdentifier("copy-debug-address")
                    .help("复制调试地址")
                } else {
                    Text(session == nil ? "调试地址仅在本机可用" : "调试端口未就绪")
                        .font(.system(size: 11))
                        .foregroundColor(WorkbenchPalette.muted)
                }
            }
            if case .failed(let message) = state {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.danger)
                    .textSelection(.enabled)
            }
        }
    }

    private var randomizer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择随机生成的字段")
                .font(.system(size: 16, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(FingerprintField.allCases, id: \.self) { field in
                    Toggle(field.title, isOn: randomBinding(field))
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("randomize-field-\(field.rawValue)")
                }
            }
            Divider()
            HStack {
                Button(randomFields == Set(FingerprintField.allCases) ? "取消全选" : "全选") {
                    let all = Set(FingerprintField.allCases)
                    randomFields = randomFields == all ? [] : all
                }
                .buttonStyle(WorkbenchButtonStyle(.quiet))
                Spacer()
                Button("生成预览") {
                    showRandomizer = false
                    _ = randomize(randomFields)
                }
                .buttonStyle(WorkbenchButtonStyle(.primary))
                .disabled(randomFields.isEmpty)
                .accessibilityIdentifier("apply-randomization")
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func heading(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 15, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private func adjustmentBinding(_ value: FingerprintAdjustment) -> Binding<Bool> {
        Binding(
            get: { draft.profile.fingerprint.adjustments.contains(value) },
            set: { isOn in
                if isOn {
                    draft.profile.fingerprint.adjustments.insert(value)
                } else {
                    draft.profile.fingerprint.adjustments.remove(value)
                }
            }
        )
    }

    private func randomBinding(_ field: FingerprintField) -> Binding<Bool> {
        Binding(
            get: { randomFields.contains(field) },
            set: { isOn in
                if isOn {
                    randomFields.insert(field)
                } else {
                    randomFields.remove(field)
                }
            }
        )
    }
}

private struct EditorInput: View {
    let label: String
    let placeholder: String
    @Binding var value: String
    let identifier: String
    var numeric = false
    @FocusState private var focused: Bool

    init(_ label: String, placeholder: String, value: Binding<String>, identifier: String, numeric: Bool = false) {
        self.label = label
        self.placeholder = placeholder
        self._value = value
        self.identifier = identifier
        self.numeric = numeric
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .accessibilityHidden(true)
            TextField(label, text: $value, prompt: Text(placeholder).foregroundColor(WorkbenchPalette.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: numeric ? .monospaced : .default))
                .focused($focused)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(WorkbenchPalette.field, in: fieldShape)
                .overlay { fieldShape.strokeBorder(focused ? Color.accentColor : WorkbenchPalette.rule, lineWidth: 1) }
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }
}

private struct EditorPicker<Value: Hashable>: View {
    let title: String
    let identifier: String
    @Binding var selection: Value
    let choices: [(value: Value, title: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .accessibilityHidden(true)
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(choices.indices, id: \.self) { index in
                        let choice = choices[index]
                        Text(choice.title).tag(choice.value)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(choices.first { $0.value == selection }?.title ?? "")
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(WorkbenchPalette.field, in: fieldShape)
            .overlay { fieldShape.strokeBorder(WorkbenchPalette.rule, lineWidth: 1) }
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
        }
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }
}

import AnyBrowserCore
import SwiftUI

/// Fingerprint fields, random generation and spoofing adjustments.
struct FingerprintCard: View {
    @Binding var draft: ProfileDraft
    @ObservedObject var workbench: Workbench

    @State private var showRandomizer = false
    @State private var showPresets = false
    @State private var randomFields: Set<FingerprintField> = [.seed]
    @State private var regenerating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkbenchCard {
                HStack(alignment: .center, spacing: 12) {
                    CardHeading(title: "浏览器指纹", icon: "switch.2")
                    Spacer(minLength: 1)
                    Button {
                        showPresets.toggle()
                    } label: {
                        Label("身份模板", systemImage: "person.crop.rectangle")
                    }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .accessibilityIdentifier("identity-presets")
                    .popover(isPresented: $showPresets, arrowEdge: .bottom) {
                        presetMenu
                    }
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
                    Button {
                        regenerating = true
                        Task {
                            _ = await workbench.regenerateIdentity()
                            regenerating = false
                        }
                    } label: {
                        Label(regenerating ? "生成中…" : "整套重新生成",
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .disabled(regenerating)
                    .accessibilityIdentifier("regenerate-identity")
                }
                fingerprintFields
                identitySummary
                consistencyWarnings
            }

            WorkbenchCard {
                CardHeading(title: "指纹改写项", icon: "slider.horizontal.3")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 180), spacing: 12)],
                          alignment: .leading, spacing: 10) {
                    ForEach(FingerprintAdjustment.allCases, id: \.self) { adjustment in
                        Toggle(adjustment.title, isOn: adjustmentBinding(adjustment))
                            .toggleStyle(.checkbox)
                            .disabled(adjustment == .gpu && draft.profile.fingerprint.platform == .linux)
                            .accessibilityIdentifier("adjustment-\(adjustment.rawValue)")
                    }
                }
                Text("新建 Profile 会自动生成一套身份；「整套重新生成」会换种子、语言/时区、CPU 与字体表。屏幕、色深、设备内存与字体表需要引擎补丁，当前跟随本机。")
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.muted)
            }
        }
        .onChange(of: draft.profile.fingerprint.platform) { _ in
            draft.profile.fingerprint.adaptToPlatform()
        }
        .onChange(of: draft.profile.fingerprint.brand) { brand in
            if brand == nil { draft.profile.fingerprint.brandVersion = "" }
        }
    }

    private var fingerprintFields: some View {
        LazyVGrid(columns: EditorInput.columns, alignment: .leading, spacing: 12) {
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

    private var identitySummary: some View {
        let fingerprint = draft.profile.fingerprint
        let platform = fingerprint.platform.map {
            $0.title + (fingerprint.platformVersion.isEmpty ? "" : " \(fingerprint.platformVersion)")
        } ?? "引擎默认"
        let brand = fingerprint.brand.map {
            $0.rawValue + (fingerprint.brandVersion.isEmpty ? "" : " \(fingerprint.brandVersion)")
        } ?? "引擎默认"
        let screen = fingerprint.screenWidth.flatMap { width in
            fingerprint.screenHeight.map { height in
                let scale = fingerprint.deviceScaleFactor.map { String(format: "%g", $0) } ?? "?"
                return "\(width)×\(height) @\(scale)x · \(fingerprint.colorDepth ?? 24)bit"
            }
        } ?? "跟随本机"
        let languages = fingerprint.languages?.joined(separator: ", ")
            ?? (fingerprint.language.isEmpty ? "跟随本机" : fingerprint.language)
        let locale = "\(languages) · \(fingerprint.timeZone.isEmpty ? "本机时区" : fingerprint.timeZone)"
        let fonts = fingerprint.fontProfile.map {
            $0.platform == .macOS ? "macOS 字体（宿主）" : "\($0.title)（待引擎）"
        } ?? "宿主字体"
        let memory = fingerprint.deviceMemory.map { "\($0) GB" } ?? "不声明"
        return VStack(alignment: .leading, spacing: 4) {
            Text("身份摘要")
                .font(.system(size: 12, weight: .semibold))
            Text("\(platform) · \(brand) · \(fingerprint.cpuCount.map(String.init) ?? "CPU 自动")")
            Text("\(screen) · \(locale)")
            Text("\(fonts) · 设备内存 \(memory) · 种子 \(fingerprint.seed)")
        }
        .font(.system(size: 12))
        .foregroundColor(WorkbenchPalette.muted)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("identity-summary")
    }

    private var brandVersionPlaceholder: String {
        switch draft.profile.fingerprint.brand {
        case nil: return "先选择品牌"
        case .opera, .vivaldi: return "请输入版本"
        case .chrome, .edge: return "引擎默认"
        }
    }

    /// Hints only: a mismatch never blocks saving or launching.
    @ViewBuilder private var consistencyWarnings: some View {
        let issues = draft.profile.consistencyIssues(engineVersion: workbench.engineVersion,
                                                      exit: workbench.proxyCenter.exit(for: draft.profile.id,
                                                                                       proxy: draft.profile.proxy))
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(issues) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundColor(WorkbenchPalette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("consistency-\(issue.id)")
                }
            }
        }
    }

    private var presetMenu: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("套用身份模板")
                .font(.system(size: 16, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("调整平台、版本、品牌、CPU 和改写项，保留种子、语言和时区。")
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
            ForEach(IdentityPreset.all) { preset in
                Button {
                    apply(preset)
                } label: {
                    Text(preset.title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(WorkbenchButtonStyle(.quiet))
                .accessibilityIdentifier("identity-preset-\(preset.id)")
            }
        }
        .padding(20)
        .frame(width: 280)
    }

    private func apply(_ preset: IdentityPreset) {
        showPresets = false
        preset.apply(to: &draft.profile.fingerprint)
        draft.cpuText = draft.profile.fingerprint.cpuCount.map(String.init) ?? ""
        workbench.notice = Workbench.Notice(text: "已套用「\(preset.title)」，保存后应用。")
    }

    private var randomizer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择随机生成的字段")
                .font(.system(size: 16, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: EditorInput.columns, alignment: .leading, spacing: 10) {
                ForEach(FingerprintField.allCases, id: \.self) { field in
                    Toggle(field.title, isOn: randomBinding(field))
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("randomize-field-\(field.rawValue)")
                }
            }
            Text("语言与时区成对生成；Canvas 与元素坐标始终开启，GPU 按平台开启，非 macOS 不启用字体伪装。")
                .font(.system(size: 11))
                .foregroundColor(WorkbenchPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
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
                    _ = workbench.randomize(randomFields)
                }
                .buttonStyle(WorkbenchButtonStyle(.primary))
                .disabled(randomFields.isEmpty)
                .accessibilityIdentifier("apply-randomization")
            }
        }
        .padding(20)
        .frame(width: 340)
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

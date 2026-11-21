import AnyBrowserCore
import SwiftUI

/// Fingerprint fields, random generation and spoofing adjustments.
struct FingerprintCard: View {
    @Binding var draft: ProfileDraft
    @ObservedObject var workbench: Workbench

    @State private var showRandomizer = false
    @State private var randomFields: Set<FingerprintField> = [.seed]
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkbenchCard {
                HStack(alignment: .center, spacing: 12) {
                    CardHeading(title: "浏览器指纹", icon: "switch.2")
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

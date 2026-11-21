import AnyBrowserCore
import Foundation

extension Workbench {
    /// Saves the running Profile's cookies to a JSON file.
    func exportCookies(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }), cookiesAvailable(id) else { return }
        guard let url = FilePanels.saveLocation(title: "导出 Cookie", prompt: "导出",
                                                name: Self.cookieFileName(profile.name)) else { return }
        Task {
            do {
                let export = try await CookieTransfer.exportCookies(from: cookieEndpoint(id))
                try CookieTransfer.writeFile(export.data, to: url)
                notice = Notice(text: "已导出 \(export.count) 条 Cookie。")
            } catch {
                show(error)
            }
        }
    }

    /// Loads cookies from a JSON file into the running Profile.
    func importCookies(_ id: UUID) {
        guard cookiesAvailable(id) else { return }
        // Cookie-Editor and EditThisCookie copy their exports to the clipboard, so pasted .txt files are common.
        guard let url = FilePanels.file(title: "导入 Cookie", prompt: "导入", types: [.json, .plainText]) else { return }
        Task {
            do {
                let data = try CookieTransfer.readFile(url)
                let result = try await CookieTransfer.importCookies(data, into: cookieEndpoint(id))
                notice = Notice(text: "已导入 \(result.imported) 条 Cookie，跳过 \(result.skipped) 条。")
            } catch {
                show(error)
            }
        }
    }

    /// Checked before a file panel opens, so that its choice isn't wasted.
    private func cookiesAvailable(_ id: UUID) -> Bool {
        guard case .running(_, _, let ready) = state(for: id) else {
            notice = Notice(text: "Profile 未运行，请先启动再导入或导出 Cookie。", isError: true)
            return false
        }
        guard ready else {
            notice = Notice(text: "浏览器调试端口尚未就绪，请稍后重试。", isError: true)
            return false
        }
        return true
    }

    private func cookieEndpoint(_ id: UUID) async throws -> URL {
        guard state(for: id).isRunning else {
            throw ProfileError.invalid("Profile 已停止，请先启动再导入或导出 Cookie。")
        }
        guard let endpoint = await runtime?.devToolsEndpoint(for: id) else {
            throw ProfileError.invalid("浏览器调试端口尚未就绪，请稍后重试。")
        }
        return endpoint
    }

    private static func cookieFileName(_ profileName: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let name = profileName.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
        return "\(name.isEmpty ? "Profile" : name)-Cookie-\(formatter.string(from: Date())).json"
    }
}

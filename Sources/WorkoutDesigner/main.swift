import Cocoa
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKUIDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var web: WKWebView!
    var syncFolder: URL?                    // carpeta de sincronización (Google Drive, iCloud Drive, Dropbox…)
    var syncTimer: Timer?
    var seen: [String: Date] = [:]
    var labels: [String: String] = [:]   // textos del menú, enviados por la página en el idioma elegido

    func L(_ key: String, _ fallback: String) -> String { labels[key] ?? fallback }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "native")
        web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = self

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Workout Designer"
        window.contentView = web
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)

        loadPage()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.checkUpdates(manual: false) }
    }

    // MARK: Actualizaciones (GitHub Releases)
    // «usuario/repositorio» de GitHub (repositorio público).
    let repo = "beltxo84/.workout"
    var pageVersion = "0"
    var shellVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0" }
    var overrideURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WorkoutDesigner", isDirectory: true).appendingPathComponent("index.html")
    }

    func meta(_ name: String, _ html: String) -> String? {
        guard let r = html.range(of: "<meta name=\"\(name)\" content=\"") else { return nil }
        let rest = html[r.upperBound...]
        guard let e = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<e])
    }

    // Compara versiones numéricas: -1 si a<b, 0 si iguales, 1 si a>b (1.10 > 1.9).
    func cmp(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }

    // Carga la página incluida en la app o la descargada, la que tenga versión mayor
    // (y solo si esta app cumple su versión mínima).
    func loadPage() {
        var html: String?
        var ver = "0"
        if let url = Bundle.main.url(forResource: "index", withExtension: "html"),
           let h = try? String(contentsOf: url, encoding: .utf8) {
            html = h; ver = meta("app-version", h) ?? "0"
        }
        if let h = try? String(contentsOf: overrideURL, encoding: .utf8) {
            let v = meta("app-version", h) ?? "0", need = meta("min-shell", h) ?? "0"
            if cmp(v, ver) > 0 && cmp(need, shellVersion) <= 0 { html = h; ver = v }
        }
        pageVersion = ver
        // Origen estable (https) para que localStorage persista y crypto.randomUUID funcione.
        if let h = html { web.loadHTMLString(h, baseURL: URL(string: "https://workout.local/")) }
    }

    func say(_ text: String) {
        let a = NSAlert(); a.messageText = "Workout Designer"; a.informativeText = text
        a.addButton(withTitle: "OK"); a.runModal()
    }

    @objc func checkNow(_ sender: Any?) { checkUpdates(manual: true) }

    func checkUpdates(manual: Bool) {
        let fail = { if manual { self.say(self.L("updfail", "No se pudo comprobar si hay actualizaciones.")) } }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return fail() }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("WorkoutDesigner", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            DispatchQueue.main.async {
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else { return fail() }
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if self.cmp(self.pageVersion, latest) >= 0 {
                    if manual { self.say(self.L("updok", "Ya tienes la última versión.")) }
                    return
                }
                let assets = json["assets"] as? [[String: Any]] ?? []
                func asset(_ n: String) -> URL? {
                    (assets.first { ($0["name"] as? String) == n }?["browser_download_url"] as? String).flatMap { URL(string: $0) }
                }
                #if arch(arm64)
                let dmg = asset("WorkoutDesigner-apple-silicon.dmg")
                #else
                let dmg = asset("WorkoutDesigner-intel.dmg")
                #endif
                // El Release puede existir unos minutos antes de que GitHub termine de adjuntar los archivos.
                guard let pageURL = asset("index.html") else { return fail() }
                URLSession.shared.dataTask(with: URLRequest(url: pageURL, timeoutInterval: 30)) { d, r, _ in
                    DispatchQueue.main.async {
                        guard (r as? HTTPURLResponse)?.statusCode == 200, let d = d,
                              let html = String(data: d, encoding: .utf8),
                              self.cmp(self.meta("app-version", html) ?? "0", self.pageVersion) > 0 else { return fail() }
                        let needShell = self.cmp(self.meta("min-shell", html) ?? "0", self.shellVersion) > 0
                        self.askUpdate(latest, html: html, needShell: needShell, dmg: dmg)
                    }
                }.resume()
            }
        }.resume()
    }

    func askUpdate(_ version: String, html: String, needShell: Bool, dmg: URL?) {
        let a = NSAlert()
        a.messageText = L("updt", "Versión nueva disponible")
        let msg = needShell
            ? L("updsh", "La versión %v necesita instalar la app de nuevo: se descargará el instalador y tendrás que arrastrarlo a Aplicaciones.")
            : L("updm", "La versión %v está lista. ¿Quieres actualizar ahora? La página se recargará y tus datos se conservan.")
        a.informativeText = msg.replacingOccurrences(of: "%v", with: version)
        a.addButton(withTitle: L("updb", "Actualizar"))
        a.addButton(withTitle: L("updl", "Más tarde"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if needShell {
            if let u = dmg { NSWorkspace.shared.open(u) }
            return
        }
        let dir = overrideURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if (try? html.write(to: overrideURL, atomically: true, encoding: .utf8)) != nil { loadPage() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Mensajes desde la página
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["a"] as? String else { return }

        if action == "menu" {
            if let l = body["l"] as? [String: String] { labels = l; buildMenu() }
            return
        }
        if action == "ready" { onReady(); return }
        if action == "url" {
            if let u = body["u"] as? String, (u.hasPrefix("https://geojson.io/") || u.hasPrefix("https://www.google.com/maps/")), let url = URL(string: u) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard let name = body["n"] as? String,
              let b64 = body["d"] as? String,
              let data = Data(base64Encoded: b64) else { return }
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")

        if action == "airdrop" {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(safeName)
            guard (try? data.write(to: file)) != nil else { return }
            if let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [file]) {
                service.perform(withItems: [file])
            } else {
                let picker = NSSharingServicePicker(items: [file])
                picker.show(relativeTo: .zero, of: web, preferredEdge: .minY)
            }
        } else if action == "syncwrite" {
            if let dir = syncFolder { try? data.write(to: dir.appendingPathComponent(safeName), options: .atomic) }
        } else if action == "save" {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = safeName
            panel.allowsOtherFileTypes = true
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { try? data.write(to: url) }
            }
        }
    }

    // Selector de archivos para <input type="file">
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    // MARK: Acciones del menú
    @objc func runJS(_ sender: NSMenuItem) {
        if let js = sender.representedObject as? String { web.evaluateJavaScript(js, completionHandler: nil) }
    }

    @objc func openFile(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = (kind == "gpx")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let name = url.lastPathComponent.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "")
                self.web.evaluateJavaScript("nativeFile('\(kind)','\(name)','\(data.base64EncodedString())')", completionHandler: nil)
            }
        }
    }

    @objc func showAbout(_ sender: Any?) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
        let credits = NSMutableAttributedString(string: "\(L("by", "Creado por")) beltxo84\n", attributes: attrs)
        credits.append(NSAttributedString(string: "beltxo84@proton.me", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .link: URL(string: "mailto:beltxo84@proton.me")!
        ]))
        NSApp.orderFrontStandardAboutPanel(options: [
            NSApplication.AboutPanelOptionKey.applicationName: "Workout Designer",
            NSApplication.AboutPanelOptionKey.applicationVersion: pageVersion,
            NSApplication.AboutPanelOptionKey.version: "",
            NSApplication.AboutPanelOptionKey.credits: credits
        ])
    }

    // MARK: Sincronización con una carpeta
    func jsString(_ text: String) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: [text]), let t = String(data: d, encoding: .utf8) { return t + "[0]" }
        return "\"\""
    }

    func onReady() {
        if syncFolder == nil, let path = UserDefaults.standard.string(forKey: "syncFolder"),
           FileManager.default.fileExists(atPath: path) {
            syncFolder = URL(fileURLWithPath: path, isDirectory: true)
        }
        guard let dir = syncFolder else { return }
        web.evaluateJavaScript("syncOn(\(jsString(dir.lastPathComponent)))", completionHandler: nil)
        startSyncTimer()
        readAll(force: true)
    }

    @objc func undoPage(_ sender: Any?) { web.evaluateJavaScript("undoApp()", completionHandler: nil) }
    @objc func redoPage(_ sender: Any?) { web.evaluateJavaScript("redoApp()", completionHandler: nil) }

    @objc func chooseSyncFolder(_ sender: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            self.syncFolder = url
            self.seen = [:]
            UserDefaults.standard.set(url.path, forKey: "syncFolder")
            self.web.evaluateJavaScript("syncOn(\(self.jsString(url.lastPathComponent)))", completionHandler: nil)
            self.startSyncTimer()
            self.readAll(force: true)
        }
    }

    @objc func stopSync(_ sender: NSMenuItem) {
        syncTimer?.invalidate(); syncTimer = nil
        syncFolder = nil
        UserDefaults.standard.removeObject(forKey: "syncFolder")
        web.evaluateJavaScript("syncOff()", completionHandler: nil)
    }

    func startSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.readAll(force: false)
        }
    }

    // Lee los archivos de los demás equipos y se los pasa a la página, que los fusiona.
    func readAll(force: Bool) {
        guard let dir = syncFolder,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var changed = force
        var texts: [String] = []
        for f in files where f.lastPathComponent.hasPrefix("workout-designer-") && f.pathExtension == "json" {
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            if seen[f.lastPathComponent] != mod { changed = true; seen[f.lastPathComponent] = mod }
            if let text = try? String(contentsOf: f, encoding: .utf8), !text.isEmpty { texts.append(text) }
        }
        guard changed, !texts.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: texts),
              let js = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("syncIn(\(js))", completionHandler: nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(stopSync(_:)) { return syncFolder != nil }
        return true
    }

    // MARK: Menú del sistema
    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu(); appItem.submenu = app
        let about = app.addItem(withTitle: L("about", "Acerca de Workout Designer"), action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        let upd = app.addItem(withTitle: L("upd", "Buscar actualizaciones…"), action: #selector(checkNow(_:)), keyEquivalent: "")
        upd.target = self
        app.addItem(.separator())
        app.addItem(withTitle: L("hide", "Ocultar Workout Designer"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: L("quit", "Salir de Workout Designer"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: L("file", "Archivo")); fileItem.submenu = file
        func add(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags, _ sel: Selector, _ obj: String) {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            item.representedObject = obj
            file.addItem(item)
        }
        add(L("new", "Nuevo"), "n", [.command], #selector(runJS(_:)), "nuevo()")
        add(L("open", "Abrir .workout"), "o", [.command], #selector(openFile(_:)), "workout")
        file.addItem(.separator())
        add(L("save", "Guardar"), "s", [.command], #selector(runJS(_:)), "guardar()")
        add(L("dl", "Descargar .workout"), "s", [.command, .shift], #selector(runJS(_:)), "bajar()")
        add(L("share", "Enviar por AirDrop"), "", [], #selector(runJS(_:)), "enviar()")
        file.addItem(.separator())
        add(L("backup", "Hacer copia de seguridad…"), "", [], #selector(runJS(_:)), "backup()")
        add(L("restore", "Cargar copia de seguridad…"), "", [], #selector(openFile(_:)), "backup")
        add(L("bulk", "Carga de .GPX, .FIT o .TCX…"), "", [], #selector(openFile(_:)), "gpx")
        file.addItem(.separator())
        add(L("sync", "Sincronizar con una carpeta…"), "", [], #selector(chooseSyncFolder(_:)), "")
        add(L("unsync", "Dejar de sincronizar"), "", [], #selector(stopSync(_:)), "")

        let planItem = NSMenuItem(); main.addItem(planItem)
        let plan = NSMenu(title: L("plans", "Planes de entrenamiento")); planItem.submenu = plan
        func addPlan(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags, _ sel: Selector, _ obj: String) {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            item.representedObject = obj
            plan.addItem(item)
        }
        addPlan(L("pnew", "Nuevo plan de entrenamiento"), "n", [.command, .option], #selector(runJS(_:)), "planMenu('new')")
        addPlan(L("pload", "Cargar plan de entrenamiento…"), "o", [.command, .option], #selector(openFile(_:)), "plan")
        plan.addItem(.separator())
        addPlan(L("psave", "Guardar plan de entrenamiento"), "s", [.command, .option], #selector(runJS(_:)), "planMenu('save')")
        addPlan(L("pdl", "Descargar plan de entrenamiento"), "s", [.command, .option, .shift], #selector(runJS(_:)), "planMenu('dl')")
        plan.addItem(.separator())
        addPlan(L("plib", "Planes de entrenamiento guardados"), "", [], #selector(runJS(_:)), "planMenu('lib')")

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: L("edit", "Edición")); editItem.submenu = edit
        let undo = edit.addItem(withTitle: L("undo", "Deshacer"), action: #selector(undoPage(_:)), keyEquivalent: "z"); undo.target = self
        let redo = edit.addItem(withTitle: L("redo", "Rehacer"), action: #selector(redoPage(_:)), keyEquivalent: "z"); redo.target = self
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("cut", "Cortar"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("copy", "Copiar"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("paste", "Pegar"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("selall", "Seleccionar todo"), action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

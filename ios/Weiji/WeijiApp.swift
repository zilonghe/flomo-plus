import SwiftUI

@main
struct WeijiApp: App {
    @State private var store: AppStore

    init() {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? {
            let prefix = key + "="
            return arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
        if let address = value("weiji_test_base_url"), let token = value("weiji_test_token"),
           let config = try? ServerConfiguration(address: address, token: token) {
            _store = State(initialValue: AppStore(initial: config, temporary: true, reset: value("weiji_reset_state") == "1"))
            return
        }
        #endif
        _store = State(initialValue: AppStore())
    }

    var body: some Scene {
        WindowGroup { RootTabView(store: store) }
    }
}

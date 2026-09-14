import Foundation

// One-time, metadata-only transfer authorized for the normal-app integration.
// Never read Keychain, private CLI folders, credentials, or provider payloads.
let manager = FileManager.default
let home = manager.homeDirectoryForCurrentUser
let sourceContainer = home.appendingPathComponent("Library/Containers/com.pardeike.TokenCoffee.AccountProbe/Data/Library")
let source = sourceContainer.appendingPathComponent("Application Support/TokenCoffeeAccountProbe")
let destination = home.appendingPathComponent("Library/Containers/com.pardeike.TokenCoffee/Data/Library/Application Support/TokenCoffee/multi-account")
let accountFile = destination.appendingPathComponent("accounts.json")
if !manager.fileExists(atPath: accountFile.path), manager.fileExists(atPath: source.appendingPathComponent("accounts.json").path) {
    let input = try Data(contentsOf: source.appendingPathComponent("accounts.json"))
    guard let original = try JSONSerialization.jsonObject(with: input) as? [String: Any],
          let rows = original["accounts"] as? [[String: Any]] else { throw CocoaError(.coderReadCorrupt) }
    var ids = Set<String>()
    let accounts: [[String: Any]] = try rows.map { row in
        guard let id = row["id"] as? String, UUID(uuidString: id) != nil, ids.insert(id).inserted,
              let provider = row["provider"] as? String, ["Codex", "Claude"].contains(provider) else { throw CocoaError(.coderReadCorrupt) }
        var account = row.filter { ["id", "provider", "name", "email", "plan", "identity", "knownValues"].contains($0.key) }
        account["requiresSignIn"] = true
        return account
    }
    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
    let preferenceURL = sourceContainer.appendingPathComponent("Preferences/com.pardeike.TokenCoffee.AccountProbe.plist")
    if manager.fileExists(atPath: preferenceURL.path) {
        let plist = try Data(contentsOf: preferenceURL)
        let values = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] ?? [:]
        let selected = values.filter { $0.key.hasPrefix("linkedDashboard.") || $0.key == "NSWindow Frame LinkedAccountManagement" }
        try PropertyListSerialization.data(fromPropertyList: selected, format: .binary, options: 0)
            .write(to: destination.appendingPathComponent("transferred-settings.plist"), options: .atomic)
    }
    let history = source.appendingPathComponent("diagram-history")
    for id in ids {
        let from = history.appendingPathComponent(id)
        let to = destination.appendingPathComponent("diagram-history/" + id)
        guard manager.fileExists(atPath: from.path) else { continue }
        try manager.createDirectory(at: to, withIntermediateDirectories: true)
        for file in try manager.contentsOfDirectory(at: from, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            let resource = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard resource.isRegularFile == true, resource.isSymbolicLink != true, file.pathExtension == "jsonl",
                  file.deletingPathExtension().lastPathComponent.allSatisfy({ $0.isHexDigit }),
                  file.deletingPathExtension().lastPathComponent.count == 64 else { continue }
            let target = to.appendingPathComponent(file.lastPathComponent)
            if !manager.fileExists(atPath: target.path) { try manager.copyItem(at: file, to: target) }
        }
    }
    // Registry last: an interrupted transfer can be resumed without replacing a
    // normal-app account or an already copied history file.
    try JSONSerialization.data(withJSONObject: ["accounts": accounts], options: [.sortedKeys])
        .write(to: accountFile, options: .atomic)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accountFile.path)
}

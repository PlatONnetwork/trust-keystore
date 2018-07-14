// Copyright © 2017-2018 Trust.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation
import TrustCore

/// Manages directories of key and wallet files and presents them as accounts.
public final class KeyStore {
    /// The key file directory.
    public let keyDirectory: URL

    /// List of wallets.
    public private(set) var wallets = [Wallet]()

    /// Creates a `KeyStore` for the given directory.
    public init(keyDirectory: URL) throws {
        self.keyDirectory = keyDirectory
        try load()
    }

    private func load() throws {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: keyDirectory, withIntermediateDirectories: true, attributes: nil)

        let accountURLs = try fileManager.contentsOfDirectory(at: keyDirectory, includingPropertiesForKeys: [], options: [.skipsHiddenFiles])
        for url in accountURLs {
            do {
                let key = try KeystoreKey(contentsOf: url)
                let wallet = Wallet(keyURL: url, key: key)
                for account in key.activeAccounts {
                    account.wallet = wallet
                    wallet.accounts.append(account)
                }
                wallets.append(wallet)
            } catch {
                // Ignore invalid keys
            }
        }
    }

    /// Creates a new wallet. HD default by default
    public func createWallet(password: String, derivationPaths: [DerivationPath]) throws -> Wallet {
        let key = try KeystoreKey(password: password)
        return try saveCreatedWallet(for: key, password: password, derivationPaths: derivationPaths)
    }

    /// Creates a new wallet. Private Key default by default
    public func createWallet(password: String, for blockchain: Blockchain) throws -> Wallet {
        let key = try KeystoreKey(password: password, for: blockchain)
        return try saveCreatedWallet(for: key, password: password, derivationPaths: [])
    }

    private func saveCreatedWallet(for key: KeystoreKey, password: String, derivationPaths: [DerivationPath]) throws -> Wallet {
        var newKey = key
        let url = makeAccountURL()
        let wallet = Wallet(keyURL: url, key: newKey)
        try save(wallet: wallet, in: keyDirectory)
        switch wallet.type {
        case .encryptedKey:
            let _ = try wallet.getAccount(password: password)
        case .hierarchicalDeterministicWallet:
            let _ = try wallet.getAccounts(derivationPaths: derivationPaths, password: password)
        }
        newKey.activeAccounts = wallet.accounts
        wallet.key = newKey
        wallets.append(wallet)
        return wallet
    }

    /// Adds accounts to a wallet.
    public func addAccounts(wallet: Wallet, derivationPaths: [DerivationPath], password: String) throws -> [Account] {
        let accounts = try wallet.getAccounts(derivationPaths: derivationPaths, password: password)
        try save(wallet: wallet, in: wallet.keyURL)
        return accounts
    }

    /// Imports an encrypted JSON key.
    ///
    /// - Parameters:
    ///   - key: key to import
    ///   - password: key password
    ///   - newPassword: password to use for the imported key
    /// - Returns: new account
    public func `import`(json: Data, password: String, newPassword: String, blockchain: Blockchain) throws -> Wallet {
        let key = try JSONDecoder().decode(KeystoreKey.self, from: json)

        var privateKeyData = try key.decrypt(password: password)
        defer {
            privateKeyData.clear()
        }
        guard let privateKey = PrivateKey(data: privateKeyData) else {
            throw Error.invalidKey
        }
        return try self.import(privateKey: privateKey, password: newPassword, blockchain: blockchain)
    }

    /// Imports a private key.
    ///
    /// - Parameters:
    ///   - privateKey: private key to import
    ///   - password: password to use for the imported private key
    /// - Returns: new wallet
    public func `import`(privateKey: PrivateKey, password: String, blockchain: Blockchain) throws -> Wallet {
        var newKey = try KeystoreKey(password: password, key: privateKey, blockchain: blockchain)
        let url = makeAccountURL()
        let wallet = Wallet(keyURL: url, key: newKey)
        let _ = try wallet.getAccount(password: password)
        newKey.activeAccounts = wallet.accounts
        wallet.key = newKey
        wallets.append(wallet)

        try save(wallet: wallet, in: keyDirectory)

        return wallet
    }

    /// Imports a wallet.
    ///
    /// - Parameters:
    ///   - mnemonic: wallet's mnemonic phrase
    ///   - passphrase: wallet's password
    ///   - encryptPassword: password to use for encrypting
    /// - Returns: new account
    public func `import`(mnemonic: String, passphrase: String = "", encryptPassword: String, derivationPath: DerivationPath) throws -> Wallet {
        if !Crypto.isValid(mnemonic: mnemonic) {
            throw Error.invalidMnemonic
        }

        var newKey = try KeystoreKey(password: encryptPassword, mnemonic: mnemonic, passphrase: passphrase)
        let url = makeAccountURL()
        let wallet = Wallet(keyURL: url, key: newKey)
        let _ = try wallet.getAccounts(derivationPaths: [derivationPath], password: encryptPassword)
        newKey.activeAccounts = wallet.accounts
        wallet.key = newKey
        wallets.append(wallet)

        try save(wallet: wallet, in: keyDirectory)

        return wallet
    }

    /// Exports a wallet as JSON data.
    ///
    /// - Parameters:
    ///   - wallet: wallet to export
    ///   - password: account password
    ///   - newPassword: password to use for exported key
    /// - Returns: encrypted JSON key
    public func export(wallet: Wallet, password: String, newPassword: String) throws -> Data {
        var privateKeyData = try wallet.key.decrypt(password: password)
        defer {
            privateKeyData.resetBytes(in: 0 ..< privateKeyData.count)
        }

        let newKey: KeystoreKey
        switch wallet.key.type {
        case .encryptedKey:
            guard let privateKey = PrivateKey(data: privateKeyData) else {
                throw Error.invalidKey
            }
            let blockchain = wallet.key.blockchain ?? .ethereum //Default

            newKey = try KeystoreKey(password: newPassword, key: privateKey, blockchain: blockchain)
        case .hierarchicalDeterministicWallet:
            guard let string = String(data: privateKeyData, encoding: .ascii) else {
                throw EncryptError.invalidMnemonic
            }
            newKey = try KeystoreKey(password: newPassword, mnemonic: string, passphrase: wallet.key.passphrase)
        }
        return try JSONEncoder().encode(newKey)
    }

    /// Exports a wallet as private key data.
    ///
    /// - Parameters:
    ///   - wallet: wallet to export
    ///   - password: account password
    /// - Returns: private key data for encrypted keys or menmonic phrase for HD wallets
    public func exportPrivateKey(wallet: Wallet, password: String) throws -> Data {
        return try wallet.key.decrypt(password: password)
    }

    /// Exports a wallet as a mnemonic phrase.
    ///
    /// - Parameters:
    ///   - wallet: wallet to export
    ///   - password: account password
    /// - Returns: mnemonic phrase
    /// - Throws: `EncryptError.invalidMnemonic` if the account is not an HD wallet.
    public func exportMnemonic(wallet: Wallet, password: String) throws -> String {
        var data = try wallet.key.decrypt(password: password)
        defer {
            data.resetBytes(in: 0 ..< data.count)
        }

        switch wallet.key.type {
        case .encryptedKey:
            throw EncryptError.invalidMnemonic
        case .hierarchicalDeterministicWallet:
            guard let string = String(data: data, encoding: .ascii) else {
                throw EncryptError.invalidMnemonic
            }
            if string.hasSuffix("\0") {
                return String(string.dropLast())
            } else {
                return string
            }
        }
    }

    /// Updates the password of an existing account.
    ///
    /// - Parameters:
    ///   - wallet: wallet to update
    ///   - password: current password
    ///   - newPassword: new password
    public func update(wallet: Wallet, password: String, newPassword: String) throws {
        guard let index = wallets.index(of: wallet) else {
            fatalError("Missing wallet")
        }

        var privateKeyData = try wallet.key.decrypt(password: password)
        defer {
            privateKeyData.resetBytes(in: 0 ..< privateKeyData.count)
        }

        switch wallet.key.type {
        case .encryptedKey:
            guard let privateKey = PrivateKey(data: privateKeyData) else {
                throw Error.invalidKey
            }
            let blockchain = wallet.key.blockchain ?? .ethereum //Default
            wallets[index].key = try KeystoreKey(password: newPassword, key: privateKey, blockchain: blockchain)
        case .hierarchicalDeterministicWallet:
            guard let string = String(data: privateKeyData, encoding: .ascii) else {
                throw EncryptError.invalidMnemonic
            }
            wallets[index].key = try KeystoreKey(password: newPassword, mnemonic: string, passphrase: wallet.key.passphrase)
        }
    }

    /// Deletes an account including its key if the password is correct.
    public func delete(wallet: Wallet, password: String) throws {
        guard let index = wallets.index(of: wallet) else {
            fatalError("Missing wallet")
        }

        var privateKey = try wallet.key.decrypt(password: password)
        defer {
            privateKey.resetBytes(in: 0..<privateKey.count)
        }
        wallets.remove(at: index)

        try FileManager.default.removeItem(at: wallet.keyURL)
    }

    // MARK: Helpers

    private func makeAccountURL(for address: Address) -> URL {
        return keyDirectory.appendingPathComponent(generateFileName(identifier: address.data.hexString))
    }

    private func makeAccountURL() -> URL {
        return keyDirectory.appendingPathComponent(generateFileName(identifier: UUID().uuidString))
    }

    /// Saves the account to the given directory.
    private func save(wallet: Wallet, in directory: URL) throws {
        try save(key: wallet.key, to: wallet.keyURL)
    }

    /// Generates a unique file name for an address.
    func generateFileName(identifier: String, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        // keyFileName implements the naming convention for keyfiles:
        // UTC--<created_at UTC ISO8601>-<address hex>
        return "UTC--\(filenameTimestamp(for: date, in: timeZone))--\(identifier)"
    }

    private func filenameTimestamp(for date: Date, in timeZone: TimeZone = .current) -> String {
        var tz = ""
        let offset = timeZone.secondsFromGMT()
        if offset == 0 {
            tz = "Z"
        } else {
            tz = String(format: "%03d00", offset/60)
        }

        let components = Calendar(identifier: .iso8601).dateComponents(in: timeZone, from: date)
        return String(format: "%04d-%02d-%02dT%02d-%02d-%02d.%09d%@", components.year!, components.month!, components.day!, components.hour!, components.minute!, components.second!, components.nanosecond!, tz)
    }

    private func save(key: KeystoreKey, to url: URL) throws {
        let json = try JSONEncoder().encode(key)
        try json.write(to: url, options: [.atomicWrite])
    }
}

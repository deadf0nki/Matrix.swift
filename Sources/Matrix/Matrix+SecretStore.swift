//
//  File.swift
//  
//
//  Created by Charles Wright on 5/3/23.
//

import Foundation
import MatrixSDKCrypto
import os

import CryptoKit
import IDZSwiftCommonCrypto

import LocalAuthentication
import KeychainAccess

extension Matrix {
    
    public class KeychainSecretStore {
        let userId: UserId
        private var keychain: Keychain
        private var logger: os.Logger
        
        public init(userId: UserId) {
            self.userId = userId
            self.keychain = Keychain(service: "matrix", accessGroup: userId.stringValue)
            self.logger = .init(subsystem: "matrix", category: "keychain")
        }
        
        public func loadKey(keyId: String, reason: String) async throws -> Data? {
            logger.debug("Attempting to load key with keyId \(keyId)")
            // https://developer.apple.com/documentation/security/keychain_services/keychain_items/searching_for_keychain_items
            // https://github.com/kishikawakatsumi/KeychainAccess#closed_lock_with_key-obtaining-a-touch-id-face-id-protected-item
            // Ensure this runs on a background thread - Otherwise if we try to authenticate to the keychain from the main thread, the app will lock up
            let t = Task(priority: .background) {
                var context = LAContext()
                context.touchIDAuthenticationAllowableReuseDuration = 60.0
                guard let data = try? keychain
                    .accessibility(.whenUnlockedThisDeviceOnly, authenticationPolicy: .userPresence)
                    .authenticationContext(context)
                    .authenticationPrompt(reason)
                    .getData(keyId)
                else {
                    self.logger.debug("Failed to get key data from keychain")
                    throw Matrix.Error("Failed to get key data from keychain")
                }
                self.logger.debug("Got \(data.count) bytes of data from the keychain")
                return data
            }
            return try await t.value
        }
        
        public func saveKey(key: Data, keyId: String) async throws {
            logger.debug("Attempting to save key with keyId \(keyId)")
            // https://github.com/kishikawakatsumi/KeychainAccess#closed_lock_with_key-updating-a-touch-id-face-id-protected-item
            // Ensure this runs on a background thread - Otherwise if we try to authenticate to the keychain from the main thread, the app will lock up
            let t = Task(priority: .background) {
                var context = LAContext()
                context.touchIDAuthenticationAllowableReuseDuration = 60.0
                self.logger.debug("Got context.  Attempting to save keyId \(keyId)")
                try keychain
                    .accessibility(.whenUnlockedThisDeviceOnly, authenticationPolicy: .userPresence)
                    .authenticationContext(context)
                    .set(key, key: keyId)
                self.logger.debug("Success saving keyId \(keyId)")
            }
            try await t.value
        }
    }
    
    // https://spec.matrix.org/v1.6/client-server-api/#storage
    public class SecretStore {
        
        public enum State {
            case uninitialized
            case needKey(KeyDescriptionContent)
            case online(String)
            case error(String)
        }
        
        // https://spec.matrix.org/v1.6/client-server-api/#secret-storage
        public struct EncryptedData: Codable {
            public var iv: String
            public var ciphertext: String
            public var mac: String
        }

        public struct Secret: Codable {
            public var encrypted: [String: EncryptedData]
        }
        
        public var state: State
        private var session: Session
        private var logger: os.Logger
        private var keychain: KeychainSecretStore
        var keys: [String: Data]
    
        public init(session: Session, defaultKey: Data, defaultKeyId: String) async throws {
            self.session = session
            self.logger = .init(subsystem: "matrix", category: "SSSS")
            self.keys = [defaultKeyId : defaultKey]
            self.keychain = KeychainSecretStore(userId: session.creds.userId)
            self.state = .online(defaultKeyId)
            
            logger.debug("Initializing with default key")
            
            // Make sure that our default key is registered with the server-side secret storage
            if let oldDefaultKeyId = try await getDefaultKeyId() {
                logger.debug("Found existing default keyId [\(oldDefaultKeyId)]")
                if oldDefaultKeyId != defaultKeyId {
                    logger.debug("Overwriting old default keyId [\(oldDefaultKeyId)] with new default keyId [\(defaultKeyId)]")
                    try await registerKey(key: defaultKey, keyId: defaultKeyId)
                    try await setDefaultKeyId(keyId: defaultKeyId)
                    
                    // FIXME: Also encrypt the old key under the new key, and (maybe?) vice versa
                    
                } else {
                    logger.debug("Existing default keyId matches what we have [\(defaultKeyId)]")
                }
            } else {
                logger.debug("No existing keyId; Uploading our new one")
                try await registerKey(key: defaultKey, keyId: defaultKeyId)
                try await setDefaultKeyId(keyId: defaultKeyId)
            }
            
            logger.debug("Done with init")
        }
        
        public init(session: Session, keys: [String: Data]) async throws {
            self.session = session
            self.logger = .init(subsystem: "matrix", category: "SSSS")
            self.keys = keys
            self.keychain = KeychainSecretStore(userId: session.creds.userId)
            self.state = .uninitialized
            
            logger.debug("Initializing with a set of keys")
            
            // OK now let's see what we got
            // 1. Do we have the default key?
            //    a. Is it in the `keys` that we were init'ed with?
            //    b. Is it in our Keychain?
            //    c. Do we need to prompt the user for the passphrase?
            
            // First we need to connect to the server's account data and get the default key info
            // (If there is no default key, then we must remain in state `.uninitialized` and we are done here.)
            guard let defaultKeyId = try await getDefaultKeyId()
            else {
                logger.warning("No default keyId for SSSS")
                return
            }
            
            // Next, once we know the id of the default key, we look to see if we already have it in our `keys` dictionary
            // - If we have the default key, then we are in state `.online(keyId)` where `keyId` is the id of our default key
            if let key = keys[defaultKeyId] {
                logger.debug("SSSS is online with key [\(defaultKeyId)]")
                self.state = .online(defaultKeyId)
                return
            } else {
                logger.debug("Can't find the actual key for keyId [\(defaultKeyId)]")
            }
            
            logger.debug("Looking in Keychain for key with keyId \(defaultKeyId)")
            // If the key isn't already loaded in memory, then maybe we have previously saved it in the Keychain
            // - If we have the default key, then we are in state `.online(keyId)` where `keyId` is the id of our default key
            let keychain = KeychainSecretStore(userId: session.creds.userId)
            if let key = try await keychain.loadKey(keyId: defaultKeyId, reason: "The app needs to load cryptographic keys for your account") {
                logger.debug("Found key \(defaultKeyId) in the Keychain")
                self.state = .online(defaultKeyId)
                return
            } else {
                logger.debug("Failed to load key \(defaultKeyId) from the Keychain ")
            }

            // If we don't have the default key, then there's not much that we can do.
            logger.debug("Failed to load default SSSS key with keyId \(defaultKeyId)")
            // Set `state` to `.needKey` with the default key's description, so that the application can prompt the user
            // to provide a passphrase.
            logger.debug("Fetching key description")
            if let description = try await getKeyDescription(keyId: defaultKeyId) {
                logger.debug("Setting state to .needKey")
                self.state = .needKey(description)
            }
            
            logger.debug("Done with init")
        }
        
        public static func computeKeyId(key: Data) throws -> String {
            // First compute the SHA256 hash of the key
            guard let hash = Digest(algorithm: .sha256).update(data: key)?.final()
            else {
                throw Matrix.Error("Failed to compute SHA256 hash on \(key.count) bytes")
            }
            // Then take the first 12 bytes (96 bits) of the hash and convert to base64
            let keyId = Data(hash[0..<12]).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
            return keyId
        }
        
        func encrypt(name: String,
                     data: Data,
                     key: Data
        ) throws -> EncryptedData {
            logger.debug("Encrypting \(name)")
            // Keygen - Use HKDF to derive encryption key and MAC key from master key
            let salt = Array<UInt8>(repeating: 0, count: 32)
                        
            let hac: HashedAuthenticationCode = HKDF<CryptoKit.SHA256>.extract(inputKeyMaterial: SymmetricKey(data: key), salt: salt)
            let keyMaterial = HKDF<CryptoKit.SHA256>.expand(pseudoRandomKey: hac, info: name.data(using: .utf8), outputByteCount: 64)
            
            let (encryptionKey, macKey) = keyMaterial.withUnsafeBytes { bytes in
                let kE = Array(bytes[0..<32])
                let kM = Array(bytes[32..<64])
                return (kE, kM)
            }
            //logger.debug("Encryption key = \(Data(encryptionKey).base64EncodedString())")
            //logger.debug("MAC key        = \(Data(macKey).base64EncodedString())")
            
            // Generate random IV
            let iv = try Random.generateBytes(byteCount: 16)
            
            // Encrypt data with encryption key and IV to create ciphertext
            let cryptor = Cryptor(operation: .encrypt,
                                  algorithm: .aes,
                                  mode: .CTR,
                                  padding: .NoPadding,
                                  key: encryptionKey,
                                  iv: iv
            )
            
            guard let ciphertext = cryptor.update(data)?.final()
            else {
                logger.error("Failed to encrypt")
                throw Matrix.Error("Failed to encrypt")
            }
            
            // MAC ciphertext with MAC key
            guard let mac = HMAC(algorithm: .sha256, key: macKey).update(ciphertext)?.final()
            else {
                logger.error("Couldn't compute HMAC")
                throw Matrix.Error("Couldn't compute HMAC")
            }
            
            let encrypted = EncryptedData(iv: Data(iv).base64EncodedString(),
                                          ciphertext: Data(ciphertext).base64EncodedString(),
                                          mac: Data(mac).base64EncodedString())
            
            /*
            // TEST: Can we decrypt what we just encrypted???
            if let decrypted = try? decrypt(name: name, encrypted: encrypted, key: key) {
                logger.debug("Test decryption succeeded")
                if decrypted == data {
                    logger.debug("Data decrypted successfully!")
                } else {
                    logger.error("Failed to decrypt correctly!")
                }
            } else {
                logger.error("Test decryption failed!")
            }
            */
            
            return encrypted
        }
        
        func decrypt(name: String,
                     encrypted: EncryptedData,
                     key: Data
        ) throws -> Data {
            logger.debug("Decrypting \(name)")
            
            guard let iv = Data(base64Encoded: encrypted.iv),
                  let ciphertext = Data(base64Encoded: encrypted.ciphertext),
                  let mac = Data(base64Encoded: encrypted.mac)
            else {
                throw Matrix.Error("Couldn't parse encrypted data")
            }
            
            // Keygen
            let salt = Array<UInt8>(repeating: 0, count: 32)
                        
            let hac: HashedAuthenticationCode = HKDF<CryptoKit.SHA256>.extract(inputKeyMaterial: SymmetricKey(data: key), salt: salt)
            let keyMaterial = HKDF<CryptoKit.SHA256>.expand(pseudoRandomKey: hac, info: name.data(using: .utf8), outputByteCount: 64)
            
            let (encryptionKey, macKey) = keyMaterial.withUnsafeBytes { bytes in
                let kE = Array(bytes[0..<32])
                let kM = Array(bytes[32..<64])
                return (kE, kM)
            }
            //logger.debug("Encryption key = \(Data(encryptionKey).base64EncodedString())")
            //logger.debug("MAC key        = \(Data(macKey).base64EncodedString())")
            
            // Cryptographic Doom Principle: Always check the MAC first!
            let storedMAC = [UInt8](mac)  // convert from Data
            guard let computedMAC = HMAC(algorithm: .sha256, key: macKey).update(ciphertext)?.final()
            else {
                logger.error("Couldn't compute HMAC")
                throw Matrix.Error("Couldn't compute HMAC")
            }
            
            guard storedMAC.count == computedMAC.count
            else {
                logger.error("MAC doesn't match (\(storedMAC.count) bytes vs \(computedMAC.count) bytes)")
                throw Matrix.Error("MAC doesn't match")
            }
            
            var macIsValid = true
            // Compare the MACs -- Constant time comparison
            for i in storedMAC.indices {
                if storedMAC[i] != computedMAC[i] {
                    macIsValid = false
                }
            }
            
            guard macIsValid
            else {
                let stored = Data(storedMAC).base64EncodedString()
                let computed = Data(computedMAC).base64EncodedString()
                logger.error("MAC doesn't match (\(stored) vs \(computed)")
                throw Matrix.Error("MAC doesn't match")
            }
            
            // Whew now we finally know it's safe to decrypt
            
            let cryptor = Cryptor(operation: .decrypt,
                                  algorithm: .aes,
                                  mode: .CTR,
                                  padding: .NoPadding,
                                  key: encryptionKey,
                                  iv: [UInt8](iv)
            )
            
            guard let decryptedBytes = cryptor.update(ciphertext)?.final()
            else {
                logger.error("Failed to decrypt ciphertext")
                throw Matrix.Error("Failed to decrypt ciphertext")
            }
            
            return Data(decryptedBytes)
        }
            
        public func getSecret<T: Codable>(type: String) async throws -> T? {
            
            logger.debug("Attempting to get secret for type [\(type)]")
            
            guard let secret = try await session.getAccountData(for: type, of: Secret.self)
            else {
                // Couldn't download the account data ==> Don't have this secret
                logger.debug("Could not download account data for type [\(type)]")
                return nil
            }

            // Now we have the encrypted secret downloaded
            // Look at all of the encryptions, and see if there's one where we know the key -- or where we can get the key
            for (keyId, encryptedData) in secret.encrypted {
                guard let key = self.keys[keyId]
                else {
                    logger.warning("Couldn't get key for id \(keyId)")
                    continue
                }
                logger.debug("Got key and description for key id [\(keyId)]")
                
                let decryptedData = try decrypt(name: type, encrypted: encryptedData, key: key)
                logger.debug("Successfully decrypted data for secret [\(type)]")
                
                let decoder = JSONDecoder()
                if let object = try? decoder.decode(T.self, from: decryptedData) {
                    logger.debug("Successfully decoded object of type [\(T.self)]")
                    return object
                }
            }
            logger.warning("Couldn't find a key to decrypt secret [\(type)]")
            return nil
        }
        
        public func saveSecret<T: Codable>(_ content: T, type: String) async throws {
            logger.debug("Saving secret of type [\(type)]")
            
            guard case let .online(keyId) = self.state
            else {
                logger.error("Can't save secrets until secret storage is online with decryption key")
                throw Matrix.Error("Can't save secrets until secret storage is online with decryption key")
            }
            
            guard let key = self.keys[keyId]
            else {
                logger.error("Could not find encryption key with id [\(keyId)]")
                throw Matrix.Error("Could not find encryption key with id [\(keyId)]")
            }
            
            // Do we already have encrypted version(s) of this secret?
            // FIXME: Whooooooaaaaaa - Hold on a minute
            // We have NO WAY to know whether the old value is the same as the new one!
            // What should we do here?!?
            let existingSecret = try await session.getAccountData(for: type, of: Secret.self)
            var secret = existingSecret ?? Secret(encrypted: [:])
            
            let encoder = JSONEncoder()
            let data = try encoder.encode(content)
            let encryptedData = try encrypt(name: type, data: data, key: key)
            
            // Add our encryption to whatever was there before, overwriting any previous encryption to this key
            secret.encrypted[keyId] = encryptedData
            
            // Upload the EncryptedData object to SSSS
            try await session.putAccountData(secret, for: type)
        }
        
        public func getKeyDescription(keyId: String) async throws -> KeyDescriptionContent? {
            logger.debug("Fetching key description for keyId [\(keyId)]")
            return try await session.getAccountData(for: "m.secret_storage.key.\(keyId)", of: KeyDescriptionContent.self)
        }

        public func registerKey(key: Data,
                                keyId: String,
                                name: String? = nil,
                                passphrase: KeyDescriptionContent.Passphrase? = nil
        ) async throws {
            logger.debug("Registering new key with keyId [\(keyId)]")
            
            let algorithm: String = M_SECRET_STORAGE_V1_AES_HMAC_SHA2
            let zeroes = [UInt8](repeating: 0, count: 32)
            let encrypted = try encrypt(name: "", data: Data(zeroes), key: key)
            let iv = encrypted.iv
            let mac = encrypted.mac
            
            let content = KeyDescriptionContent(name: name, algorithm: algorithm, passphrase: passphrase, iv: iv, mac: mac)
            let type = "m.secret_storage.key.\(keyId)"
            
            try await session.putAccountData(content, for: type)
        }
        
        public func validateKey(key: Data,
                                keyId: String
        ) async throws -> Bool {
            logger.debug("Validating key with keyId [\(keyId)]")
            
            guard let description = try await getKeyDescription(keyId: keyId),
                  let oldIV = description.iv,
                  let oldMacString = description.mac,
                  let oldMacData = Data(base64Encoded: oldMacString),
                  let iv = Data(base64Encoded: oldIV)
            else { return false }
            
            // Keygen - Use HKDF to derive encryption key and MAC key from master key
            let salt = Array<UInt8>(repeating: 0, count: 32)
                        
            let hac: HashedAuthenticationCode = HKDF<CryptoKit.SHA256>.extract(inputKeyMaterial: SymmetricKey(data: key), salt: salt)
            let keyMaterial = HKDF<CryptoKit.SHA256>.expand(pseudoRandomKey: hac, info: "".data(using: .utf8), outputByteCount: 64)
            
            let (encryptionKey, macKey) = keyMaterial.withUnsafeBytes { bytes in
                let kE = Array(bytes[0..<32])
                let kM = Array(bytes[32..<64])
                return (kE, kM)
            }
            
            let zeroes = [UInt8](repeating: 0, count: 32)
         
            // Encrypt data with encryption key and IV to create ciphertext
            let cryptor = Cryptor(operation: .encrypt,
                                  algorithm: .aes,
                                  mode: .CTR,
                                  padding: .NoPadding,
                                  key: encryptionKey,
                                  iv: [UInt8](iv)
            )
            
            guard let ciphertext = cryptor.update(zeroes)?.final()
            else {
                logger.error("Failed to encrypt")
                throw Matrix.Error("Failed to encrypt")
            }
            
            // MAC ciphertext with MAC key
            guard let mac = HMAC(algorithm: .sha256, key: macKey).update(ciphertext)?.final()
            else {
                logger.error("Couldn't compute HMAC")
                throw Matrix.Error("Couldn't compute HMAC")
            }
            
            // Now validate the new MAC vs the old MAC
            let oldMac = [UInt8](oldMacData)
            // First quick check - Are they the same length?
            guard mac.count == oldMac.count
            else {
                return false
            }
            
            // Compare the MACs -- Constant time comparison
            var macIsValid = true
            for i in oldMac.indices {
                if mac[i] != oldMac[i] {
                    macIsValid = false
                }
            }
            
            guard macIsValid
            else {
                let old = Data(oldMac).base64EncodedString()
                let new = Data(mac).base64EncodedString()
                logger.warning("MAC doesn't match - \(old) vs \(new)")
                return false
            }
            
            // If we're still here, then everything must have matched.  We're good!
            return true
        }
        
        public func setDefaultKeyId(keyId: String) async throws {
            logger.debug("Setting keyId [\(keyId)] to be the default SSSS key")
            let content = DefaultKeyContent(key: keyId)
            let type = M_SECRET_STORAGE_DEFAULT_KEY
            
            try await session.putAccountData(content, for: type)
        }
        
        public func getDefaultKeyId() async throws -> String? {
            logger.debug("Getting default keyId")
            guard let content = try await session.getAccountData(for: M_SECRET_STORAGE_DEFAULT_KEY, of: DefaultKeyContent.self)
            else {
                logger.error("Couldn't find a default keyId")
                return nil
            }

            logger.debug("Found default keyId \(content.key)`")
            return content.key
        }
    }
}
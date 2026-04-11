import Foundation
import Sodium

enum NativeCrypto {
    struct DecryptionResult {
        let text: String
    }

    private static func roomPrivateKey(roomId: Int) -> String? {
        guard roomId > 0 else { return nil }
        guard let keysJSON = SafeStorageStore.get("roomDecryptedKeys"),
              let data = keysJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let roomObj = json["\(roomId)"] as? [String: Any],
              let priv = roomObj["privateKey"] as? String,
              !priv.isEmpty else {
            return nil
        }
        return priv
    }

    private static func userPrivateKey(userId: Int) -> String? {
        guard userId > 0 else { return nil }
        guard let keysJSON = SafeStorageStore.get("memberDecryptedKeys"),
              let data = keysJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let userObj = json["\(userId)"] as? [String: Any],
              let priv = userObj["privateKey"] as? String,
              !priv.isEmpty else {
            return nil
        }
        return priv
    }

    static func decryptRoomData(roomId: Int, encryptedJSON: String) throws -> DecryptionResult {
        guard let priv = roomPrivateKey(roomId: roomId) else {
            throw NSError(domain: "NativeCrypto", code: 1, userInfo: [NSLocalizedDescriptionKey: "No private key for room \(roomId)"])
        }
        return try decryptInternal(encryptedJSON: encryptedJSON, recipientPrivB64: priv)
    }

    static func decryptUserData(userId: Int, encryptedJSON: String) throws -> DecryptionResult {
        guard let priv = userPrivateKey(userId: userId) else {
            throw NSError(domain: "NativeCrypto", code: 2, userInfo: [NSLocalizedDescriptionKey: "No private key for user \(userId)"])
        }
        return try decryptInternal(encryptedJSON: encryptedJSON, recipientPrivB64: priv)
    }

    private static func decryptInternal(encryptedJSON: String, recipientPrivB64: String) throws -> DecryptionResult {
        guard let objData = encryptedJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: objData, options: []) as? [String: Any],
              let encryptedB64 = json["encryptedMessage"] as? String,
              let nonceB64 = json["nonce"] as? String,
              let ephPubB64 = json["ephPublicKey"] as? String,
              let encrypted = Data(base64Encoded: encryptedB64),
              let nonce = Data(base64Encoded: nonceB64),
              let ephPub = Data(base64Encoded: ephPubB64),
              let recipientPriv = Data(base64Encoded: recipientPrivB64) else {
            throw NSError(domain: "NativeCrypto", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid encrypted JSON"])
        }

        let sodium = Sodium()
        let ephPubBytes = [UInt8](ephPub)
        let recipientPrivBytes = [UInt8](recipientPriv)

        guard let shared = sodium.box.beforenm(recipientPublicKey: ephPubBytes, senderSecretKey: recipientPrivBytes) else {
            throw NSError(domain: "NativeCrypto", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to derive shared key"])
        }

        let nonceBytes = [UInt8](nonce)
        let cipherBytes = [UInt8](encrypted)

        guard let decrypted = sodium.secretBox.open(authenticatedCipherText: cipherBytes, secretKey: shared, nonce: nonceBytes) else {
            throw NSError(domain: "NativeCrypto", code: 5, userInfo: [NSLocalizedDescriptionKey: "Decryption failed"])
        }

        let text = String(bytes: decrypted, encoding: .utf8) ?? ""
        return DecryptionResult(text: text)
    }
}


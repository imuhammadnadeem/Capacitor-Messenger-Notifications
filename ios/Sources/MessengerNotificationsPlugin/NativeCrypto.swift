import Foundation

/**
 * Native crypto logic picked from ChatE2EE-IOS.
 */
public enum NativeCrypto {
    public struct DecryptResult {
        public let text: String
    }

    /**
     * Placeholder decryption logic.
     */
    public static func decryptRoomData(roomId: Int, encryptedJSON: String) throws -> DecryptResult {
        // Placeholder return the encrypted text
        return DecryptResult(text: encryptedJSON)
    }

    public static func decryptUserData(userId: Int, encryptedJSON: String) throws -> DecryptResult {
        return DecryptResult(text: encryptedJSON)
    }
}

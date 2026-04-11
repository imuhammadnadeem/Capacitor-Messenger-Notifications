package com.codecraft_studio.messenger.notifications;

import android.content.Context;
import android.content.SharedPreferences;
import com.getcapacitor.JSObject;

import org.libsodium.jni.NaCl;
import org.libsodium.jni.Sodium;
import java.util.Base64;
import org.json.JSONObject;

public class NativeCrypto {
    static { NaCl.sodium(); }

    private final Context context;

    // Constructor to receive context for SharedPreferences access
    public NativeCrypto(Context context) {
        this.context = context;
    }

    /**
     * Decrypts data for a specific room by fetching the key from SharedPreferences
     * @param roomId The ID used to look up the private key
     * @param encryptedJSON The JSON string containing encryptedMessage, nonce, and ephPublicKey
     * @return JSObject containing the decrypted text
     */
    public JSObject decryptRoomData(int roomId, String encryptedJSON) throws Exception {
        // 1. Fetch key from SharedPreferences
        String recipientPrivB64 = getRoomPrivateKey(roomId);

        if (recipientPrivB64 == null) {
            throw new Exception("No private key found for room ID: " + roomId);
        }

        // 2. Perform Decryption
        return decryptDataInternal(encryptedJSON, recipientPrivB64);
    }

    public JSObject decryptUserData(int userId, String encryptedJSON) throws Exception {
        // 1. Fetch key from SharedPreferences
        String recipientPrivB64 = getUserPrivateKey(userId);

        if (recipientPrivB64 == null) {
            throw new Exception("No private key found for user ID: " + userId);
        }

        // 2. Perform Decryption
        return decryptDataInternal(encryptedJSON, recipientPrivB64);
    }

    private String getRoomPrivateKey(int roomId) {
        try {
            SharedPreferences prefs = context.getSharedPreferences("safe_storage", Context.MODE_PRIVATE);
            String keysJSON = prefs.getString("roomDecryptedKeys", null);

            if (keysJSON == null) {
                return null;
            }

            // Parse the main JSON object
            JSONObject allKeys = new JSONObject(keysJSON);

            // Check if the roomId exists as a key in the JSON object
            // Note: JSON keys are strings, so we convert roomId to String
            if (!allKeys.has(String.valueOf(roomId))) {
                return null;
            }

            // Fetch the room-specific object
            JSONObject roomKeyPair = allKeys.getJSONObject(String.valueOf(roomId));

            // Return the privateKey value from the obtained keypair object
            return roomKeyPair.optString("privateKey", null);

        } catch (Exception e) {
            e.printStackTrace();
            return null;
        }
    }

    private String getUserPrivateKey(int userId) {
        try {
            SharedPreferences prefs = context.getSharedPreferences("safe_storage", Context.MODE_PRIVATE);
            String keysJSON = prefs.getString("memberDecryptedKeys", null);

            if (keysJSON == null) {
                return null;
            }

            // Parse the main JSON object
            JSONObject allKeys = new JSONObject(keysJSON);

            // Check if the roomId exists as a key in the JSON object
            // Note: JSON keys are strings, so we convert roomId to String
            if (!allKeys.has(String.valueOf(userId))) {
                return null;
            }

            // Fetch the room-specific object
            JSONObject userKeyPair = allKeys.getJSONObject(String.valueOf(userId));

            // Return the privateKey value from the obtained keypair object
            return userKeyPair.optString("privateKey", null);

        } catch (Exception e) {
            e.printStackTrace();
            return null;
        }
    }

    /**
     * Shared decryption logic
     */
    private JSObject decryptDataInternal(String encryptedJSON, String recipientPrivB64) throws Exception {
        JSONObject obj = new JSONObject(encryptedJSON);
        byte[] encrypted = Base64.getDecoder().decode(obj.getString("encryptedMessage"));
        byte[] nonce = Base64.getDecoder().decode(obj.getString("nonce"));
        byte[] ephPub = Base64.getDecoder().decode(obj.getString("ephPublicKey"));
        byte[] recipientPriv = Base64.getDecoder().decode(recipientPrivB64);

        byte[] shared = new byte[32];
        Sodium.crypto_box_beforenm(shared, ephPub, recipientPriv);

        byte[] decrypted = new byte[encrypted.length - 16];
        int success = Sodium.crypto_secretbox_open_easy(decrypted, encrypted, encrypted.length, nonce, shared);

        if (success != 0) throw new Exception("Decryption failed");

        JSObject result = new JSObject();
        result.put("text", new String(decrypted, "UTF-8"));
        return result;
    }

    // Static helper kept for backward compatibility if needed elsewhere
    public static JSObject decryptDataStatic(JSObject call) throws Exception {
        String encryptedJSON = call.getString("encryptedJSON");
        String recipientPrivB64 = call.getString("recipientPrivateKey");

        // We can't use 'this' in static, so we call a static version or replicate logic
        // For simplicity in this file, we keep the static logic separate or create a temporary instance
        NativeCrypto temp = new NativeCrypto(null);
        return temp.decryptDataInternal(encryptedJSON, recipientPrivB64);
    }
}
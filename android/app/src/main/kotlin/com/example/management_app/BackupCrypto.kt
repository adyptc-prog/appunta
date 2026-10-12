package com.example.management_app

import org.json.JSONObject
import java.security.SecureRandom
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.io.encoding.Base64

/**
 * Criptarea fișierelor de backup (.orgbackup v2) — logică pură, testabilă pe
 * JVM. Backup-ul conține numele și telefoanele clienților și ajunge pe stick
 * sau în Documents, deci nu stă în clar.
 *
 *   {
 *     "app": "organizator",
 *     "formatVersion": 2,
 *     "createdAt": <epoch ms>,
 *     "kdf": { "alg": "PBKDF2-HMAC-SHA256", "iterations": n, "salt": b64 },
 *     "cipher": { "alg": "AES-256-GCM", "iv": b64 },
 *     "payload": b64(AES-GCM(backup v1 complet, ca text))
 *   }
 *
 * Tag-ul GCM garantează și integritatea: un fișier modificat sau o parolă
 * greșită dau aceeași eroare (nu se poate deosebi una de alta).
 */
object BackupCrypto {

    const val FORMAT_VERSION = 2
    const val MIN_PASSWORD_LENGTH = 8
    const val DEFAULT_ITERATIONS = 120_000

    private const val KEY_BYTES = 32
    private const val SALT_BYTES = 16
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128
    private val AAD = "organizator-backup-v2".toByteArray(Charsets.UTF_8)

    class WrongPasswordException :
        Exception(tr("Parolă greșită sau fișier modificat.", "Wrong password or modified file."))

    fun isValidPassword(password: String?): Boolean =
        password != null && password.length >= MIN_PASSWORD_LENGTH

    fun isEncrypted(content: String): Boolean = try {
        JSONObject(content).optInt("formatVersion", -1) == FORMAT_VERSION
    } catch (_: Exception) {
        false
    }

    fun encrypt(
        plain: String,
        password: String,
        createdAt: Long,
        iterations: Int = DEFAULT_ITERATIONS,
        random: SecureRandom = SecureRandom(),
    ): String {
        require(isValidPassword(password)) {
            tr(
                "Parola trebuie să aibă minim $MIN_PASSWORD_LENGTH caractere.",
                "The password must have at least $MIN_PASSWORD_LENGTH characters.",
            )
        }
        val salt = ByteArray(SALT_BYTES).also(random::nextBytes)
        val iv = ByteArray(IV_BYTES).also(random::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(pbkdf2Sha256(password, salt, iterations, KEY_BYTES), "AES"),
            GCMParameterSpec(TAG_BITS, iv),
        )
        cipher.updateAAD(AAD)
        val encrypted = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return JSONObject()
            .put("app", BackupFormat.APP_ID)
            .put("formatVersion", FORMAT_VERSION)
            .put("createdAt", createdAt)
            .put("kdf", JSONObject()
                .put("alg", "PBKDF2-HMAC-SHA256")
                .put("iterations", iterations)
                .put("salt", Base64.encode(salt)))
            .put("cipher", JSONObject()
                .put("alg", "AES-256-GCM")
                .put("iv", Base64.encode(iv)))
            .put("payload", Base64.encode(encrypted))
            .toString()
    }

    /** Textul backup-ului v1 din interior; [WrongPasswordException] la parolă greșită. */
    fun decrypt(content: String, password: String): String {
        val invalid = BackupFormat.InvalidBackupException(tr("Fișierul nu este un backup Organizator valid.", "The file is not a valid Organizator backup."))
        val root = try { JSONObject(content) } catch (_: Exception) { throw invalid }
        if (root.optString("app") != BackupFormat.APP_ID ||
            root.optInt("formatVersion", -1) != FORMAT_VERSION
        ) throw invalid
        val kdf = root.optJSONObject("kdf") ?: throw invalid
        val cipherInfo = root.optJSONObject("cipher") ?: throw invalid
        val iterations = kdf.optInt("iterations", 0)
        if (iterations !in 1..10_000_000) throw invalid
        val salt: ByteArray
        val iv: ByteArray
        val payload: ByteArray
        try {
            salt = Base64.decode(kdf.getString("salt"))
            iv = Base64.decode(cipherInfo.getString("iv"))
            payload = Base64.decode(root.getString("payload"))
        } catch (_: Exception) {
            throw invalid
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(pbkdf2Sha256(password, salt, iterations, KEY_BYTES), "AES"),
            GCMParameterSpec(TAG_BITS, iv),
        )
        cipher.updateAAD(AAD)
        val plain = try {
            cipher.doFinal(payload)
        } catch (_: AEADBadTagException) {
            throw WrongPasswordException()
        }
        return String(plain, Charsets.UTF_8)
    }

    /**
     * PBKDF2 cu HMAC-SHA256 (RFC 8018). Implementat aici pentru că
     * SecretKeyFactory „PBKDF2WithHmacSHA256” există pe Android abia de la
     * API 26, iar minSdk e 24.
     */
    fun pbkdf2Sha256(password: String, salt: ByteArray, iterations: Int, keyBytes: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(password.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        val hLen = mac.macLength
        val blocks = (keyBytes + hLen - 1) / hLen
        val out = ByteArray(blocks * hLen)
        for (block in 1..blocks) {
            mac.update(salt)
            mac.update(byteArrayOf(
                (block ushr 24).toByte(), (block ushr 16).toByte(),
                (block ushr 8).toByte(), block.toByte(),
            ))
            var u = mac.doFinal()
            val t = u.copyOf()
            for (i in 2..iterations) {
                u = mac.doFinal(u)
                for (j in t.indices) t[j] = (t[j].toInt() xor u[j].toInt()).toByte()
            }
            t.copyInto(out, (block - 1) * hLen)
        }
        return out.copyOf(keyBytes)
    }
}

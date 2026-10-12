package com.example.management_app

import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Autentificarea mesajelor de sincronizare dintre cele două telefoane —
 * logică pură, testabilă pe JVM.
 *
 * Numărul expeditorului unui SMS poate fi falsificat, deci nu e suficient ca
 * mesajul să „vină” de la partener. Ambele telefoane cunosc un cod de
 * împerechere (introdus manual pe fiecare, per tabel); fiecare mesaj „ORG:”
 * e trimis învelit și semnat cu el:
 *
 *   ORG:S:<semnătură, 16 hex>:<mesajul original, ex. ORG:A:{...}>
 *
 * Semnătura = primii 8 octeți din HMAC-SHA256(cheie, mesaj original), cu
 * cheia = SHA-256("organizator-sync|" + cod normalizat). Mesajele fără
 * semnătură validă sunt respinse.
 */
object SyncAuth {

    const val SIGNED_PREFIX = "ORG:S:"
    const val MIN_CODE_LENGTH = 8
    private const val TAG_HEX_LENGTH = 16

    /** Litere mari și cifre, fără spații/cratime — „k7qm-2xpa” = „K7QM2XPA”. */
    fun normalizeCode(code: String?): String =
        code.orEmpty().uppercase().filter { it in 'A'..'Z' || it in '0'..'9' }

    fun isValidCode(code: String?): Boolean = normalizeCode(code).length >= MIN_CODE_LENGTH

    private fun key(code: String): ByteArray =
        MessageDigest.getInstance("SHA-256")
            .digest("organizator-sync|${normalizeCode(code)}".toByteArray(Charsets.UTF_8))

    private fun tag(code: String, message: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key(code), "HmacSHA256"))
        return mac.doFinal(message.toByteArray(Charsets.UTF_8))
            .take(TAG_HEX_LENGTH / 2)
            .joinToString("") { "%02x".format(it) }
    }

    fun sign(code: String, message: String): String {
        require(isValidCode(code)) { tr("Cod de împerechere invalid.", "Invalid pairing code.") }
        return "$SIGNED_PREFIX${tag(code, message)}:$message"
    }

    /** Mesajul original dacă semnătura e validă pentru [code], altfel null. */
    fun verify(code: String?, body: String): String? {
        if (!isValidCode(code) || !body.startsWith(SIGNED_PREFIX)) return null
        val rest = body.substring(SIGNED_PREFIX.length)
        val sep = rest.indexOf(':')
        if (sep != TAG_HEX_LENGTH) return null
        val received = rest.substring(0, sep)
        val message = rest.substring(sep + 1)
        val expected = tag(code!!, message)
        // Comparație în timp constant.
        return if (MessageDigest.isEqual(
                expected.toByteArray(Charsets.US_ASCII),
                received.toByteArray(Charsets.US_ASCII),
            )
        ) message else null
    }
}

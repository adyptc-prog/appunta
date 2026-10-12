package com.example.management_app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Sigilează un secret local (implementarea reală: Android Keystore). */
interface SecretBox {
    fun seal(plain: ByteArray): String
    fun open(sealed: String): ByteArray
}

/**
 * Cheia AES stă în Android Keystore (nu poate fi extrasă din telefon); în
 * BackupPrefs se păstrează doar parola criptată cu ea. Excluse din backup-ul
 * Google (backup_rules.xml), deci nu pleacă de pe telefon.
 */
object KeystoreSecretBox : SecretBox {
    private const val ALIAS = "organizator_backup_password"
    private const val PROVIDER = "AndroidKeyStore"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    override fun seal(plain: ByteArray): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val iv = cipher.iv
        val out = cipher.doFinal(plain)
        return Base64.encodeToString(iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(out, Base64.NO_WRAP)
    }

    override fun open(sealed: String): ByteArray {
        val (iv, data) = sealed.split(":", limit = 2)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
        return cipher.doFinal(Base64.decode(data, Base64.NO_WRAP))
    }
}

/** Parola de backup a acestui telefon, folosită de backup-ul manual și automat. */
object BackupPassword {
    private const val PREFS_NAME = "BackupPrefs"
    private const val KEY_SEALED = "backup_password_sealed"

    // Doar testele îl înlocuiesc (Robolectric nu are Android Keystore).
    @Volatile
    internal var box: SecretBox = KeystoreSecretBox

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun set(context: Context, password: String) {
        require(BackupCrypto.isValidPassword(password)) {
            tr(
                "Parola trebuie să aibă minim ${BackupCrypto.MIN_PASSWORD_LENGTH} caractere.",
                "The password must have at least ${BackupCrypto.MIN_PASSWORD_LENGTH} characters.",
            )
        }
        prefs(context).edit()
            .putString(KEY_SEALED, box.seal(password.toByteArray(Charsets.UTF_8)))
            .commit()
    }

    /** null dacă nu e setată sau nu mai poate fi citită (cheia Keystore pierdută). */
    fun get(context: Context): String? {
        val sealed = prefs(context).getString(KEY_SEALED, null) ?: return null
        return try {
            String(box.open(sealed), Charsets.UTF_8)
        } catch (e: Exception) {
            Diag.e("backup password unreadable", e)
            null
        }
    }

    fun isSet(context: Context): Boolean = get(context) != null
}

package com.example.management_app

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.util.Base64
import org.json.JSONObject

/**
 * Starea licenței (flux nou, format identic cu Fidelio), păstrată în
 * "LicensePrefs":
 *  - business_id   — codul de instalare pe care e emisă licența;
 *  - license_json  — conținutul semnat al licenței, copiat intern la import,
 *                    ca licența să nu depindă de fișierul original (poate fi
 *                    șters, sau URI-ul poate deveni inaccesibil) și să poată
 *                    fi inclusă în backup / trimisă telefonului partener;
 *  - license_uri   — fluxul inițial, păstrat doar pentru migrare.
 */
object LicenseStore {

    const val PREFS_NAME = "LicensePrefs"
    const val KEY_BUSINESS_ID = "business_id"
    const val KEY_LICENSE_JSON = "license_json"
    const val KEY_LICENSE_URI = "license_uri"
    private const val KEY_LAST_CHECK = "last_license_check"
    // Setat când licența a fost preluată/reînnoită de la telefonul partener,
    // ca Flutter să poată anunța utilizatorul la următoarea verificare.
    private const val KEY_PARTNER_NOTICE = "license_partner_notice"
    // De unde vine licența: SOURCE_FILE (importată aici din fișier / backup)
    // sau SOURCE_PARTNER (primită prin SMS) — doar prima poate fi trimisă.
    const val KEY_LICENSE_SOURCE = "license_source"
    const val SOURCE_FILE = "file"
    const val SOURCE_PARTNER = "partner"
    // Partenerul căruia i-a fost trimisă licența, și pentru care licență.
    const val KEY_SHARE_PARTNER = "license_share_partner"
    const val KEY_SHARE_LICENSE_ID = "license_share_license_id"

    // Cheia publică RSA-2048 (DER/X.509, base64) — corespunde tools/private.pem
    const val PUBLIC_KEY_B64 =
        "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA6LMDi/tUuBHqLag6NHTw" +
        "WNQfS3Forlq5IVkSDtjoNa/Q+2N+hlfSdLJyNsetsZhBpDhvpl/BBbvlMT+CZsyh" +
        "xnmVVZ1w0bd6JUftEYAnK6/aaLW7qaRxQ0Gh1LT6YDKpJecd5ozWM7hgNTXoflRl" +
        "PgjmdxiQJcZHOuRV4crPOYDNPQbgbWnHVMor4MyOX9bLzHOdyVjO/SyDNR2eMoLP" +
        "TtoHDI1Lhj/2r3T6tt/BE+mC8see5GCq2Jzb31IgFpw0gPAK495R3P3b3URbCCkt" +
        "yx23dfww5NNWiI4fRp/PyFMS1lvqprQZf8gLWXqnKmmih+2kTNE6ukHcO7pjfKBD" +
        "UwIDAQAB"

    private val productionVerifier by lazy {
        LicenseVerifier(Base64.decode(PUBLIC_KEY_B64, Base64.DEFAULT)) {
            Base64.decode(it, Base64.DEFAULT)
        }
    }

    // Doar testele îl înlocuiesc (licențele de test sunt semnate cu altă cheie).
    @Volatile
    internal var verifierOverride: LicenseVerifier? = null

    private val verifier: LicenseVerifier get() = verifierOverride ?: productionVerifier

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun getOrCreateBusinessId(context: Context): String {
        val prefs = prefs(context)
        val existing = prefs.getString(KEY_BUSINESS_ID, null)
        if (existing != null) return existing
        val fresh = "organizator-${System.currentTimeMillis()}"
        prefs.edit().putString(KEY_BUSINESS_ID, fresh).apply()
        return fresh
    }

    // Anti-clock-manipulation: monotonically non-decreasing "effective now",
    // identical logic to Fidelio's getEffectiveNow().
    internal fun effectiveNow(context: Context): Long {
        val prefs = prefs(context)
        val lastMs = prefs.getLong(KEY_LAST_CHECK, 0L)
        val deviceNow = System.currentTimeMillis()
        val effectiveNow = if (deviceNow < lastMs - 60_000L) lastMs else maxOf(deviceNow, lastMs)
        prefs.edit().putLong(KEY_LAST_CHECK, effectiveNow).apply()
        return effectiveNow
    }

    /** Licența stocată intern; migrează o singură dată din vechiul license_uri. */
    fun storedLicense(context: Context): String? {
        val prefs = prefs(context)
        prefs.getString(KEY_LICENSE_JSON, null)?.let { return it }
        val uriText = prefs.getString(KEY_LICENSE_URI, null) ?: return null
        val content = try {
            context.contentResolver.openInputStream(Uri.parse(uriText))?.use {
                it.reader(Charsets.UTF_8).readText()
            }
        } catch (_: Exception) {
            null
        } ?: return null
        prefs.edit().putString(KEY_LICENSE_JSON, content).apply()
        return content
    }

    fun check(context: Context): LicenseCheck {
        val content = storedLicense(context)
            ?: return LicenseCheck("missing", tr("Niciun fișier de licență selectat.", "No license file selected."))
        return verifier.evaluate(content, getOrCreateBusinessId(context), effectiveNow(context))
    }

    /**
     * Import din fișierul ales de utilizator. O licență invalidă NU înlocuiește
     * licența stocată — altfel alegerea greșită a unui fișier ar dezactiva o
     * licență bună.
     */
    fun importLicense(context: Context, content: String): LicenseCheck {
        val result = verifier.evaluate(content, getOrCreateBusinessId(context), effectiveNow(context))
        if (result.isActive) {
            prefs(context).edit()
                .putString(KEY_LICENSE_JSON, content)
                .putString(KEY_LICENSE_SOURCE, SOURCE_FILE)
                .apply()
        }
        return result
    }

    /**
     * Licența de trimis telefonului [partnerPhone], dacă are voie (vezi
     * LicenseVerifier.decideShare). La SEND partenerul rămâne legat de
     * licență. Licența e compactată (fără spații/linii noi) ca SMS-ul să aibă
     * cât mai puține segmente; semnătura acoperă câmpurile canonice, nu
     * textul JSON, deci rămâne validă.
     */
    fun shareTo(context: Context, partnerPhone: String): Pair<ShareDecision, String?> {
        val current = check(context)
        val prefs = prefs(context)
        val decision = LicenseVerifier.decideShare(
            active = current.isActive,
            fromPartner = prefs.getString(KEY_LICENSE_SOURCE, SOURCE_FILE) == SOURCE_PARTNER,
            licenseId = current.licenseId,
            boundLicenseId = prefs.getString(KEY_SHARE_LICENSE_ID, null),
            boundPhone = prefs.getString(KEY_SHARE_PARTNER, null),
            partnerPhone = partnerPhone,
        )
        if (decision != ShareDecision.SEND) return decision to null
        val compact = try {
            JSONObject(storedLicense(context) ?: return ShareDecision.NO_LICENSE to null).toString()
        } catch (_: Exception) {
            return ShareDecision.NO_LICENSE to null
        }
        prefs.edit()
            .putString(KEY_SHARE_PARTNER, Phones.digitsOnly(partnerPhone))
            .putString(KEY_SHARE_LICENSE_ID, current.licenseId)
            .commit()
        return decision to compact
    }

    /** Pentru ecranul de licență: de unde vine licența și cui a fost trimisă. */
    fun shareInfo(context: Context): HashMap<String, Any?> {
        val prefs = prefs(context)
        val current = check(context)
        val bound = prefs.getString(KEY_SHARE_PARTNER, null)
            ?.takeIf { prefs.getString(KEY_SHARE_LICENSE_ID, null) == current.licenseId }
        return hashMapOf(
            "fromPartner" to (prefs.getString(KEY_LICENSE_SOURCE, SOURCE_FILE) == SOURCE_PARTNER),
            "sharedWith" to bound?.let { Diag.mask(it) },
        )
    }

    /** Licență primită prin SMS de la partenerul de sincronizare. */
    fun adoptFromPartner(context: Context, content: String): AdoptionDecision {
        val now = effectiveNow(context)
        val incoming = verifier.evaluate(content, null, now)
        val currentBusinessId = getOrCreateBusinessId(context)
        val current = storedLicense(context)?.let { verifier.evaluate(it, currentBusinessId, now) }
        val decision = LicenseVerifier.decideAdoption(current, currentBusinessId, incoming)
        if (decision == AdoptionDecision.ADOPT || decision == AdoptionDecision.RENEW) {
            prefs(context).edit()
                .putString(KEY_BUSINESS_ID, incoming.businessId)
                .putString(KEY_LICENSE_JSON, content)
                .putString(KEY_LICENSE_SOURCE, SOURCE_PARTNER)
                .putBoolean(KEY_PARTNER_NOTICE, true)
                .commit()
        }
        return decision
    }

    // ── Backup / restore ─────────────────────────────────────────────────────────
    fun identity(context: Context): BackupFormat.Identity {
        val prefs = prefs(context)
        return BackupFormat.Identity(
            businessId = getOrCreateBusinessId(context),
            licenseJson = storedLicense(context),
            licenseSource = prefs.getString(KEY_LICENSE_SOURCE, null),
            sharePartner = prefs.getString(KEY_SHARE_PARTNER, null),
            shareLicenseId = prefs.getString(KEY_SHARE_LICENSE_ID, null),
        )
    }

    /** True dacă [licenseJson] e o licență activă emisă pe [businessId]. */
    fun isActiveFor(context: Context, licenseJson: String?, businessId: String?): Boolean {
        if (licenseJson == null || businessId == null) return false
        return verifier.evaluate(licenseJson, businessId, effectiveNow(context)).isActive
    }

    /**
     * Restaurează codul de instalare (și licența) din backup — licența
     * cumpărată continuă să funcționeze după reinstalare sau pe telefon nou.
     * Nu înlocuiește o licență activă cu o identitate fără licență validă.
     * Întoarce true dacă identitatea a fost schimbată.
     */
    fun restoreIdentity(context: Context, identity: BackupFormat.Identity): Boolean {
        val businessId = identity.businessId ?: return false
        val restore = BackupFormat.shouldRestoreIdentity(
            currentLicenseActive = check(context).isActive,
            backupLicenseActive = isActiveFor(context, identity.licenseJson, businessId),
        )
        if (!restore) return false
        val editor = prefs(context).edit().putString(KEY_BUSINESS_ID, businessId)
        if (identity.licenseJson != null) {
            editor.putString(KEY_LICENSE_JSON, identity.licenseJson)
        } else {
            editor.remove(KEY_LICENSE_JSON)
        }
        // Proveniența și partenerul legat vin cu licența — altfel backup-ul
        // telefonului partener, restaurat pe un telefon nou, ar putea trimite
        // licența unui al treilea telefon.
        fun putOrRemove(key: String, value: String?) {
            if (value != null) editor.putString(key, value) else editor.remove(key)
        }
        putOrRemove(KEY_LICENSE_SOURCE, identity.licenseSource)
        putOrRemove(KEY_SHARE_PARTNER, identity.sharePartner)
        putOrRemove(KEY_SHARE_LICENSE_ID, identity.shareLicenseId)
        // URI-ul vechi ar reintroduce, prin migrare, licența altei identități.
        editor.remove(KEY_LICENSE_URI).commit()
        return true
    }

    /** Întoarce true (o singură dată) dacă licența a venit de la partener. */
    fun consumePartnerNotice(context: Context): Boolean {
        val prefs = prefs(context)
        if (!prefs.getBoolean(KEY_PARTNER_NOTICE, false)) return false
        prefs.edit().putBoolean(KEY_PARTNER_NOTICE, false).apply()
        return true
    }
}

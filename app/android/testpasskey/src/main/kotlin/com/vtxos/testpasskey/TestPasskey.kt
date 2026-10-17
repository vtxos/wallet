package com.vtxos.testpasskey

import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.os.OutcomeReceiver
import android.util.Log
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.ClearCredentialException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.CreateCredentialUnknownException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.GetCredentialUnknownException
import androidx.credentials.provider.BeginCreateCredentialRequest
import androidx.credentials.provider.BeginCreateCredentialResponse
import androidx.credentials.provider.BeginCreatePublicKeyCredentialRequest
import androidx.credentials.provider.BeginGetCredentialRequest
import androidx.credentials.provider.BeginGetCredentialResponse
import androidx.credentials.provider.BeginGetPublicKeyCredentialOption
import androidx.credentials.provider.CallingAppInfo
import androidx.credentials.provider.CreateEntry
import androidx.credentials.provider.CredentialProviderService
import androidx.credentials.provider.PendingIntentHandler
import androidx.credentials.provider.ProviderClearCredentialStateRequest
import androidx.credentials.provider.PublicKeyCredentialEntry
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import org.json.JSONArray
import org.json.JSONObject

/*
 * A passkey provider in software, for the emulator e2e. **Never for a real wallet**: its keys are
 * plain files in its own storage.
 *
 * It stands where Google Password Manager stands on a phone, so the app's own path is the real one:
 * PasskeyPlugin → Credential Manager → a provider → back. What it signs is what the runtime's
 * SoftwareAuthenticator and core's signs (attestation `none`, ES256, UP|UV), and two things only a
 * provider on Android does: the origin is `android:apk-key-hash:<the calling APK's signing
 * certificate>`, and the PRF extension is answered, as WebAuthn defines it over a per-credential
 * secret.
 *
 * It checks no Digital Asset Links: the relying party's vouching for the app is Google's part on a
 * phone, and not what this tests.
 */

private const val TAG = "TestPasskey"
private const val EXTRA_CREDENTIAL = "credential"
private const val FLAG_UP = 0x01
private const val FLAG_UV = 0x04
private const val FLAG_AT = 0x40

class TestPasskeyService : CredentialProviderService() {
    override fun onBeginCreateCredentialRequest(
        request: BeginCreateCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<BeginCreateCredentialResponse, CreateCredentialException>,
    ) {
        if (request !is BeginCreatePublicKeyCredentialRequest) {
            callback.onError(CreateCredentialUnknownException("only passkeys"))
            return
        }
        val entry = CreateEntry.Builder("Test passkeys", pendingIntent(this, "create", null)).build()
        callback.onResult(BeginCreateCredentialResponse(createEntries = listOf(entry)))
    }

    override fun onBeginGetCredentialRequest(
        request: BeginGetCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<BeginGetCredentialResponse, GetCredentialException>,
    ) {
        val store = Store(this)
        val entries = request.beginGetCredentialOptions
            .filterIsInstance<BeginGetPublicKeyCredentialOption>()
            .flatMap { option ->
                val options = JSONObject(option.requestJson)
                val allowed = options.optJSONArray("allowCredentials")
                    ?.let { a -> (0 until a.length()).map { a.getJSONObject(it).getString("id") } }
                    ?.toSet()
                store.ids(options.getString("rpId"))
                    .filter { allowed.isNullOrEmpty() || it in allowed }
                    .map { id ->
                        PublicKeyCredentialEntry.Builder(this, id.take(12), pendingIntent(this, "get", id), option)
                            .build()
                    }
            }
        callback.onResult(BeginGetCredentialResponse(credentialEntries = entries))
    }

    override fun onClearCredentialStateRequest(
        request: ProviderClearCredentialStateRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<Void?, ClearCredentialException>,
    ) {
        callback.onResult(null)
    }
}

// Mutable, as Credential Manager adds the request to it; the URI keeps one per credential distinct.
private fun pendingIntent(context: Context, op: String, credential: String?): PendingIntent =
    PendingIntent.getActivity(
        context,
        0,
        Intent(context, PasskeyActivity::class.java)
            .setData(Uri.parse("testpasskey:$op/${credential ?: ""}"))
            .putExtra(EXTRA_CREDENTIAL, credential),
        PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

/** Answers the entry the person picked on Credential Manager's sheet, and closes. */
class PasskeyActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val result = Intent()
        val credential = intent.getStringExtra(EXTRA_CREDENTIAL)
        val store = Store(this)
        if (credential == null) {
            try {
                val request = PendingIntentHandler.retrieveProviderCreateCredentialRequest(intent)
                    ?: error("no create request")
                val options = (request.callingRequest as CreatePublicKeyCredentialRequest).requestJson
                PendingIntentHandler.setCreateCredentialResponse(
                    result,
                    CreatePublicKeyCredentialResponse(store.create(options, request.callingAppInfo)),
                )
            } catch (e: Exception) {
                Log.e(TAG, "create", e)
                PendingIntentHandler.setCreateCredentialException(result, CreateCredentialUnknownException(e.message))
            }
        } else {
            try {
                val request = PendingIntentHandler.retrieveProviderGetCredentialRequest(intent)
                    ?: error("no get request")
                val option = request.credentialOptions.filterIsInstance<GetPublicKeyCredentialOption>().first()
                PendingIntentHandler.setGetCredentialResponse(
                    result,
                    GetCredentialResponse(
                        PublicKeyCredential(store.assert(credential, option.requestJson, request.callingAppInfo)),
                    ),
                )
            } catch (e: Exception) {
                Log.e(TAG, "get", e)
                PendingIntentHandler.setGetCredentialException(result, GetCredentialUnknownException(e.message))
            }
        }
        setResult(RESULT_OK, result)
        finish()
    }
}

/** The credentials, one JSON object each in this app's preferences. */
private class Store(context: Context) {
    private val prefs = context.getSharedPreferences("passkeys", Context.MODE_PRIVATE)
    private val random = SecureRandom()

    fun ids(rpId: String): List<String> =
        prefs.all.keys.filter { JSONObject(prefs.getString(it, "{}")!!).optString("rpId") == rpId }

    /** A registration: a fresh P-256 key, attested `none`. */
    fun create(requestJson: String, app: CallingAppInfo): String {
        val options = JSONObject(requestJson)
        val rpId = options.getJSONObject("rp").getString("id")
        val keys = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }
            .generateKeyPair()
        val id = ByteArray(16).also(random::nextBytes)
        val credRandom = ByteArray(32).also(random::nextBytes)
        prefs.edit().putString(
            b64(id),
            JSONObject()
                .put("rpId", rpId)
                .put("key", b64(keys.private.encoded))
                .put("credRandom", b64(credRandom))
                .put("userHandle", options.getJSONObject("user").getString("id"))
                .toString(),
        ).commit()

        val point = (keys.public as ECPublicKey).w
        // COSE_Key {1: 2 (EC2), 3: -7 (ES256), -1: 1 (P-256), -2: x, -3: y}
        val cose = bytes(0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20) + unsigned32(point.affineX) +
            bytes(0x22, 0x58, 0x20) + unsigned32(point.affineY)
        val authData = sha256(rpId.toByteArray()) + bytes(FLAG_UP or FLAG_UV or FLAG_AT, 0, 0, 0, 0) +
            ByteArray(16) + bytes(0, id.size) + id + cose
        // {"fmt": "none", "attStmt": {}, "authData": authData}
        val attestation = bytes(0xA3, 0x63) + "fmt".toByteArray() + bytes(0x64) + "none".toByteArray() +
            bytes(0x67) + "attStmt".toByteArray() + bytes(0xA0, 0x68) + "authData".toByteArray() +
            cborBytesHeader(authData.size) + authData

        val response = JSONObject()
            .put("clientDataJSON", b64(clientData("webauthn.create", options, app)))
            .put("attestationObject", b64(attestation))
            .put("transports", JSONArray(listOf("internal")))
        val extensions = JSONObject()
        if (options.optJSONObject("extensions")?.has("prf") == true) {
            extensions.put("prf", JSONObject().put("enabled", true))
        }
        return credential(id, response, extensions)
    }

    /** An assertion, with the PRF evaluated when the request asks for it. */
    fun assert(id: String, requestJson: String, app: CallingAppInfo): String {
        val options = JSONObject(requestJson)
        val stored = JSONObject(prefs.getString(id, null) ?: error("no credential $id"))
        val authData = sha256(stored.getString("rpId").toByteArray()) + bytes(FLAG_UP or FLAG_UV, 0, 0, 0, 0)
        val clientData = clientData("webauthn.get", options, app)
        val key = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(unb64(stored.getString("key"))))
        // SHA256withECDSA gives ASN.1 DER, which is what WebAuthn's ES256 signature is.
        val signature = Signature.getInstance("SHA256withECDSA").run {
            initSign(key)
            update(authData + sha256(clientData))
            sign()
        }

        val response = JSONObject()
            .put("clientDataJSON", b64(clientData))
            .put("authenticatorData", b64(authData))
            .put("signature", b64(signature))
            .put("userHandle", stored.getString("userHandle"))
        val extensions = JSONObject()
        options.optJSONObject("extensions")?.optJSONObject("prf")?.optJSONObject("eval")?.let { eval ->
            val results = JSONObject()
            for (name in listOf("first", "second")) {
                if (eval.has(name)) results.put(name, b64(prf(unb64(stored.getString("credRandom")), unb64(eval.getString(name)))))
            }
            extensions.put("prf", JSONObject().put("results", results))
        }
        return credential(unb64(id), response, extensions)
    }

    private fun credential(id: ByteArray, response: JSONObject, extensions: JSONObject): String =
        JSONObject()
            .put("id", b64(id))
            .put("rawId", b64(id))
            .put("type", "public-key")
            .put("authenticatorAttachment", "platform")
            .put("response", response)
            .put("clientExtensionResults", extensions)
            .toString()

    /**
     * What Android writes for a native app: its origin is the calling APK's signing certificate, and
     * the package is named beside it. The challenge goes back as the string it came as.
     */
    private fun clientData(type: String, options: JSONObject, app: CallingAppInfo): ByteArray {
        val cert = app.signingInfo.apkContentsSigners.first().toByteArray()
        val origin = "android:apk-key-hash:" + b64(sha256(cert))
        return ("{\"type\":\"$type\",\"challenge\":\"${options.getString("challenge")}\",\"origin\":\"$origin\"," +
            "\"crossOrigin\":false,\"androidPackageName\":\"${app.packageName}\"}").toByteArray()
    }
}

/** WebAuthn's PRF: hmac-secret over the salt WebAuthn derives from the caller's input. */
private fun prf(credRandom: ByteArray, input: ByteArray): ByteArray {
    val salt = sha256("WebAuthn PRF".toByteArray() + bytes(0) + input)
    return Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(credRandom, "HmacSHA256"))
        doFinal(salt)
    }
}

private fun cborBytesHeader(length: Int): ByteArray = when {
    length < 24 -> bytes(0x40 + length)
    length < 256 -> bytes(0x58, length)
    else -> bytes(0x59, length shr 8, length and 0xFF)
}

private fun unsigned32(value: BigInteger): ByteArray {
    val raw = value.toByteArray().takeLast(32).toByteArray()
    return ByteArray(32 - raw.size) + raw
}

private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }
private fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)
private fun b64(data: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(data)
private fun unb64(data: String): ByteArray = Base64.getUrlDecoder().decode(data)

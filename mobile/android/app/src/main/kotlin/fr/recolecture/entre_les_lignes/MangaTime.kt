package fr.recolecture.entre_les_lignes

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.annotation.Keep
import org.json.JSONObject
import java.net.URL
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.net.ssl.HttpsURLConnection

/** Session indépendante de la clé OpenAI, jamais exposée à Flutter ni intégrée à l'APK. */
class MangaSession(context: Context) {
    private val prefs = context.getSharedPreferences("iris_mangatime_session", Context.MODE_PRIVATE)
    private val alias = "iris_mangatime_v1"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    @Synchronized fun read(): JSONObject? {
        val raw = prefs.getString("encrypted", null) ?: return null
        return try {
            val parts = raw.split(":")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
            JSONObject(String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8))
        } catch (_: Exception) { null }
    }
    @Synchronized fun save(session: JSONObject) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(cipher.doFinal(session.toString().toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
        check(prefs.edit().putString("encrypted", encrypted).commit())
    }
    @Synchronized fun clear() { check(prefs.edit().clear().commit()) }

    fun importSession(raw: String) {
        val source = JSONObject(raw.trim().removePrefix("\uFEFF"))
        val session = JSONObject()
        for (header in listOf("authorization", "x-app-token")) {
            val value = source.getString(header)
            require(value.length in 1..16000 && value.all { it.code in 33..126 || it == ' ' })
            session.put(header, value)
        }
        require(session.getString("authorization").startsWith("Bearer "))
        val response = MangaTimeNetwork.fetch(session, "GET", "/api/v1/auth/me")
        check(response.getInt("status") == 200)
        val account = JSONObject(response.getString("body")).getJSONObject("data").getString("id")
        require(account.isNotBlank())
        session.put("account", account)
        save(session)
    }
}

@Keep
class MangaTimeNetwork(private val session: MangaSession) {
    fun account(): String = session.read()?.optString("account") ?: ""
    fun request(method: String, path: String): String {
        val id = "[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}"
        require(when (method) {
            "GET" -> path.matches(Regex("/api/v1/mangas/$id")) ||
                path.matches(Regex("/api/v1/search\\?keyword=[A-Za-z0-9%+_.~*-]{1,6000}"))
            "POST" -> path.matches(Regex("/api/v1/me/library/mangas/$id/plan-to-read"))
            "DELETE" -> path.matches(Regex("/api/v1/me/library/mangas/$id"))
            else -> false
        })
        val credentials = session.read() ?: return JSONObject().put("status", 401).toString()
        return fetch(credentials, method, path).toString()
    }
    companion object {
        fun fetch(session: JSONObject, method: String, path: String): JSONObject {
            val connection = URL("https://api.mangatime.net$path").openConnection() as HttpsURLConnection
            return try {
                connection.connectTimeout = 15000
                connection.readTimeout = 20000
                connection.requestMethod = method
                connection.instanceFollowRedirects = false
                connection.setRequestProperty("Authorization", session.getString("authorization"))
                connection.setRequestProperty("X-App-Token", session.getString("x-app-token"))
                connection.setRequestProperty("Accept", "application/json")
                connection.setRequestProperty("X-Locale", "fr")
                connection.setRequestProperty("X-Timezone", "Europe/Paris")
                connection.setRequestProperty("User-Agent", "Iris/1.2 (personal reading recommendations)")
                if (method == "POST") {
                    connection.doOutput = true
                    connection.setFixedLengthStreamingMode(0)
                    connection.outputStream.close()
                }
                val status = connection.responseCode
                val body = if (status in 200..299) connection.inputStream.use {
                    val bytes = it.readBytesLimited(2_000_000)
                    String(bytes, Charsets.UTF_8)
                } else ""
                JSONObject().put("status", status).put("body", body)
            } catch (_: Exception) {
                JSONObject().put("status", 0)
            } finally { connection.disconnect() }
        }
    }
}

private fun java.io.InputStream.readBytesLimited(limit: Int): ByteArray {
    val result = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(8192)
    while (true) {
        val count = read(buffer)
        if (count == -1) break
        require(result.size() + count <= limit)
        result.write(buffer, 0, count)
    }
    return result.toByteArray()
}

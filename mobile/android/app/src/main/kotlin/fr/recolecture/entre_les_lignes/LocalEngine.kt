package fr.recolecture.entre_les_lignes

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.annotation.Keep
import com.chaquo.python.Python
import com.chaquo.python.PyObject
import com.chaquo.python.android.AndroidPlatform
import java.io.File
import java.security.KeyStore
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import org.json.JSONObject
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Appelé par Python : conserver le nom de la méthode lors de l'optimisation. */
@Keep
class OpenAINetwork {
    fun post(body: String, key: String): String {
        val connection = URL("https://api.openai.com/v1/responses").openConnection() as HttpsURLConnection
        return try {
            connection.connectTimeout = 20000
            connection.readTimeout = 110000
            connection.requestMethod = "POST"
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("Authorization", "Bearer $key")
            connection.setRequestProperty("Content-Type", "application/json")
            connection.doOutput = true
            val bytes = body.toByteArray(Charsets.UTF_8)
            connection.setFixedLengthStreamingMode(bytes.size)
            connection.outputStream.use { it.write(bytes) }
            val status = connection.responseCode
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            val response = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() } ?: "{}"
            JSONObject().put("status", status).put("body", response).toString()
        } catch (_: Exception) {
            JSONObject().put("network_error", true).toString()
        } finally { connection.disconnect() }
    }
}

/** Les secrets restent dans le coffre Android, séparés des données du moteur. */
class ApiKeyVault(context: Context) {
    private val prefs = context.getSharedPreferences("iris_credentials", Context.MODE_PRIVATE)
    private val alias = "iris_openai_v1"
    private fun secret(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    @Synchronized fun read(): String {
        val raw = prefs.getString("encrypted", null) ?: return ""
        return try {
            val pieces = raw.split(":")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secret(), GCMParameterSpec(128, Base64.decode(pieces[0], Base64.NO_WRAP)))
            String(cipher.doFinal(Base64.decode(pieces[1], Base64.NO_WRAP)), Charsets.UTF_8)
        } catch (_: Exception) { "" }
    }
    @Synchronized fun write(value: String) {
        val key = value.trim()
        require(key.startsWith("sk-") && key.length in 20..512 && key.all { it.code in 33..126 })
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secret())
        val encrypted = Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(cipher.doFinal(key.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
        check(prefs.edit().putString("encrypted", encrypted).commit())
    }
    @Synchronized fun clear() { check(prefs.edit().clear().commit()) }
}

/** Unique pour le processus : une rotation de l'activité ne coupe pas une requête. */
object LocalEngine {
    private var engine: PyObject? = null
    @Synchronized fun get(context: Context): PyObject {
        engine?.let { return it }
        if (!Python.isStarted()) Python.start(AndroidPlatform(context.applicationContext))
        return Python.getInstance().getModule("mobile_engine")
            .callAttr("Engine", File(context.filesDir, "iris").absolutePath, null, OpenAINetwork(),
                MangaTimeNetwork(MangaSession(context.applicationContext)))
            .also { engine = it }
    }
}

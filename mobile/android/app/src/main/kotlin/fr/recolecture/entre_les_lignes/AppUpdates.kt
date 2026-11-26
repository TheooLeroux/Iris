package fr.recolecture.entre_les_lignes

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

/** Seules les versions signées avec la clé de l'app installée peuvent être proposées. */
class AppUpdates(private val activity: Activity) {
    private val repository = "TheooLeroux/Iris"
    private val prefs = activity.getSharedPreferences("iris_updates", Activity.MODE_PRIVATE)
    private val downloading = AtomicBoolean(false)
    private val cancelled = AtomicBoolean(false)
    @Volatile private var received = 0L
    @Volatile private var total = 0L
    private val directory get() = File(activity.cacheDir, "updates").apply { mkdirs() }
    private val target get() = File(directory, "iris-update.apk")

    @Suppress("DEPRECATION")
    private fun packageInfo() = activity.packageManager.getPackageInfo(activity.packageName, PackageManager.GET_SIGNATURES)
    @Suppress("DEPRECATION")
    private fun code(info: android.content.pm.PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    fun installed(): Map<String, Any> = mapOf("version" to (packageInfo().versionName ?: ""), "build" to code(packageInfo()))
    fun progress(): Map<String, Any> = mapOf("received" to received, "total" to total)
    fun cancel() { cancelled.set(true) }
    fun later(build: Long) { prefs.edit().putLong("dismissed", build).putLong("until", System.currentTimeMillis() + 86400000).apply() }

    private fun assetUrl(value: String): Boolean {
        val uri = Uri.parse(value)
        return uri.scheme == "https" && uri.host == "github.com" && uri.userInfo == null &&
            uri.port == -1 && uri.path?.startsWith("/$repository/releases/download/") == true && uri.query == null
    }

    private fun open(value: String): HttpsURLConnection {
        var url = URL(value)
        repeat(6) {
            require(url.protocol == "https" && url.userInfo == null && (url.port == -1 || url.port == 443))
            require(url.host in setOf("api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"))
            val connection = url.openConnection() as HttpsURLConnection
            connection.connectTimeout = 10000
            connection.readTimeout = 30000
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("User-Agent", "Iris-Android-Updater")
            connection.setRequestProperty("Accept", "application/vnd.github+json")
            val status = connection.responseCode
            if (status in setOf(301, 302, 303, 307, 308)) {
                val location = connection.getHeaderField("Location")
                connection.disconnect()
                require(!location.isNullOrBlank())
                url = URL(url, location)
            } else {
                if (status != 200) {
                    connection.disconnect()
                    if (status == 404) throw NoRelease()
                    error("Mise à jour indisponible. Réessaie plus tard.")
                }
                return connection
            }
        }
        error("Téléchargement indisponible.")
    }

    private fun json(url: String): JSONObject {
        val connection = open(url)
        try {
            return connection.inputStream.use { input ->
                val bytes = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    require(bytes.size() + count <= 256000)
                    bytes.write(buffer, 0, count)
                }
                JSONObject(bytes.toString("UTF-8"))
            }
        } finally { connection.disconnect() }
    }

    private fun validate(info: JSONObject) {
        require(info.getLong("build") > code(packageInfo()))
        require(info.getString("version").matches(Regex("[0-9]+\\.[0-9]+\\.[0-9]+")))
        require(info.getString("sha256").matches(Regex("[a-f0-9]{64}")))
        require(info.getLong("size") in 1..250_000_000)
        require(assetUrl(info.getString("apk_url")))
    }

    fun checkForUpdate(force: Boolean): Map<String, Any>? {
        val now = System.currentTimeMillis()
        if (!force && now - prefs.getLong("checked", 0) in 0L until 21600000L) return null
        prefs.edit().putLong("checked", now).apply()
        val release = try { json("https://api.github.com/repos/$repository/releases/latest") }
            catch (_: NoRelease) { return null }
        if (release.optBoolean("draft") || release.optBoolean("prerelease")) return null
        val assets = release.getJSONArray("assets")
        var manifest: String? = null
        for (index in 0 until assets.length()) {
            val asset = assets.getJSONObject(index)
            if (asset.optString("name") == "iris-update.json") manifest = asset.getString("browser_download_url")
        }
        val link = manifest ?: return null
        require(assetUrl(link))
        val info = json(link)
        if (info.getLong("build") <= code(packageInfo())) return null
        validate(info)
        // Le manifeste et l'APK doivent provenir de la même release complète.
        require(info.getString("apk_url").substringBeforeLast('/') == link.substringBeforeLast('/'))
        var apkFound = false
        for (index in 0 until assets.length()) {
            val asset = assets.getJSONObject(index)
            if (asset.getString("browser_download_url") == info.getString("apk_url") && asset.getLong("size") == info.getLong("size")) apkFound = true
        }
        require(apkFound)
        if (!force && info.getLong("build") == prefs.getLong("dismissed", 0) && now < prefs.getLong("until", 0)) return null
        return mapOf("version" to info.getString("version"), "build" to info.getLong("build"),
            "sha256" to info.getString("sha256"), "size" to info.getLong("size"),
            "apk_url" to info.getString("apk_url"), "notes" to info.optString("notes").take(3000))
    }

    @Suppress("DEPRECATION")
    private fun verify(file: File, expectedBuild: Long? = null) {
        val candidate = activity.packageManager.getPackageArchiveInfo(file.absolutePath, PackageManager.GET_SIGNATURES)
            ?: error("Fichier de mise à jour invalide.")
        require(candidate.packageName == activity.packageName && code(candidate) > code(packageInfo()))
        if (expectedBuild != null) require(code(candidate) == expectedBuild)
        val installed = packageInfo().signatures?.map { it.toCharsString() }?.toSet()
        val signatures = candidate.signatures?.map { it.toCharsString() }?.toSet()
        require(!installed.isNullOrEmpty() && installed == signatures)
    }

    fun download(info: JSONObject) {
        validate(info)
        check(downloading.compareAndSet(false, true))
        cancelled.set(false)
        received = 0
        total = info.getLong("size")
        val partial = File(directory, "iris-update.part")
        try {
            val connection = open(info.getString("apk_url"))
            val digest = MessageDigest.getInstance("SHA-256")
            try {
                connection.inputStream.use { input ->
                    partial.outputStream().use { output ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            check(!cancelled.get())
                            val count = input.read(buffer)
                            if (count < 0) break
                            received += count
                            require(received <= total)
                            digest.update(buffer, 0, count)
                            output.write(buffer, 0, count)
                        }
                    }
                }
            } finally { connection.disconnect() }
            val hash = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
            require(received == total && hash == info.getString("sha256"))
            verify(partial, info.getLong("build"))
            if (target.exists()) check(target.delete())
            check(partial.renameTo(target))
        } finally {
            partial.delete()
            downloading.set(false)
        }
    }

    fun install(): Boolean {
        verify(target)
        if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
            return false
        }
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", target)
        activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        })
        return true
    }

    private class NoRelease : Exception()
}

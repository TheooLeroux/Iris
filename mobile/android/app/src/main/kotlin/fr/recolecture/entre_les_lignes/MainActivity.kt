package fr.recolecture.entre_les_lignes

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val prefs by lazy { getSharedPreferences("mangatime", MODE_PRIVATE) }
    private val worker = Executors.newSingleThreadExecutor()
    private val engineWorker = Executors.newFixedThreadPool(3)
    private val vault by lazy { ApiKeyVault(applicationContext) }
    private var picker: MethodChannel.Result? = null
    private var sessionPicker: MethodChannel.Result? = null
    private val mangaSession by lazy { MangaSession(applicationContext) }
    private val updates by lazy { AppUpdates(this) }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "iris/updates").setMethodCallHandler { call, reply ->
            when (call.method) {
                "installed" -> reply.success(updates.installed())
                "progress" -> reply.success(updates.progress())
                "cancel" -> { updates.cancel(); reply.success(null) }
                "later" -> { updates.later((call.arguments as Number).toLong()); reply.success(null) }
                "install" -> try { reply.success(updates.install()) }
                    catch (_: Exception) { reply.error("update", "Impossible d’ouvrir l’installation. Réessaie.", null) }
                "check", "download" -> engineWorker.execute {
                    try {
                        val result = if (call.method == "check") updates.checkForUpdate(call.arguments == true)
                            else { updates.download(JSONObject(call.arguments as String)); null }
                        runOnUiThread { reply.success(result) }
                    } catch (_: Exception) {
                        val message = if (call.method == "check") "Vérification impossible. Vérifie Internet et réessaie."
                            else "Téléchargement interrompu ou fichier non valide. Réessaie."
                        runOnUiThread { reply.error("update", message, null) }
                    }
                }
                else -> reply.notImplemented()
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "iris/mangatime").setMethodCallHandler { call, reply ->
            when (call.method) {
                "configured" -> reply.success(mangaSession.read() != null)
                "clear" -> { mangaSession.clear(); reply.success(null) }
                "import" -> {
                    if (sessionPicker != null) { reply.error("busy", "Sélection déjà ouverte.", null) }
                    else {
                        sessionPicker = reply
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE); type = "*/*"
                        }, 732)
                    }
                }
                else -> reply.notImplemented()
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "iris/engine").setMethodCallHandler { call, reply ->
            engineWorker.execute {
                try {
                    val value: Any? = when (call.method) {
                        "settings" -> mapOf("configured" to vault.read().isNotEmpty())
                        "setKey" -> { vault.write(call.arguments as String); null }
                        "clearKey" -> { vault.clear(); null }
                        "request" -> {
                            val args = call.arguments as Map<*, *>
                            LocalEngine.get(applicationContext).callAttr("call", args["path"] as String,
                                args["body"] as? String, vault.read()).toString()
                        }
                        else -> throw IllegalArgumentException()
                    }
                    runOnUiThread { reply.success(value) }
                } catch (_: Exception) {
                    // Aucune exception native ni donnée de requête dans les logs ou l'UI.
                    val message = if (call.method == "setKey") "Clé invalide ou enregistrement impossible."
                        else "Impossible d’exécuter cette action. Ferme puis rouvre l’application."
                    runOnUiThread { reply.error("engine", message, null) }
                }
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "iris/library").setMethodCallHandler { call, reply ->
            when(call.method) {
                "choose" -> {
                    if (picker != null) { reply.error("busy","Sélection déjà ouverte",null); return@setMethodCallHandler }
                    picker = reply
                    startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), 731)
                }
                "openLink" -> {
                    try {
                        val uri = Uri.parse(call.arguments as String)
                        require(uri.scheme == "https" && !uri.host.isNullOrBlank() && uri.userInfo == null)
                        startActivity(Intent(Intent.ACTION_VIEW, uri))
                        reply.success(null)
                    } catch (error: Exception) {
                        reply.error("open", "Impossible d’ouvrir le site", null)
                    }
                }
                "sync" -> readExport(reply, null)
                else -> reply.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode,resultCode,data)
        if (requestCode == 732) {
            val reply = sessionPicker ?: return
            sessionPicker = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) { reply.success(false); return }
            worker.execute {
                try {
                    val raw = contentResolver.openInputStream(uri)?.use { input ->
                        val buffer = ByteArray(100_001)
                        var count = 0
                        while (count < buffer.size) {
                            val n = input.read(buffer, count, buffer.size - count)
                            if (n < 0) break
                            count += n
                        }
                        require(count <= 100_000)
                        String(buffer, 0, count, Charsets.UTF_8)
                    } ?: error("Session illisible")
                    mangaSession.importSession(raw)
                    runOnUiThread { reply.success(true) }
                } catch (_: Exception) {
                    runOnUiThread { reply.error("session", "Import impossible. Choisis un fichier session-mangatime.json valide et vérifie Internet.", null) }
                }
            }
            return
        }
        if (requestCode != 731) return
        val reply = picker ?: return
        picker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { reply.success(null); return }
        try {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            readExport(reply,uri)
        } catch(e:Exception) { reply.error("access","Accès au dossier refusé",null) }
    }

    private fun readExport(reply:MethodChannel.Result, selected:Uri?) {
        worker.execute {
            var error:String? = null
            val last = prefs.getLong("checked",0)
            val folder = selected ?: prefs.getString("folder",null)?.let(Uri::parse)
            if(folder != null && (selected != null || System.currentTimeMillis()-last !in 0L until 3600000L)) {
                try {
                    val children=DocumentsContract.buildChildDocumentsUriUsingTree(folder,DocumentsContract.getTreeDocumentId(folder))
                    var newest:String?=null
                    var latestName=""
                    contentResolver.query(children,arrayOf(Document.COLUMN_DOCUMENT_ID,Document.COLUMN_DISPLAY_NAME),null,null,null)?.use { c ->
                        while(c.moveToNext()) {
                            val name=c.getString(1) ?: continue
                            if(Regex("""mangatime-\d{8}-\d{6}.*\.json""",RegexOption.IGNORE_CASE).matches(name) && name>latestName) {
                                newest=c.getString(0); latestName=name
                            }
                        }
                    }
                    val id=newest ?: error("Aucun export MangaTime daté dans ce dossier.")
                    val uri=DocumentsContract.buildDocumentUriUsingTree(folder,id)
                    val raw=contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() } ?: error("Export illisible.")
                    val rows=JSONArray(raw.removePrefix("\uFEFF"))
                    for(i in 0 until rows.length()) {
                        val row=rows.getJSONObject(i)
                        require(row.getString("titre").isNotBlank() && row.getString("statut").isNotBlank())
                    }
                    check(prefs.edit().putString("data",rows.toString()).putString("folder",folder.toString()).putString("file",latestName).putLong("checked",System.currentTimeMillis()).commit())
                } catch(e:Exception) { error="Synchronisation impossible. Vérifie le dossier et le dernier export MangaTime." }
            }
            val snapshot=mapOf("data" to prefs.getString("data",null),"file" to prefs.getString("file",null),"checked" to prefs.getLong("checked",0),"error" to error)
            runOnUiThread { reply.success(snapshot) }
        }
    }
}

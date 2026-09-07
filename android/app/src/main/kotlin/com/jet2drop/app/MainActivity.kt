package com.jet2drop.app

import android.app.Activity
import android.Manifest
import android.content.Intent
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.content.ContentValues
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

class MainActivity : FlutterActivity() {
    private val channelName = "jet2drop/save_document"
    private val mediaPickerChannelName = "jet2drop/media_picker"
    private val tailscaleChannelName = "jet2drop/tailscale"
    private val transferServiceChannelName = "jet2drop/transfer_service"
    private val createDocumentRequestCode = 41002
    private val pickMediaRequestCode = 41003
    private var pendingTargetResult: MethodChannel.Result? = null
    private var pendingMediaResult: MethodChannel.Result? = null

    @Deprecated("Deprecated in Android API, retained for FlutterActivity compatibility.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == pickMediaRequestCode) {
            val callback = pendingMediaResult
            pendingMediaResult = null
            if (resultCode != Activity.RESULT_OK) {
                callback?.success(emptyList<String>())
                return
            }
            try {
                val uris = buildList {
                    data?.data?.let(::add)
                    data?.clipData?.let { clip ->
                        for (index in 0 until clip.itemCount) add(clip.getItemAt(index).uri)
                    }
                }.distinct()
                callback?.success(uris.map(::copyPickedMediaToCache))
            } catch (error: Exception) {
                callback?.error("media_read_failed", error.message, null)
            }
            return
        }
        if (requestCode != createDocumentRequestCode) {
            return
        }
        val targetCallback = pendingTargetResult
        if (targetCallback != null) {
            pendingTargetResult = null
            val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
            if (uri != null) {
                runCatching {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                    )
                }
            }
            targetCallback.success(uri?.toString())
            return
        }
    }

    private fun copyPickedMediaToCache(uri: android.net.Uri): Map<String, String> {
        val displayName = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
            ?.replace(Regex("[\\\\/:*?\"<>|]"), "_")
            ?: "media"
        val mimeType = contentResolver.getType(uri) ?: "application/octet-stream"
        val target = File(cacheDir, "quick-media-${UUID.randomUUID()}-$displayName")
        contentResolver.openInputStream(uri)?.use { input ->
            target.outputStream().use { output -> input.copyTo(output, 256 * 1024) }
        } ?: error("Unable to read selected media")
        return mapOf(
            "path" to target.absolutePath,
            "name" to displayName,
            "mimeType" to mimeType,
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        cacheDir.listFiles()
            ?.filter { it.name.startsWith("quick-media-") &&
                System.currentTimeMillis() - it.lastModified() > 24 * 60 * 60 * 1000L }
            ?.forEach { runCatching { it.delete() } }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "saveMedia") {
                    val sourcePath = call.argument<String>("sourcePath")
                    val suggestedName = call.argument<String>("suggestedName") ?: "media"
                    val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                    if (sourcePath == null || !File(sourcePath).exists()) {
                        result.error("source_missing", "Downloaded file is no longer available.", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val collection = if (mimeType.startsWith("video/")) {
                            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                        } else {
                            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                        }
                        val values = ContentValues().apply {
                            put(MediaStore.MediaColumns.DISPLAY_NAME, suggestedName)
                            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                put(MediaStore.MediaColumns.RELATIVE_PATH, if (mimeType.startsWith("video/")) "Movies/Jet2Drop" else "Pictures/Jet2Drop")
                                put(MediaStore.MediaColumns.IS_PENDING, 1)
                            }
                        }
                        val uri = contentResolver.insert(collection, values)
                            ?: throw IllegalStateException("Unable to create media entry")
                        try {
                            contentResolver.openOutputStream(uri, "w")!!.use { output ->
                                File(sourcePath).inputStream().use { input -> input.copyTo(output) }
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                ContentValues().also { it.put(MediaStore.MediaColumns.IS_PENDING, 0) }
                                    .let { contentResolver.update(uri, it, null, null) }
                            }
                            result.success(true)
                        } catch (error: Exception) {
                            contentResolver.delete(uri, null, null)
                            throw error
                        }
                    } catch (error: Exception) {
                        result.error("save_media_failed", error.message, null)
                    }
                    return@setMethodCallHandler
                }
                if (call.method == "chooseDocumentTarget") {
                    if (pendingTargetResult != null) {
                        result.error("busy", "Another save request is active.", null)
                        return@setMethodCallHandler
                    }
                    pendingTargetResult = result
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                        addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                        type = call.argument<String>("mimeType") ?: "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, call.argument<String>("suggestedName") ?: "download")
                    }, createDocumentRequestCode)
                    return@setMethodCallHandler
                }
                if (call.method == "saveToDocumentTarget") {
                    val sourcePath = call.argument<String>("sourcePath")
                    val targetUri = call.argument<String>("targetUri")
                    if (sourcePath == null || targetUri == null || !File(sourcePath).exists()) {
                        result.error("source_missing", "Downloaded file is no longer available.", null)
                        return@setMethodCallHandler
                    }
                    try {
                        contentResolver.openOutputStream(Uri.parse(targetUri), "w")!!.use { output ->
                            File(sourcePath).inputStream().use { input -> input.copyTo(output) }
                        }
                        result.success(true)
                    } catch (error: Exception) {
                        result.error("save_failed", error.message, null)
                    }
                    return@setMethodCallHandler
                }
                result.notImplemented()
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaPickerChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "cleanupPickedMedia") {
                    val cachePath = cacheDir.canonicalPath + File.separator
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    paths.forEach { path ->
                        runCatching {
                            val candidate = File(path)
                            if (candidate.canonicalPath.startsWith(cachePath) &&
                                candidate.name.startsWith("quick-media-")) {
                                candidate.delete()
                            }
                        }
                    }
                    result.success(true)
                    return@setMethodCallHandler
                }
                if (call.method != "pickImagesAndVideos") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (pendingMediaResult != null) {
                    result.error("busy", "Another media selection is active.", null)
                    return@setMethodCallHandler
                }
                pendingMediaResult = result
                val pickerIntent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
                }
                startActivityForResult(pickerIntent, pickMediaRequestCode)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, tailscaleChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "isTailscaleActive") {
                    val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    val tailscaleUid = runCatching {
                        packageManager.getApplicationInfo("com.tailscale.ipn", 0).uid
                    }.getOrNull()
                    val tailscaleActive = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                        tailscaleUid != null && connectivity.allNetworks.any { network ->
                            val capabilities = connectivity.getNetworkCapabilities(network)
                            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true &&
                                capabilities.ownerUid == tailscaleUid
                    }
                    result.success(tailscaleActive)
                    return@setMethodCallHandler
                }
                if (call.method != "openTailscale") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val launchIntent = packageManager.getLaunchIntentForPackage("com.tailscale.ipn")
                if (launchIntent == null) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                try {
                    startActivity(launchIntent)
                    result.success(true)
                } catch (_: Exception) {
                    result.success(false)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, transferServiceChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start", "update" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 41004)
                        }
                        val intent = Intent(this, TransferForegroundService::class.java).apply {
                            action = if (call.method == "start") {
                                TransferForegroundService.ACTION_START
                            } else {
                                TransferForegroundService.ACTION_UPDATE
                            }
                            putExtra(TransferForegroundService.EXTRA_CURRENT, call.argument<Int>("current") ?: 0)
                            putExtra(TransferForegroundService.EXTRA_TOTAL, call.argument<Int>("total") ?: 0)
                            putExtra(TransferForegroundService.EXTRA_TASKS, call.argument<Int>("tasks") ?: 1)
                        }
                        if (call.method == "start" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    }
                    "stop" -> {
                        // Queue an explicit stop command instead of cancelling
                        // the service before its first onStartCommand.  The
                        // latter races with fast photo transfers and causes
                        // ForegroundServiceDidNotStartInTimeException.
                        startService(Intent(this, TransferForegroundService::class.java).apply {
                            action = TransferForegroundService.ACTION_STOP
                        })
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

}

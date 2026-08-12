package com.jet2drop.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
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
    private val createDocumentRequestCode = 41002
    private val pickMediaRequestCode = 41003
    private var pendingSourcePath: String? = null
    private var pendingResult: MethodChannel.Result? = null
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
            targetCallback.success(if (resultCode == Activity.RESULT_OK) data?.data?.toString() else null)
            return
        }
        val sourcePath = pendingSourcePath
        val callback = pendingResult
        pendingSourcePath = null
        pendingResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null || sourcePath == null) {
            callback?.success(false)
            return
        }
        try {
            contentResolver.openOutputStream(data.data!!, "w")!!.use { output ->
                File(sourcePath).inputStream().use { input -> input.copyTo(output) }
            }
            callback?.success(true)
        } catch (error: Exception) {
            callback?.error("save_failed", error.message, null)
        }
    }

    private fun copyPickedMediaToCache(uri: android.net.Uri): String {
        val displayName = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
            ?.replace(Regex("[\\\\/:*?\"<>|]"), "_")
            ?: "media"
        val target = File(cacheDir, "quick-media-${UUID.randomUUID()}-$displayName")
        contentResolver.openInputStream(uri)?.use { input ->
            target.outputStream().use { output -> input.copyTo(output) }
        } ?: error("Unable to read selected media")
        return target.absolutePath
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                    if (pendingTargetResult != null || pendingResult != null) {
                        result.error("busy", "Another save request is active.", null)
                        return@setMethodCallHandler
                    }
                    pendingTargetResult = result
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
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
                if (call.method != "saveDocument") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (pendingResult != null) {
                    result.error("busy", "Another save request is active.", null)
                    return@setMethodCallHandler
                }
                val sourcePath = call.argument<String>("sourcePath")
                val suggestedName = call.argument<String>("suggestedName") ?: "download"
                val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                if (sourcePath == null || !File(sourcePath).exists()) {
                    result.error("source_missing", "Downloaded file is no longer available.", null)
                    return@setMethodCallHandler
                }
                pendingSourcePath = sourcePath
                pendingResult = result
                startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mimeType
                    putExtra(Intent.EXTRA_TITLE, suggestedName)
                }, createDocumentRequestCode)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaPickerChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "pickImagesAndVideos") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (pendingMediaResult != null) {
                    result.error("busy", "Another media selection is active.", null)
                    return@setMethodCallHandler
                }
                pendingMediaResult = result
                startActivityForResult(Intent(Intent.ACTION_PICK).apply {
                    setDataAndType(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "image/*")
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
                }, pickMediaRequestCode)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, tailscaleChannelName)
            .setMethodCallHandler { call, result ->
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
    }

}

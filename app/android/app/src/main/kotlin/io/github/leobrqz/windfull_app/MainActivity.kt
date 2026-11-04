package io.github.leobrqz.windfull_app

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private val updateChannel = "windfull/updates"
    private val apkName = "Windfull-Android-universal-release.apk"
    private val packageNameExpected = "io.github.leobrqz.windfull_app"
    private val preferences by lazy { getSharedPreferences("windfull_updates", Context.MODE_PRIVATE) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannel)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "getDeviceInfo" -> result.success(deviceInfo())
                        "canInstallPackages" -> result.success(
                            Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls(),
                        )
                        "getPendingDownload" -> result.success(pendingDownload())
                        "enqueueDownload" -> result.success(enqueueDownload(call.arguments as? Map<*, *>))
                        "getDownloadState" -> result.success(downloadState(call.arguments as? Map<*, *>))
                        "cancelDownload" -> {
                            val id = call.arguments as? Long ?: (call.arguments as? Int)?.toLong()
                                ?: throw UpdateFailure("invalid_arguments")
                            cancelDownload(id)
                            result.success(null)
                        }
                        "installDownload" -> result.success(installDownload(call.arguments as? Map<*, *>))
                        "openReleasePage" -> {
                            val url = call.arguments as? String ?: throw UpdateFailure("invalid_arguments")
                            openReleasePage(url)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: UpdateFailure) {
                    result.error(error.code, error.message, null)
                } catch (_: Exception) {
                    result.error("update_failed", "The update operation failed.", null)
                }
            }
    }

    private fun deviceInfo(): Map<String, Any> {
        val installed = packageManager.getPackageInfo(packageName, signingFlags())
        return mapOf(
            "packageName" to packageName,
            "versionName" to (installed.versionName ?: "0.0.0"),
            "versionCode" to versionCode(installed),
            "sdkInt" to Build.VERSION.SDK_INT,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "signerSha256" to signerDigests(installed),
        )
    }

    private fun pendingDownload(): Map<String, Any>? {
        val raw = preferences.getString("candidate", null) ?: return null
        val id = preferences.getLong("download_id", -1L)
        if (id < 0L) return null
        val candidate = JSONObject(raw)
        val info = packageManager.getPackageInfo(packageName, 0)
        if (candidate.optInt("versionCode", Int.MAX_VALUE) <= versionCode(info)) {
            clearPending()
            return null
        }
        return mapOf("downloadId" to id, "candidate" to jsonMap(candidate))
    }

    private fun enqueueDownload(arguments: Map<*, *>?): Map<String, Any> {
        val candidate = candidateFrom(arguments)
        val request = DownloadManager.Request(Uri.parse(candidate.url)).apply {
            setTitle("WindFull ${candidate.version}")
            setDescription("Baixando a atualização aprovada")
            setMimeType("application/vnd.android.package-archive")
            setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            setAllowedOverMetered(true)
            setAllowedOverRoaming(false)
            setDestinationInExternalFilesDir(
                this@MainActivity,
                Environment.DIRECTORY_DOWNLOADS,
                apkName,
            )
        }
        val manager = getSystemService(DownloadManager::class.java)
        val id = manager.enqueue(request)
        preferences.edit()
            .putLong("download_id", id)
            .putString("candidate", JSONObject(candidate.toMap()).toString())
            .apply()
        return mapOf("downloadId" to id)
    }

    private fun downloadState(arguments: Map<*, *>?): Map<String, Any> {
        val args = arguments ?: throw UpdateFailure("invalid_arguments")
        val id = args["downloadId"] as? Long
            ?: (args["downloadId"] as? Int)?.toLong()
            ?: throw UpdateFailure("invalid_arguments")
        val candidate = candidateFrom(args["candidate"] as? Map<*, *>)
        val query = DownloadManager.Query().setFilterById(id)
        val cursor = getSystemService(DownloadManager::class.java).query(query)
            ?: throw UpdateFailure("download_missing")
        cursor.use {
            if (!it.moveToFirst()) throw UpdateFailure("download_missing")
            val status = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            val received = it.getLong(it.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
            val total = it.getLong(it.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
            return when (status) {
                DownloadManager.STATUS_SUCCESSFUL -> {
                    validateDownloadedApk(candidate)
                    mapOf("status" to "complete", "downloadedBytes" to received, "totalBytes" to total)
                }
                DownloadManager.STATUS_FAILED -> {
                    clearPending()
                    mapOf("status" to "failed")
                }
                DownloadManager.STATUS_PENDING,
                DownloadManager.STATUS_RUNNING,
                DownloadManager.STATUS_PAUSED -> mapOf(
                    "status" to "running",
                    "downloadedBytes" to received,
                    "totalBytes" to total,
                )
                else -> mapOf("status" to "failed")
            }
        }
    }

    private fun cancelDownload(id: Long) {
        getSystemService(DownloadManager::class.java).remove(id)
        clearPending()
    }

    private fun installDownload(arguments: Map<*, *>?): String {
        val args = arguments ?: throw UpdateFailure("invalid_arguments")
        val id = args["downloadId"] as? Long
            ?: (args["downloadId"] as? Int)?.toLong()
            ?: throw UpdateFailure("invalid_arguments")
        val candidate = candidateFrom(args["candidate"] as? Map<*, *>)
        val manager = getSystemService(DownloadManager::class.java)
        val cursor = manager.query(DownloadManager.Query().setFilterById(id))
            ?: throw UpdateFailure("download_missing")
        val complete = cursor.use {
            it.moveToFirst() &&
                it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)) == DownloadManager.STATUS_SUCCESSFUL
        }
        if (!complete) throw UpdateFailure("download_incomplete")
        val apk = validateDownloadedApk(candidate)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            return "permissionRequired"
        }
        val contentUri = FileProvider.getUriForFile(
            this,
            "$packageName.updates",
            apk,
        )
        startActivity(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(contentUri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            },
        )
        return "installerOpened"
    }

    private fun validateDownloadedApk(candidate: UpdateCandidate): File {
        val apk = File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), apkName)
        if (!apk.isFile || apk.length() != candidate.size || apk.length() > 200L * 1024 * 1024) {
            throw UpdateFailure("integrity", "The APK size does not match release metadata.")
        }
        if (sha256(apk) != candidate.sha256) throw UpdateFailure("integrity", "The APK checksum is invalid.")
        val flags = signingFlags()
        val archive = packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
            ?: throw UpdateFailure("integrity", "Android could not inspect the APK.")
        if (archive.packageName != packageNameExpected ||
            versionCode(archive) != candidate.versionCode) {
            throw UpdateFailure("integrity", "The APK package or version does not match the release.")
        }
        val archiveSigners = signerDigests(archive)
        val installedSigners = signerDigests(packageManager.getPackageInfo(packageName, flags))
        if (archiveSigners != listOf(candidate.signerSha256) ||
            installedSigners != archiveSigners) {
            throw UpdateFailure("signature", "The APK signing key does not match this installation.")
        }
        return apk
    }

    @Suppress("DEPRECATION")
    private fun signingFlags(): Int = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        PackageManager.GET_SIGNING_CERTIFICATES
    } else {
        PackageManager.GET_SIGNATURES
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Int = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        info.longVersionCode.toInt()
    } else {
        info.versionCode
    }

    private fun signerDigests(info: PackageInfo): List<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners?.toList().orEmpty()
        } else {
            @Suppress("DEPRECATION")
            info.signatures?.toList().orEmpty()
        }
        if (signatures.isEmpty()) throw UpdateFailure("signature", "The APK signing certificate is unavailable.")
        return signatures.map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                .joinToString("") { byte -> "%02x".format(byte) }
        }.sorted()
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
    }

    private fun candidateFrom(raw: Map<*, *>?): UpdateCandidate {
        if (raw == null) throw UpdateFailure("invalid_arguments")
        fun string(key: String) = raw[key] as? String ?: throw UpdateFailure("invalid_arguments")
        fun integer(key: String) = (raw[key] as? Number)?.toLong()?.takeIf { it > 0 }
            ?: throw UpdateFailure("invalid_arguments")
        val version = string("version")
        val versionCode = integer("versionCode")
        val size = integer("size")
        val sha = string("sha256").lowercase()
        val signer = string("signerSha256").lowercase()
        val url = string("downloadUrl")
        val expected = "https://github.com/leobrqz/Windfull/releases/download/v$version/$apkName"
        if (!Regex("^\\d+\\.\\d+\\.\\d+$").matches(version) ||
            versionCode > Int.MAX_VALUE || size > 200L * 1024 * 1024 ||
            !Regex("^[a-f0-9]{64}$").matches(sha) ||
            !Regex("^[a-f0-9]{64}$").matches(signer) || url != expected ||
            string("releaseUrl") != "https://github.com/leobrqz/Windfull/releases/tag/v$version") {
            throw UpdateFailure("invalid_metadata")
        }
        return UpdateCandidate(version, versionCode.toInt(), size, sha, signer, url)
    }

    private fun openReleasePage(raw: String) {
        if (!Regex("^https://github\\.com/leobrqz/Windfull/releases/tag/v\\d+\\.\\d+\\.\\d+$").matches(raw)) {
            throw UpdateFailure("invalid_metadata")
        }
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(raw)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun clearPending() {
        preferences.edit().remove("candidate").remove("download_id").apply()
    }

    private fun jsonMap(json: JSONObject): Map<String, Any?> =
        json.keys().asSequence().associateWith { key -> json.get(key) }

    private data class UpdateCandidate(
        val version: String,
        val versionCode: Int,
        val size: Long,
        val sha256: String,
        val signerSha256: String,
        val url: String,
    ) {
        fun toMap() = mapOf(
            "version" to version,
            "versionCode" to versionCode,
            "size" to size,
            "sha256" to sha256,
            "signerSha256" to signerSha256,
            "downloadUrl" to url,
            "releaseUrl" to "https://github.com/leobrqz/Windfull/releases/tag/v$version",
            "notes" to "",
        )
    }

    private class UpdateFailure(val code: String, message: String = "Update validation failed.") : Exception(message)
}

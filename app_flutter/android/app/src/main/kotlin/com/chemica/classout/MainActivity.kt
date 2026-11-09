package com.chemica.classout

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.os.Bundle
import android.provider.CalendarContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

class MainActivity : FlutterActivity() {
    companion object {
        private const val CALENDAR_CHANNEL = "classout/calendar"
        private const val CALENDAR_PERMISSION_REQUEST = 401
        private const val TAG_MARK = "ClassOUT"
    }

    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALENDAR_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermission" -> requestCalendarPermission(result)
                    "sync" -> {
                        if (!hasCalendarPermission()) {
                            result.error("permission", "calendar permission denied", null)
                        } else {
                            val events = call.argument<List<*>>("events") ?: emptyList<Any>()
                            result.success(syncEvents(events))
                        }
                    }
                    "clear" -> {
                        if (!hasCalendarPermission()) {
                            result.error("permission", "calendar permission denied", null)
                        } else {
                            result.success(clearEvents())
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasCalendarPermission(): Boolean =
        checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED &&
            checkSelfPermission(Manifest.permission.WRITE_CALENDAR) == PackageManager.PERMISSION_GRANTED

    private fun requestCalendarPermission(result: MethodChannel.Result) {
        if (hasCalendarPermission()) {
            result.success(true)
            return
        }
        pendingPermissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR),
            CALENDAR_PERMISSION_REQUEST
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != CALENDAR_PERMISSION_REQUEST) return
        val ok = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        pendingPermissionResult?.success(ok)
        pendingPermissionResult = null
    }

    private fun writableCalendarId(): Long? {
        val projection = arrayOf(CalendarContract.Calendars._ID)
        val selection = "${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL} >= ?"
        val args = arrayOf("${CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR}")
        contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            selection,
            args,
            null
        )?.use { c ->
            if (c.moveToFirst()) return c.getLong(0)
        }
        return null
    }

    private fun clearEvents(): Int {
        val calId = writableCalendarId() ?: return -1
        val selection = "${CalendarContract.Events.CALENDAR_ID} = ? AND " +
            "${CalendarContract.Events.DESCRIPTION} LIKE ?"
        return contentResolver.delete(
            CalendarContract.Events.CONTENT_URI,
            selection,
            arrayOf("$calId", "$TAG_MARK%")
        )
    }

    private fun syncEvents(events: List<*>): Int {
        val calId = writableCalendarId() ?: return -1
        clearEvents()
        var inserted = 0
        for (raw in events) {
            val e = raw as? Map<*, *> ?: continue
            val title = e["title"] as? String ?: continue
            val start = (e["startMs"] as? Number)?.toLong() ?: continue
            val end = (e["endMs"] as? Number)?.toLong() ?: continue
            if (end <= start) continue
            val desc = (e["description"] as? String) ?: TAG_MARK
            val leadMin = (e["leadMin"] as? Number)?.toInt() ?: 15
            val values = ContentValues().apply {
                put(CalendarContract.Events.CALENDAR_ID, calId)
                put(CalendarContract.Events.TITLE, title)
                put(CalendarContract.Events.DESCRIPTION,
                    if (desc.startsWith(TAG_MARK)) desc else "$TAG_MARK · $desc")
                put(CalendarContract.Events.DTSTART, start)
                put(CalendarContract.Events.DTEND, end)
                put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
                put(CalendarContract.Events.HAS_ALARM, 1)
            }
            try {
                val uri = contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
                if (uri != null) {
                    inserted++
                    val eventId = uri.lastPathSegment?.toLongOrNull()
                    if (eventId != null && leadMin > 0) {
                        val reminder = ContentValues().apply {
                            put(CalendarContract.Reminders.EVENT_ID, eventId)
                            put(CalendarContract.Reminders.MINUTES, leadMin)
                            put(CalendarContract.Reminders.METHOD,
                                CalendarContract.Reminders.METHOD_ALERT)
                        }
                        contentResolver.insert(CalendarContract.Reminders.CONTENT_URI, reminder)
                    }
                }
            } catch (_: Exception) {
                // 单个事件失败不阻断整批
            }
        }
        return inserted
    }
}

package app.oneone.one_one_app

import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.database.FirebaseDatabase

/**
 * Conclusive nudge delivery status for the sender — written **directly to
 * RTDB by the receiving device**. No Render/backend hop.
 *
 * Path: `userNudgeDeliveries/{senderUserId}/{eventId}/{recipientUserId}`
 * Sender listens / gets this path via the Firebase SDK.
 */
object NudgeDeliveryStatusRtdb {
    private val database: FirebaseDatabase by lazy {
        FirebaseDatabase.getInstance(FirebaseApp.getInstance(), mediaVolumeDatabaseUrl)
    }

    /**
     * Persist played/failed for this device. Safe to call from any thread;
     * Firebase SDK handles the write asynchronously.
     */
    fun write(
        senderUserId: String?,
        eventId: String?,
        groupId: String?,
        kind: String?,
        status: String,
        reason: String? = null,
        attention: String? = null,
        recipientName: String? = null,
    ) {
        val sender = senderUserId?.trim().orEmpty()
        val event = eventId?.trim().orEmpty()
        val group = groupId?.trim().orEmpty()
        if (sender.isEmpty() || event.isEmpty()) {
            DeviceLog.warn(
                "NudgeService",
                "Delivery RTDB write skipped: missing sender/event " +
                    "status=$status eventId=${event.ifEmpty { "-" }} " +
                    "senderUserId=${sender.ifEmpty { "-" }}",
                groupId = group.ifEmpty { null },
            )
            return
        }
        if (status != "played" && status != "failed") {
            DeviceLog.warn(
                "NudgeService",
                "Delivery RTDB write skipped: invalid status=$status eventId=$event",
                groupId = group.ifEmpty { null },
            )
            return
        }

        val recipientUserId = FirebaseAuth.getInstance().currentUser?.uid?.trim().orEmpty()
        if (recipientUserId.isEmpty()) {
            DeviceLog.warn(
                "NudgeService",
                "Delivery RTDB write skipped: no signed-in user eventId=$event",
                groupId = group.ifEmpty { null },
            )
            return
        }

        val name = recipientName?.trim()?.takeIf { it.isNotEmpty() }
            ?: FirebaseAuth.getInstance().currentUser?.displayName?.trim()?.takeIf { it.isNotEmpty() }
            ?: "friend"

        val normalizedKind = when (kind?.trim()) {
            VoiceNudgeContract.kindRing, "ring_nudge" -> "ring_nudge"
            VoiceNudgeContract.kindPush, "nudge" -> "nudge"
            else -> "voice_nudge"
        }

        val path = "userNudgeDeliveries/$sender/$event/$recipientUserId"
        val payload = mutableMapOf<String, Any>(
            "eventId" to event,
            "groupId" to group,
            "kind" to normalizedKind,
            "senderUserId" to sender,
            "recipientUserId" to recipientUserId,
            "recipientName" to name,
            "status" to status,
            "recordedAt" to (System.currentTimeMillis() / 1000L),
        )
        if (!reason.isNullOrBlank()) payload["reason"] = reason
        if (!attention.isNullOrBlank()) payload["attention"] = attention

        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[NUDGE-RTDB] Writing delivery status=$status path=$path",
        )
        DeviceLog.info(
            "NudgeService",
            "Delivery RTDB write start status=$status eventId=$event " +
                "senderUserId=$sender recipientUserId=$recipientUserId " +
                "reason=${reason ?: "-"} attention=${attention ?: "-"}",
            groupId = group.ifEmpty { null },
        )

        database.reference.child(path).updateChildren(payload)
            .addOnSuccessListener {
                DeviceLog.info(
                    "NudgeService",
                    "Delivery RTDB write ok status=$status eventId=$event " +
                        "recipientUserId=$recipientUserId",
                    groupId = group.ifEmpty { null },
                )
            }
            .addOnFailureListener { error ->
                Log.w(
                    VoiceNudgeDiagnostics.tag,
                    "[NUDGE-RTDB] Write failed status=$status eventId=$event: ${error.message}",
                )
                DeviceLog.warn(
                    "NudgeService",
                    "Delivery RTDB write failed status=$status eventId=$event " +
                        "detail=${error.message ?: "-"}",
                    groupId = group.ifEmpty { null },
                )
            }
    }
}

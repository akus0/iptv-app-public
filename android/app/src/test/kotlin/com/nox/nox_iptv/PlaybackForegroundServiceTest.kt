package com.nox.nox_iptv

import android.content.Intent
import android.app.Notification
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PlaybackForegroundServiceTest {
    @After fun cleanup() { PlaybackForegroundService.onAction = null }

    @Test fun promotesBeforeProcessingAnyCommands() {
        val controller = Robolectric.buildService(PlaybackForegroundService::class.java).create()
        val service = controller.get()
        assertNotNull(shadowOf(service).lastForegroundNotification)
        // A cancelled startup still acknowledges Android's foreground deadline.
        service.onStartCommand(Intent().setAction(PlaybackForegroundService.SHUTDOWN), 0, 1)
        assertTrue(shadowOf(service).isStoppedBySelf)
        controller.destroy()
    }

    @Test fun mediaActionsKeepTheChannelTitleAndUseExistingPlayer() {
        val actions = mutableListOf<String>()
        PlaybackForegroundService.onAction = { actions.add(it) }
        val controller = Robolectric.buildService(PlaybackForegroundService::class.java).create()
        val service = controller.get()
        service.onStartCommand(Intent().putExtra("title", "Test channel")
            .putExtra("playing", true), 0, 1)
        service.onStartCommand(Intent().setAction("pause"), 0, 2)
        assertEquals(listOf("pause"), actions)
        assertEquals("Test channel", shadowOf(service).lastForegroundNotification
            .extras.getString(Notification.EXTRA_TITLE))
        service.onStartCommand(Intent().setAction(PlaybackForegroundService.SHUTDOWN), 0, 3)
        assertEquals(listOf("pause"), actions)
        assertTrue(shadowOf(service).isStoppedBySelf)
        controller.destroy()
    }
}

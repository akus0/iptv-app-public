package com.nox.nox_iptv

import org.junit.Assert.*
import org.junit.Test

class TvBackGestureTest {
    @Test fun clickNavigatesOnceAndDelayedReleaseIsNotAHold() {
        var clicks = 0; var holds = 0
        val key = TvBackGesture({ clicks++ }, { holds++ }).apply { enabled = true }
        assertTrue(key.down(0, 0)); assertTrue(key.up(false))
        assertEquals(1, clicks); assertEquals(0, holds)
        assertFalse(key.up(false))
        key.down(0, 0); key.up(false)
        assertEquals(2, clicks)
    }
    @Test fun heldBackSurvivesRouteChangeAndSwallowsItsRelease() {
        var clicks = 0; var holds = 0
        lateinit var key: TvBackGesture
        key = TvBackGesture({ clicks++ }, { holds++; key.enabled = false })
        key.enabled = true
        key.down(0, 0); key.down(1, 450)
        assertEquals(0, holds)
        key.down(4, 700); key.down(5, 750)
        assertTrue(key.up(false))
        assertEquals(1, holds); assertEquals(0, clicks)
        assertFalse(key.down(0, 0)); assertFalse(key.up(false))
    }
    @Test fun cancellationsAndCoveredRoutesDoNotNavigate() {
        var calls = 0
        val key = TvBackGesture({ calls++ }, { calls++ }).apply { enabled = true }
        key.down(0, 0); key.up(true)
        key.down(0, 0); key.cancel(); key.down(8, 1000); key.up(false)
        key.down(0, 0); key.enabled = false; key.down(8, 1000); key.up(false)
        assertEquals(0, calls)
        key.enabled = true; key.down(0, 0); key.up(false)
        assertEquals(1, calls)
    }
}

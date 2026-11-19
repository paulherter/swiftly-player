package de.paulherter.swiftly

import org.junit.Assert.assertEquals
import org.junit.Test

/** Back inside the hub's Server section climbs one level per press and leaves the hub only from the top. */
class HubBackTest {
    @Test fun serverPageLeavesTheHub() = assertEquals(LogsBack.NONE, logsBackStep(logsOpen = false, inText = false))
    @Test fun fileListGoesBackToTheServerPage() = assertEquals(LogsBack.CLOSE, logsBackStep(logsOpen = true, inText = false))
    @Test fun oneLogTextGoesBackToTheFileList() = assertEquals(LogsBack.TO_LIST, logsBackStep(logsOpen = true, inText = true))
    @Test fun threeLevelsNeedThreePresses() {
        var logs = true; var text = true; var presses = 0
        while (true) {
            when (logsBackStep(logs, text)) {
                LogsBack.NONE -> break
                LogsBack.TO_LIST -> text = false
                LogsBack.CLOSE -> logs = false
            }
            presses++
        }
        assertEquals(2, presses)
    }
}

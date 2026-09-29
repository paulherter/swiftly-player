package de.paulherter.swiftly

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BildImBildTest {
    @Test fun handyDarfWennDasGeraetKann() = assertTrue(bildImBildErlaubt(istFernseher = false, kannBildImBild = true))
    @Test fun handyOhneFunktionNicht() = assertFalse(bildImBildErlaubt(istFernseher = false, kannBildImBild = false))
    @Test fun fernseherNie() {
        assertFalse(bildImBildErlaubt(istFernseher = true, kannBildImBild = true))
        assertFalse(bildImBildErlaubt(istFernseher = true, kannBildImBild = false))
    }
}

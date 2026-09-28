import Testing
@testable import JellyfinKit

@Suite struct FesthaltetempoTests {
    @Test func nurWennAllesPasst() {
        #expect(Festhaltetempo.erlaubt(eingeschaltet: true, inGruppe: false, fremderAbspieler: false,
                                       laeuft: true, spult: false))
        #expect(!Festhaltetempo.erlaubt(eingeschaltet: false, inGruppe: false, fremderAbspieler: false,
                                        laeuft: true, spult: false))
        #expect(!Festhaltetempo.erlaubt(eingeschaltet: true, inGruppe: true, fremderAbspieler: false,
                                        laeuft: true, spult: false))
        #expect(!Festhaltetempo.erlaubt(eingeschaltet: true, inGruppe: false, fremderAbspieler: true,
                                        laeuft: true, spult: false))
        #expect(!Festhaltetempo.erlaubt(eingeschaltet: true, inGruppe: false, fremderAbspieler: false,
                                        laeuft: false, spult: false))
        #expect(!Festhaltetempo.erlaubt(eingeschaltet: true, inGruppe: false, fremderAbspieler: false,
                                        laeuft: true, spult: true))
    }

    @Test func loslassenGibtDasAlteTempoZurueck() {
        #expect(Festhaltetempo.danach(vorher: 1.25) == 1.25)
        #expect(Festhaltetempo.danach(vorher: 0) == 1)
        #expect(Festhaltetempo.tempo == 2)
    }
}

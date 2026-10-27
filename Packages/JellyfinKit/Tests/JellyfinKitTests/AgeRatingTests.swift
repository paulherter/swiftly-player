import Testing
@testable import JellyfinKit

@Suite("Altersfreigabe")
struct AgeRatingTests {

    @Test("age18+ und age18 werden zu 18+")
    func agePrefix() {
        #expect(AgeRating.text("age18+") == "18+")
        #expect(AgeRating.text("age18") == "18+")
        #expect(AgeRating.text("Age 16+") == "16+")
        #expect(AgeRating.text("age-6") == "6+")
    }

    @Test("Andere Systeme bleiben, wie der Server sie schickt")
    func otherSystems() {
        #expect(AgeRating.text("PG-13") == "PG-13")
        #expect(AgeRating.text("FSK 12") == "FSK 12")
        #expect(AgeRating.text("TV-MA") == "TV-MA")
        #expect(AgeRating.text("18+") == "18+")
    }

    @Test("Leer oder ohne Zahl")
    func empty() {
        #expect(AgeRating.text(nil) == nil)
        #expect(AgeRating.text("  ") == nil)
        #expect(AgeRating.text("ageless") == "ageless")
    }
}

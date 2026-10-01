import SwiftUI
import JellyfinKit

/// Eine Kachel in der Reihe „Extras" — auf der Filmseite und unter der Serie.
/// Tippen spielt das Extra ab, wie jeden anderen Titel: derselbe Plan,
/// Direct Play, nie Transkodieren.
struct Extrakachel: View {
    let model: AppModel
    let extra: Item
    @Binding var bereitet: Bool
    let fehlt: () -> Void
    let abspielen: (Abspielwunsch) -> Void

    var body: some View {
        Button {
            Stil.ruck(.mittel)
            Abspielwunsch.starten(extra, model: model, bereitet: $bereitet,
                                  fehlt: fehlt, abspielen: abspielen)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Bild(url: model.imageURL(for: extra, maxHeight: 300),
                     breite: 210, hoehe: 118)
                Text(extra.name)
                    .font(Stil.kachel).foregroundStyle(Stil.schrift).lineLimit(1)
                // Ein Extra ohne Laufzeit meldet 0, nicht nichts —
                // ohne die Regel stünde dort „0 Min.".
                if Anzeigeregeln.laufzeitZeigen(sekunden: extra.runtimeSeconds),
                   let s = extra.runtimeSeconds {
                    Text(laufzeit(s)).font(Stil.klein)
                        .foregroundStyle(Stil.schriftSehrLeise)
                }
            }
            .frame(width: 210, alignment: .leading)
        }
        .buttonStyle(Stil.Druckknopf())
        .disabled(bereitet)
    }
}

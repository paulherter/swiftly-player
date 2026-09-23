import JellyfinKit
import SwiftUI

/// Profil und Einstellungen.
///
/// **Zwei Spalten: links die Bereiche, rechts ihre Zeilen.** So bauen Apples
/// eigene tvOS-Einstellungen auf, und der Grund ist der Weg: eine einzige
/// lange Liste zwingt zum Durchwandern, drei Spalten mit Chips nebeneinander
/// (so stand es hier zuerst) sind gar kein Aufbau, sondern eine Ablage.
///
/// Die Gruppen sind die der iPhone-Fassung — dort drei Seiten hintereinander
/// (Profil, Einstellungen, Wiedergabe), hier nebeneinander, weil Breite da
/// ist und jeder gesparte Sprung auf der Fernbedienung zählt.
struct ProfilView: View {
    @AppStorage("bildrateAnpassen") private var bildrateAnpassen = true
    let model: AppModel

    @State private var bereich: Bereichswahl = .wiedergabe
    /// Welche Wertzeile gerade ihre Auswahl zeigt.
    @State private var offen: String?
    @State private var pruefung: String?
    /// Zeigt Quick Connect, um ein weiteres Konto aufzunehmen.
    @State private var kontoAufnehmen = false
    /// Ein zweiter Jellyfin — Adresse, dann Quick Connect.
    @State private var serverAufnehmen = false
    /// Eigene Header des aktiven Servers (Issue #4).
    @State private var eigeneKoepfe = false
    /// Seerr anbinden — als eigene Seite ueber allem: drei Felder und eine
    /// Bildschirmtastatur brauchen den Platz, den eine Zeile nicht hat.
    @State private var seerrOffen = false
    /// Trakt verbinden — Code und QR-Code brauchen dieselbe ganze Seite.
    @State private var traktOffen = false
    @State private var gemeinschaftsziel: Gemeinschaftsziel?

    /// **Erst ansehen, dann hineingehen.** Wandert der Fokus links durch die
    /// Bereiche, zeigt die rechte Seite den jeweiligen schon — gedimmt, damit
    /// man sieht, dass man noch nicht drin ist. Ein Druck auf OK geht hinein,
    /// der Fokus steht dann auf der obersten Zeile. Zurück führt links auf
    /// denselben Bereich; erst ein zweites Zurück verlässt die Seite.
    ///
    /// Vorher schaltete erst der Druck den Bereich um, und rechts war sofort
    /// alles fokussierbar: ein Schritt nach rechts landete irgendwo in der
    /// Liste, geometrisch, und zurück ging es nur mit Links — Zurück verließ
    /// gleich die ganze Seite.
    @FocusState private var links: Bereichswahl?
    @State private var drin = false
    @FocusState private var rechts: Rechtsziel?
    /// Nur die oberste Zeile rechts wird gezielt angesprungen; alle übrigen
    /// tragen `.weiter`, damit sie dieselbe Bindung haben.
    private enum Rechtsziel { case oben, weiter }

    /// Alle Genres, die der Server kennt — für „Genre hinzufügen".
    @State private var alleGattungen: [String] = []
    /// **„Keins offen" war eine Luege, wenn der Server nicht geantwortet
    /// hatte.** In eine Einstellungszeile passt kein ganzseitiger Hinweis, in
    /// ihren Wert aber sehr wohl derselbe Wortlaut wie ueberall sonst.
    @State private var gattungenGestoert = false

    private var freieGattungen: [String] {
        alleGattungen.filter { !model.startGenres.contains($0) }
    }

    /// Welche festen Reihen es gerade gibt: getrennt die neuen Filme und
    /// Serien einzeln, sonst die gemeinsame.
    private var sichtbareReihen: [Startreihe] {
        model.startReihen.filter { $0.passt(getrennt: model.neuzugangGetrennt) }
    }

    /// Verschoben wird in der sichtbaren Liste. Was gerade nicht zu sehen ist
    /// — die gemeinsame Reihe, wenn getrennt ist, oder umgekehrt —, hängt
    /// hinten an und kommt beim Umschalten dort wieder zum Vorschein.
    private func verschieben(_ reihe: Startreihe, um schritt: Int) {
        var sichtbar = sichtbareReihen
        guard let von = sichtbar.firstIndex(of: reihe) else { return }
        let nach = von + schritt
        guard sichtbar.indices.contains(nach) else { return }
        withAnimation(Stil.einblenden) {
            sichtbar.swapAt(von, nach)
            model.startReihen = sichtbar + model.startReihen.filter { !sichtbar.contains($0) }
        }
    }

    enum Bereichswahl: String, CaseIterable, Identifiable {
        case wiedergabe, sprachen, darstellung, integration, server, konto, gemeinschaft
        var id: String { rawValue }
        var name: LocalizedStringKey {
            switch self {
            case .wiedergabe:  "Wiedergabe"
            case .sprachen:    "Sprachen"
            case .darstellung: "Darstellung"
            case .integration: "Integration"
            case .server:      "Server"
            case .konto:       "Konto"
            case .gemeinschaft: "Swiftly"
            }
        }
    }

    var body: some View {
        seite
            // **Zugeklappt zurückkommen.** Wer die Einstellungen verlässt und
            // später wiederkommt, findet sonst noch die Auswahl von vorhin
            // offen — und eine halb aufgeklappte Liste sieht aus wie ein
            // Zustand, den man selbst hinterlassen hat, ohne es zu wissen.
            .onDisappear { offen = nil }
            // Dasselbe beim Wechsel des Bereichs: die Zeile, die offen war,
            // gibt es auf der neuen Seite gar nicht mehr.
            .onChange(of: bereich) { _, _ in offen = nil }
            .onChange(of: links) { _, neu in
                guard let neu else { return }
                bereich = neu
                drin = false
            }
            .defaultFocus($links, bereich)
            // Einmal je Besuch: die Liste der Genres des Servers, für
            // „Genre hinzufügen".
            .task {
                let geholt = await model.gattungen()
                gattungenGestoert = geholt == nil
                if let geholt { alleGattungen = geholt }
            }
    }

    private var seite: some View {
        VStack(alignment: .leading, spacing: 0) {
            // **Kein Kopf über den Spalten.** Hier stand das Konto groß über
            // der ganzen Breite — Name, Server, Fassung. Es steht jetzt
            // links über den Bereichen: links liegt, was man wählt (wer, und
            // welcher Bereich), rechts, was man einstellt. Die rechte Spalte
            // beginnt dadurch oben, und alle acht Zeilen von „Wiedergabe"
            // stehen ohne Scrollen da. Entschieden am 11.09.2026.
            HStack(alignment: .top, spacing: 72) {
                VStack(alignment: .leading, spacing: 0) {
                    kontoblock
                    // **Eine Linie statt eines zweiten Kastens.**
                    //
                    // Sie sagt, wo „wer" aufhoert und „wo" anfaengt. Ein
                    // Kasten haette dasselbe gesagt — und dabei so
                    // ausgesehen wie die Liste darunter und die Karte
                    // rechts.
                    Blattlinie()
                        .padding(.leading, 26)
                        .padding(.vertical, 32)
                    Gruppentitel(text: "Bereiche")
                    ForEach(Bereichswahl.allCases) { b in
                        Button(b.name) {
                            bereich = b
                            hineingehen()
                        }
                        .buttonStyle(BereichsStil(an: bereich == b, ruht: drin))
                        .focused($links, equals: b)
                    }
                }
                // **Auf volle Hoehe, und zwar wegen des Fokusmotors.**
                //
                // Er bewegt den Fokus nur, wenn in der gedrueckten Richtung
                // etwas *angrenzend* und fokussierbar ist. Die Spalte war nur
                // so hoch wie ihr Inhalt; klappt rechts eine Wertzeile auf,
                // die tiefer sitzt als diese Hoehe — „Vorspulen" ist die
                // zweite —, liegt links von den Chips nichts mehr, und Links
                // tat gar nichts. Der Fokus sass fest.
                //
                // Von Koney am 03.09.2026 gemeldet. Sichtbar aendert sich
                // nichts: der Inhalt bleibt oben, nur der Abschnitt reicht
                // jetzt bis unten.
                .frame(width: 460, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .focusSection()

                // **Der Leser ist die ganze Bewegung.**
                //
                // Klappt eine Zeile auf, wird sie hierhin gescrollt — und das
                // Scrollen selbst ist die weiche Bewegung, die tvOS ohnehin
                // mitbringt. Vorher habe ich die Spalte von Hand verschoben;
                // das war hart und musste die Höhe der Auswahl raten. Hier
                // rät niemand: die Liste ist so lang, wie sie ist, und der
                // Leser bringt die aufgeklappte Zeile ins Bild.
                ScrollViewReader { leser in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Gruppentitel(text: bereich.name)
                            // **Auf einer Karte, wie auf iPhone, iPad und Mac.**
                            // Flach auf dem Grund war das die letzte Liste der
                            // App aus der Zeit vor den Karten.
                            // **Beschnitten auf die Karte, sonst stehen die
                            // Namen vor ihrem Kasten.**
                            //
                            // Klappt eine Wertzeile auf, wachsen Karte und
                            // Liste in 0,28 s auf ihre neue Hoehe — die
                            // eingefuegten Namen sind aber sofort voll da,
                            // mit ihrer eigenen, unanimierten Hoehe. Ohne
                            // Maske zeichnen sie ueber den unteren Rand der
                            // noch kleinen Karte hinaus und stehen einen
                            // Wimpernschlag auf dem nackten Grund.
                            //
                            // Der Beschnitt haengt an derselben Flaeche wie
                            // die Fuellung, also an derselben wachsenden
                            // Hoehe: der Inhalt geht mit dem Kasten auf. Am
                            // 17.09. am Fernseher gemeldet.
                            //
                            // Vor der Fuellung, nicht danach — sonst wuerde
                            // der Beschnitt auch die Fuellung wegschneiden,
                            // und die Karte haette keinen Grund mehr.
                            VStack(alignment: .leading, spacing: 0) { zeilen }
                                .padding(10)
                                .clipShape(RoundedRectangle(cornerRadius: Stil.eckeKachel, style: .continuous))
                                .background(Stil.flaeche,
                                            in: RoundedRectangle(cornerRadius: Stil.eckeKachel, style: .continuous))
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                    .onChange(of: offen) { _, neu in
                        guard let neu else { return }
                        // Dieselbe Kurve und Dauer wie das Aufklappen —
                        // sonst laufen zwei Bewegungen gegeneinander.
                        withAnimation(.easeInOut(duration: 0.28)) {
                            leser.scrollTo(neu, anchor: .top)
                        }
                    }
                }
                // Gedimmt heißt: zu sehen, aber noch nicht dran. Gesperrt,
                // damit ein Schritt nach rechts nicht schon hineinführt —
                // hinein geht es mit OK.
                .opacity(drin ? 1 : 0.5)
                .disabled(!drin)
                .focusSection()
                .onExitCommand {
                    drin = false
                    links = bereich
                }
                // **Das Netz unter dem Sprung nach rechts.**
                //
                // `hineingehen` setzt den Fokus einen Lauf spaeter, weil die
                // Spalte im selben Lauf noch gesperrt ist. Kommt sie einen
                // Lauf spaeter noch immer nicht zum Zug, faengt das hier ab:
                // `onChange` laeuft, wenn der neue Zustand steht, und setzt
                // nach, falls rechts noch nichts den Fokus hat. Zweimal
                // dasselbe zu setzen schadet nicht.
                .onChange(of: drin) { _, jetzt in
                    if jetzt, rechts == nil { rechts = .oben }
                }
                .animation(.easeInOut(duration: 0.2), value: drin)
            }
        }
        .padding(.horizontal, Stil.randSeite)
        .padding(.vertical, Stil.randOben)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) {
            if let pruefung {
                Hinweisstreifen(text: pruefung) { self.pruefung = nil }
                    .padding(.top, Stil.randOben)
            }
        }
        // Seitlicher Rand: siehe `HomeView` — der Systemrand faellt weg,
        // damit `randSeite` nicht darauf sitzt und sich verdoppelt.
        .ignoresSafeArea(edges: .horizontal)
        // **Quick Connect, nicht ein neues Anmeldeformular.** Ein Name und
        // ein Passwort auf der Fernbedienung sind eine Zumutung; den Code
        // gibt es ohnehin, und `sitzungUebernehmen` nimmt die Sitzung seit
        // dem Kontenbund ins vorhandene Konto auf, statt es zu ersetzen.
        .fullScreenCover(isPresented: $kontoAufnehmen) {
            QuickConnectView(model: model) { kontoAufnehmen = false }
        }
        .fullScreenCover(isPresented: $eigeneKoepfe) {
            TVEigeneKoepfeSeite(model: model) { eigeneKoepfe = false }
        }
        .fullScreenCover(isPresented: $serverAufnehmen) {
            ServerAufnahmeView(model: model) { serverAufnehmen = false }
        }
        .fullScreenCover(isPresented: $seerrOffen) {
            SeerrAnbindenView(model: model, seerr: model.seerr) { seerrOffen = false }
        }
        .fullScreenCover(isPresented: $traktOffen) {
            TraktAnbindenView(trakt: model.trakt) { traktOffen = false }
        }
        .fullScreenCover(item: $gemeinschaftsziel) { ziel in
            Codeblatt(ziel: ziel) { gemeinschaftsziel = nil }
        }
    }

    /// Rechts hinein, Fokus auf die oberste Zeile.
    ///
    /// **Einen Lauf später.** Im selben Lauf ist die rechte Spalte noch
    /// gesperrt, und ein Fokus auf etwas Gesperrtes geht ins Leere.
    private func hineingehen() {
        drin = true
        DispatchQueue.main.async { rechts = .oben }
    }

    // MARK: Konto

    /// **Wer angemeldet ist — ohne Kasten drumherum.**
    ///
    /// Es war eine Karte: `Stil.flaeche`, `eckeKachel`, 32 Innenabstand —
    /// genau die Fuellung, die Ecke und der Abstand der Einstellungskarte
    /// rechts, und direkt darueber die Bereichsliste, deren gewaehlter
    /// Eintrag ebenfalls ein gefuellter, gerundeter Kasten ist. Drei
    /// gefuellte Kaesten in einem Bild fuer drei verschiedene Dinge: wer du
    /// bist, wo du bist, was du einstellst. Rückmeldung vom 23.09.: die Kachel
    /// gehoert nicht zu den Bereichen, sieht aber so aus, als gehoere sie
    /// dazu.
    ///
    /// **Nicht alles ist eine Karte** (BRAND 4). Die Liste rechts ist eine —
    /// sie ist der Gegenstand, an dem man arbeitet, und jetzt der einzige
    /// gefuellte Kasten der Seite. Links steht dasselbe frei auf dem Grund,
    /// auf derselben Kante wie „Bereiche" und die Bereichsnamen: 26. Was die
    /// Karte an Zusammenhalt gab, tragen jetzt Abstand und eine Linie.
    ///
    /// **Das Profil bleibt der erste Griff.** Wer die Einstellungen oeffnet,
    /// will meistens das Konto wechseln — deshalb steht der Kontenstreifen
    /// weiter ganz oben und nicht im Bereich „Konto".
    private var kontoblock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Profilzeichen(name: model.session?.userName ?? "?",
                          bild: model.benutzerbildURL(),
                          groesse: 84)
            Text(model.session?.userName ?? "—")
                // Reihenueberschrift aus der Leiter; 40 Bold stand daneben.
                .font(Stil.reihe)
                .tracking(Stil.sperrungReihe)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                .padding(.top, 18)
            // Serverdaten, kein Katalogtext.
            Text(verbatim: serverzeile)
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftLeise)
                .lineLimit(1)
                .padding(.top, 4)
            // Die Linie, die hier stand, trennte innerhalb der Karte den
            // Namen von den Konten. Ohne Karte waere sie die zweite in einer
            // Spalte, die nur eine braucht — und die eine steht weiter
            // unten, vor „Bereiche". Die Konten gehoeren zum Namen darueber.
            Kontenstreifen(model: model) { kontoAufnehmen = true }
                .padding(.top, 28)
        }
        .padding(.leading, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var serverzeile: String {
        [model.serverName, model.serverVersion].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Zeilen je Bereich

    @ViewBuilder
    private var zeilen: some View {
        switch bereich {
        case .wiedergabe:
            // Wandelt der Server nicht um, ist nichts zu wählen: Direct Play
            // steht fest an, die Bitrate ist gesperrt — wie auf den anderen
            // Fassungen.
            let frei = model.umwandelnErlaubt
            let directPlay = model.immerDirectPlay || !frei
            // **Der Anker haengt an der obersten Zeile, die auch zu
            // haben ist.**
            //
            // Er hing fest an dieser hier — und genau sie ist gesperrt,
            // wenn der Server das Umwandeln verbietet. Ein Fokus auf etwas
            // Gesperrtes geht ins Leere, also blieb er links stehen: OK auf
            // „Wiedergabe" tat nichts Sichtbares, waehrend es in allen
            // sieben anderen Bereichen ging. Deren oberste Zeile ist nie
            // gesperrt.
            //
            // Ist sie es hier, ruecken Direct Play und Bitrate zusammen aus
            // (`directPlay` ist dann fest an) und „Puffer" ist die erste
            // Zeile, die man anfassen kann.
            Schalterzeile(titel: "Immer Direct Play", an: directPlay) {
                model.immerDirectPlay.toggle()
            }
            .disabled(!frei)
            .focused($rechts, equals: frei ? .oben : .weiter)
            Trennlinie()
            wertzeile("Höchste Bitrate", wert: Bitrate.text(model.bitratenGrenze),
                      eintraege: Bitrate.stufen, beschriftung: { Bitrate.text($0.wert) },
                      an: { $0.wert == model.bitratenGrenze },
                      waehlen: { model.bitratenGrenze = $0.wert })
            .disabled(directPlay)
            Trennlinie()
            // **Steht neben der Bitrate, weil es dieselbe Sorte Entscheidung
            // ist:** was der Zuschauer ueber seine Leitung weiss und die App
            // nicht messen kann.
            //
            // Die Beschriftungen kommen aus `Pufferstufe.name` und damit aus
            // dem Paketkatalog — hier wird nichts nachgebaut, sonst stuenden
            // dieselben drei Woerter in zwei Katalogen und liefen
            // auseinander.
            wertzeile("Puffer", wert: model.pufferstufe.name,
                      eintraege: Pufferstufe.allCases, beschriftung: \.name,
                      an: { $0 == model.pufferstufe },
                      waehlen: { model.pufferstufe = $0 })
            .focused($rechts, equals: frei ? .weiter : .oben)
            Trennlinie()
            Schalterzeile(titel: "Untertitel automatisch", an: model.untertitelAutomatisch) {
                model.untertitelAutomatisch.toggle()
            }
            Trennlinie()
            // **Der Schalter fuer die Bildratenanpassung.**
            //
            // Am 08.09.2026 an einem Geraet gemessen: dieselbe Folge laeuft
            // in Swiftfin fluessig, und Swiftfin schaltet die Bildrate nicht
            // um. Bei uns stockte es sichtbar, waehrend jeder Zaehler auf
            // null stand — kein verworfenes Bild, keines zu spaet, nichts
            // beschaedigt. Der einzige greifbare Unterschied war dieser
            // Wechsel.
            //
            // 24 Hz nativ ist auf dem Papier das Richtige: jedes Bild steht
            // gleich lang. Auf einem Fernseher, dessen Bewegungsverarbeitung
            // bei 60 Hz glaettet, kann es trotzdem schlechter aussehen. Das
            // haengt am Geraet, nicht an der Datei — also entscheidet es der
            // Zuschauer. An bleibt die Vorgabe.
            Schalterzeile(titel: "Bildrate an den Film anpassen",
                          an: bildrateAnpassen) {
                bildrateAnpassen.toggle()
            }
            Trennlinie()
            Schalterzeile(titel: "Nächste Folge automatisch", an: model.naechsteAutomatisch) {
                model.naechsteAutomatisch.toggle()
            }
            Trennlinie()
            wertzeile("Zurückspulen", wert: "\(model.zurueckSekunden) s",
                      eintraege: Spanne.stufen, beschriftung: { "\($0.wert) s" },
                      an: { $0.wert == model.zurueckSekunden },
                      waehlen: { model.zurueckSekunden = $0.wert })
            Trennlinie()
            wertzeile("Vorspulen", wert: "\(model.vorSekunden) s",
                      eintraege: Spanne.stufen, beschriftung: { "\($0.wert) s" },
                      an: { $0.wert == model.vorSekunden },
                      waehlen: { model.vorSekunden = $0.wert })

        case .sprachen:
            wertzeile("Ton",
                      wert: model.tonSprache.isEmpty ? String(localized: "Wie die Datei")
                                                     : model.tonSprache,
                      eintraege: Sprachwahl.alle, beschriftung: \.name,
                      an: { $0.wert == model.tonSprache },
                      waehlen: { model.tonSprache = $0.wert }, oben: true)
            Trennlinie()
            wertzeile("Untertitel",
                      wert: model.untertitelSprache.isEmpty ? String(localized: "Aus")
                                                            : model.untertitelSprache,
                      eintraege: Sprachwahl.alle(aus: String(localized: "Aus")),
                      beschriftung: \.name,
                      an: { $0.wert == model.untertitelSprache },
                      waehlen: { model.untertitelSprache = $0.wert })

        case .darstellung:
            Schalterzeile(titel: "Fortschritt auf Kacheln", an: model.fortschrittAufKacheln) {
                model.fortschrittAufKacheln.toggle()
            }
            .focused($rechts, equals: .oben)
            Trennlinie()

            // **Welche Reihen auf der Startseite stehen — und in welcher
            // Folge.** Geschoben wird mit den Pfeilen rechts: eine Zeile am
            // Griff zu ziehen ist eine Geste des Zeigers, die
            // Fernbedienung hat keinen. Der Fokus geht nach rechts auf die
            // Pfeile und mit einem Druck wandert die Zeile.
            Gruppentitel(text: "Startseite")
                .padding(.horizontal, 26)
                .padding(.top, 18)
            ForEach(sichtbareReihen) { reihe in
                Reihenzeile(name: reihe.name,
                            an: !model.startAus.contains(reihe),
                            kannHoch: sichtbareReihen.first != reihe,
                            kannRunter: sichtbareReihen.last != reihe,
                            umschalten: {
                                if model.startAus.contains(reihe) { model.startAus.remove(reihe) }
                                else { model.startAus.insert(reihe) }
                            },
                            schieben: { schritt in verschieben(reihe, um: schritt) })
                Trennlinie()
            }
            Schalterzeile(titel: "Neuzugänge getrennt", an: model.neuzugangGetrennt) {
                model.neuzugangGetrennt.toggle()
            }
            Trennlinie()

            // **Eine Liste, zwei Formen.** Welche Genres, stellt man einmal
            // ein; ob sie als Reihen unten oder als Chips oben stehen, ist
            // nur noch die Form.
            Gruppentitel(text: "Genres")
                .padding(.horizontal, 26)
                .padding(.top, 18)
            wertzeile("Form", wert: model.genreChips ? String(localized: "Als Chips")
                                                     : String(localized: "Als Reihen"),
                      eintraege: Genreform.allCases, beschriftung: \.name,
                      an: { $0.chips == model.genreChips },
                      waehlen: { model.genreChips = $0.chips })
            ForEach(model.startGenres, id: \.self) { name in
                Trennlinie()
                Handlungszeile(name: name, wert: String(localized: "Entfernen")) {
                    withAnimation(Stil.einblenden) {
                        model.startGenres.removeAll { $0 == name }
                    }
                }
            }
            Trennlinie()
            wertzeile("Genre hinzufügen",
                      wert: gattungenGestoert && alleGattungen.isEmpty
                            ? String(localized: "Server ist abgetaucht")
                            : (freieGattungen.isEmpty ? String(localized: "Keins offen") : ""),
                      eintraege: freieGattungen.map { Gattungswahl(name: $0) },
                      beschriftung: \.name,
                      an: { _ in false },
                      waehlen: { model.startGenres.append($0.name) })

        case .integration:
            // **Ein zweiter Dienst, kein zweiter Server** — deshalb eine
            // eigene Rubrik und nicht unter „Server". Und eine Zugabe: wer
            // nichts anbindet, sieht ausser dieser Zeile nirgends etwas
            // davon.
            Anzeigezeile(titel: "Seerr",
                         wert: model.seerr.verbunden ? String(localized: "Verbunden")
                                                     : String(localized: "Nicht verbunden"))
            Trennlinie()
            Handlungszeile(titel: model.seerr.verbunden ? "Ändern" : "Anbinden") {
                seerrOffen = true
            }
            .focused($rechts, equals: .oben)
            // **Eine Zeile, nicht zwei wie bei Seerr.** Zweimal „Anbinden"
            // untereinander liesse offen, welcher Dienst gemeint ist; hier
            // steht der Name vorn und der Stand dahinter. Nur mit
            // Zugangsdaten im Bau (`TraktZugang`).
            if model.trakt.verfuegbar {
                Trennlinie()
                Handlungszeile(name: "Trakt",
                               wert: model.trakt.verbunden
                                   ? (model.trakt.benutzer ?? String(localized: "Verbunden"))
                                   : String(localized: "Nicht verbunden")) {
                    traktOffen = true
                }
            }

        case .gemeinschaft:
            // **Als Code, nicht als Link** — der Fernseher hat keinen Browser.
            Handlungszeile(titel: "Swiftly bewerten") { gemeinschaftsziel = .bewerten }
                .focused($rechts, equals: .oben)
            Trennlinie()
            Handlungszeile(titel: "Discord beitreten") { gemeinschaftsziel = .discord }
            Trennlinie()
            Handlungszeile(titel: "Fehler melden") { gemeinschaftsziel = .fehler }

        case .server:
            Anzeigezeile(titel: "Adresse", wert: model.serverName ?? "—")
            Trennlinie()
            Anzeigezeile(titel: "Fassung", wert: model.serverVersion.map { "Jellyfin \($0)" } ?? "—")
            // **Ohne diese Zeile kann niemand sagen, was er benutzt.** Ein
            // Tester wurde am 05.09.2026 nach seiner Baunummer gefragt und
            // fand nur die Jellyfin-Fassung — die Angabe, an der ein
            // Fehlerbericht haengt, gab es auf dem Fernseher gar nicht.
            Anzeigezeile(titel: "Swiftly", wert: Fassung.zeile)
            Trennlinie()
            // **Mehrere Server, seit dem 12.09.2026.** Vorher hielt der Bund
            // genau einen, und diese Zeile gab es gar nicht.
            Handlungszeile(titel: "Server hinzufügen") { serverAufnehmen = true }
            Trennlinie()
            // Für Server hinter einem Dienst wie Cloudflare Access (Issue #4).
            Handlungszeile(titel: "Eigene Header") { eigeneKoepfe = true }
            Trennlinie()
            Handlungszeile(titel: "Verbindung prüfen") {
                Task { pruefung = await model.verbindungPruefen() }
            }
            .focused($rechts, equals: .oben)

        case .konto:
            // **„Weiteres Konto hinzufügen" steht als Plus in der Kontokarte**,
            // dort wo die Konten stehen. An seiner Stelle der zweite Server,
            // wie auf den anderen Fassungen.
            //
            // Hier stand bis zum 15.09.2026 „Kommt später" als blosse Anzeige —
            // geschrieben, bevor es mehrere Server gab, und nie nachgezogen, als
            // „Server hinzufügen" im Bereich Server am 12.09. zu funktionieren
            // begann. Jetzt derselbe Weg wie dort.
            Handlungszeile(titel: "Server hinzufügen") { serverAufnehmen = true }
            Trennlinie()
            // **Trifft nur das aktive Konto.** Sind noch andere da, schaltet
            // die App auf das nächste um; erst beim letzten geht es zurück
            // zur Anmeldung. Steht so im Zustandshalter, nicht hier.
            Handlungszeile(titel: "Abmelden") { model.signOut() }
                .focused($rechts, equals: .oben)
        }
    }

    /// Zeile mit Wert rechts. Drücken klappt die Auswahl darunter auf —
    /// statt sie in ein Blatt zu legen, das wieder Wege kostet.
    private func wertzeile<E: Identifiable>(_ titel: LocalizedStringKey, wert: String,
                                            eintraege: [E],
                                            beschriftung: @escaping (E) -> String,
                                            an: @escaping (E) -> Bool,
                                            waehlen: @escaping (E) -> Void,
                                            oben: Bool = false) -> some View {
        let schluessel = String(describing: titel)
        return VStack(alignment: .leading, spacing: 0) {
            Handlungszeile(titel: titel, wert: wert,
                           aufgeklappt: offen == schluessel) {
                // **Ein Vorgang für die ganze Liste, nicht einer je Zeile.**
                //
                // Hier hing ein `.animation(…, value: offen)` an jeder
                // Wertzeile. Damit animiert jede für sich: die zwei direkt
                // darunter standen sofort an ihrem neuen Platz, die weiter
                // unten rutschten langsam nach, und dazwischen überlappten
                // sie sich. Ein `withAnimation` an der Änderung selbst legt
                // alle in **eine** Bewegung — die Liste rückt als ein Stück.
                withAnimation(.easeInOut(duration: 0.28)) {
                    offen = offen == schluessel ? nil : schluessel
                }
            }
            .focused($rechts, equals: oben ? .oben : .weiter)

            if offen == schluessel {
                // **Dieselbe Zeilenform, nur eingerückt.** Vorher standen hier
                // runde Marken nebeneinander; Eine Auswahl sieht in einer
                // Einstellungsliste aus wie die Liste — mit Haken beim
                // Gewählten, so wie es jede App macht.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(eintraege) { eintrag in
                        Button {
                            waehlen(eintrag)
                            offen = nil
                        } label: {
                            HStack(spacing: 24) {
                                Image(systemName: an(eintrag)
                                      ? "checkmark" : "")
                                    .font(.system(size: 26, weight: .semibold))
                                    .foregroundStyle(Stil.akzent)
                                    .frame(width: 34)
                                // Interpoliert, nicht als Schlüssel: „30 s"
                                // ist ein Wert und stünde sonst als
                                // Fehlstelle im Katalog.
                                Text("\(beschriftung(eintrag))")
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(ZeilenStil())
                        // Der `checkmark` sagt, was gilt — als Zeichen ohne
                        // Beschriftung sagt er VoiceOver nichts. Das Merkmal
                        // gehoert an den Knopf.
                        .accessibilityAddTraits(an(eintrag) ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.leading, 26)
                .focusSection()
                .transition(.opacity)
            }
        }
        // Ziel für den Leser, damit die aufgeklappte Zeile ins Bild kommt.
        .id(schluessel)
    }
}

// MARK: - Zeilen

/// Ein Bereich in der linken Spalte. Gewählt ist Akzent, fokussiert die
/// ruhige Fläche — dieselbe Regel wie überall.
struct BereichsStil: ButtonStyle {
    let an: Bool
    /// **Gewaehlt, aber abgegeben.** Wer OK drueckt, arbeitet rechts; der
    /// Bereich links ist dann nicht mehr das, was man gerade tut, sondern
    /// nur noch die Auskunft, woher man kam. Trug er weiter den Akzent,
    /// standen beide Spalten gleich laut da und es sah aus, als sei links
    /// noch etwas offen.
    var ruht = false

    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration, an: an, ruht: ruht)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        let an: Bool
        let ruht: Bool
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                // **Das Gewicht bleibt.** Grau wird die Farbe, nicht die
                // Stelle: wo man war, soll man beim Zurueckgehen wiederfinden
                // — und ein Gewichtswechsel verschoebe ausserdem die Zeile.
                // **Gewaehlt ist hier Akzentschrift und Toenung — und
                // VoiceOver sieht beides nicht.** Die Hauptnavigation der
                // Einstellungen sagte ihre Wahl nur ueber Farbe; ohne diese
                // Angabe klingt der offene Bereich wie jeder andere. Der
                // Filterchip und `LeistenStil` machen es schon so.
                .accessibilityAddTraits(an ? [.isButton, .isSelected] : .isButton)
                .font(.system(size: 30, weight: an || fokus ? .semibold : .medium))
                .foregroundStyle(schriftfarbe)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .frame(height: Stil.zeilenHoehe)
                .background(grund, in: RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
                .animation(Stil.fokusAnimation, value: fokus)
        }

        /// **Vier Zustände, vier Bilder.** Gewählt war eine Fläche in Akzent —
        /// die einzige Stelle der App, an der der Akzent eine Fläche trug —,
        /// und lag der Fokus darauf, sah sie genauso aus: man sah nicht, wo
        /// man stand. Jetzt trägt der Akzent Schrift und Tönung wie in der
        /// Seitenleiste von iPad und Mac, der Fokus die helle Fläche, und
        /// beides zusammen die kräftigere Tönung.
        private var schriftfarbe: Color {
            guard an else { return Stil.schrift }
            return ruht ? Stil.schriftLeise : Stil.akzent
        }

        private var grund: Color {
            switch (an, fokus) {
            case (true, true):   Stil.akzent.opacity(0.26)
            // Abgegeben: die ruhige Flaeche statt der Toenung. Die Zeile
            // bleibt als Ort erkennbar, hoert aber auf, nach vorn zu
            // draengen.
            case (true, false):  ruht ? Stil.flaeche : Stil.akzent.opacity(0.15)
            case (false, true):  Stil.fokusflaeche
            case (false, false): .clear
            }
        }
    }
}

/// Zeile ohne Handlung — nur Angabe.
struct Anzeigezeile: View {
    let titel: LocalizedStringKey
    let wert: String

    var body: some View {
        HStack(spacing: 24) {
            Text(titel).font(.system(size: 30, weight: .medium))
            Spacer(minLength: 40)
            Text(wert).font(Stil.knopf).foregroundStyle(Stil.schriftLeise)
        }
        .foregroundStyle(Stil.schrift)
        .padding(.horizontal, 26)
        .frame(height: Stil.zeilenHoehe)
    }
}

/// Zeile, die etwas auslöst — mit oder ohne Wert rechts.
struct Handlungszeile: View {
    var titel: LocalizedStringKey = ""
    /// **Wenn die Beschriftung vom Server kommt** — ein Genre heisst, wie es
    /// heisst, und darf nicht durch die Uebersetzungstabelle laufen.
    var name: String? = nil
    var wert: String?
    var aufgeklappt = false
    let aktion: () -> Void
    /// **Gesperrt heisst gedaempft — auch rechts.** `ZeilenStil` daempft die
    /// Beschriftung, Wert und Pfeil setzten ihre Farbe selbst und blieben
    /// heller stehen als der Titel: die Bitratenzeile sah bei „Immer Direct
    /// Play" halb bedienbar aus, und der Wert war lauter als sein Name.
    @Environment(\.isEnabled) private var bedienbar

    var body: some View {
        Button(action: aktion) {
            HStack(spacing: 24) {
                if let name { Text(verbatim: name) } else { Text(titel) }
                Spacer(minLength: 40)
                if let wert {
                    Text(wert)
                        .foregroundStyle(bedienbar ? Stil.schriftLeise
                                                   : Stil.schriftSehrLeise)
                    Image(systemName: aufgeklappt ? "chevron.up" : "chevron.down")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Stil.schriftSehrLeise)
                        .opacity(bedienbar ? 1 : 0.5)
                }
            }
        }
        .buttonStyle(ZeilenStil())
        // Der Pfeil sagt, ob die Auswahl offen ist; VoiceOver sieht ihn
        // nicht. Nur wo es etwas aufzuklappen gibt — ohne Wert ist die Zeile
        // eine gewoehnliche Handlung.
        .accessibilityHint(wert == nil ? Text("")
                           : (aufgeklappt ? Text("Zuklappen") : Text("Aufklappen")))
    }
}

/// Zeile mit Schalter rechts.
///
/// Kein `Toggle`: Apples Schalter bringt eigene Maße, eigenen Radius und
/// eigene Animation mit — dieselbe Begründung wie auf dem iPhone. Auf tvOS
/// kommt dazu, dass der Fokus auf der ganzen Zeile liegt, nicht auf dem
/// Schalter; gedrückt wird die Zeile.
struct Schalterzeile: View {
    let titel: LocalizedStringKey
    let an: Bool
    let aktion: () -> Void

    var body: some View {
        Button(action: aktion) {
            HStack(spacing: 24) {
                Text(titel)
                Spacer(minLength: 40)
                Schalter(an: an)
            }
        }
        .buttonStyle(ZeilenStil())
        .accessibilityRepresentation {
            Toggle(isOn: .constant(an)) { Text(titel) }
        }
    }
}

/// **Eine Reihe der Startseite: an oder aus, und wohin sie gehört.**
///
/// Drei Ziele nebeneinander statt eines Ziehgriffs. Am Zeiger zieht man eine
/// Zeile, mit der Fernbedienung gibt es nichts zu greifen — der Fokus geht
/// nach rechts auf die Pfeile, ein Druck schiebt die Zeile um einen Platz.
struct Reihenzeile: View {
    let name: LocalizedStringKey
    let an: Bool
    let kannHoch: Bool
    let kannRunter: Bool
    let umschalten: () -> Void
    let schieben: (Int) -> Void

    var body: some View {
        HStack(spacing: 24) {
            Button(action: umschalten) {
                HStack(spacing: 24) {
                    Text(name)
                    Spacer(minLength: 40)
                    Schalter(an: an)
                }
            }
            .buttonStyle(ZeilenStil())
            .accessibilityRepresentation {
                Toggle(isOn: .constant(an)) { Text(name) }
            }

            schiebeknopf("chevron.up", an: kannHoch) { schieben(-1) }
            schiebeknopf("chevron.down", an: kannRunter) { schieben(1) }
        }
        .padding(.trailing, 26)
    }

    /// **Gesperrt statt versteckt.** Fiele der Pfeil an der obersten Zeile
    /// weg, ruecken die Knoepfe der Nachbarzeilen seitlich — und der Fokus
    /// springt beim Hinauffahren in die falsche Spalte.
    private func schiebeknopf(_ symbol: String, an: Bool,
                              tun: @escaping () -> Void) -> some View {
        Button(action: tun) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
        }
        // **Nicht `.buttonStyle(.card)`.** Apples Karte bringt Schatten,
        // Parallaxe und ein Aufblitzen mit — `tvOS/Stil.swift` schliesst sie
        // gleich im Kopf aus, und hier stand sie trotzdem. `KnopfStil` traegt
        // dieselben drei Zustaende wie jeder andere Knopf der App, den
        // gesperrten eingeschlossen: gedaempfte Schrift auf ruhiger Flaeche
        // statt einer durchscheinenden Karte.
        .buttonStyle(KnopfStil(nurSymbol: true, hoehe: 56))
        .disabled(!an)
        .accessibilityLabel(symbol == "chevron.up" ? Text("Nach oben") : Text("Nach unten"))
    }
}

/// Ob die Genres als eigene Reihen oder als Chips oben stehen.
struct Genreform: Identifiable, CaseIterable {
    let chips: Bool
    var id: Bool { chips }
    var name: String {
        chips ? String(localized: "Als Chips über den Reihen")
              : String(localized: "Als eigene Reihen")
    }
    static var allCases: [Genreform] { [.init(chips: false), .init(chips: true)] }
}

/// Ein Genre des Servers in der Auswahlliste.
struct Gattungswahl: Identifiable {
    let name: String
    var id: String { name }
}

/// Der Schalter selbst — nur Anzeige, gedrückt wird die Zeile.
struct Schalter: View {
    let an: Bool
    /// **Gesperrt heisst gedaempft, auch hier.** `ZeilenStil` daempft die
    /// Schrift, der Schalter daneben blieb in vollem Akzent stehen — die
    /// Zeile sah damit halb bedienbar aus. Der Zustand kommt aus der
    /// Umgebung, damit das `.disabled` der Aufrufstelle reicht und keine
    /// zweite Angabe danebensteht, die auseinanderlaufen kann.
    @Environment(\.isEnabled) private var bedienbar

    var body: some View {
        ZStack(alignment: an ? .trailing : .leading) {
            Capsule()
                .fill(spur)
                .frame(width: 84, height: 50)
            Circle()
                .fill(griff)
                .frame(width: 40, height: 40)
                .padding(.horizontal, 5)
        }
        .animation(bedienbar ? .easeInOut(duration: 0.15) : nil, value: an)
    }

    /// Gedaempft, nicht durchscheinend: der Schalter behaelt seine Stellung
    /// — man sieht weiter, ob er an ist, nur nicht mehr, dass man ihn
    /// umlegen koennte.
    private var spur: Color {
        guard bedienbar else {
            return an ? Stil.akzent.opacity(0.35) : Color.white.opacity(0.08)
        }
        return an ? Stil.akzent : Color.white.opacity(0.16)
    }

    private var griff: Color {
        guard bedienbar else { return Color.white.opacity(0.35) }
        return an ? Stil.grund : Color.white
    }
}

/// Haarlinie zwischen Zeilen.
struct Trennlinie: View {
    var body: some View {
        Rectangle().fill(Stil.linie)
            .frame(height: 2)
            .padding(.horizontal, 26)
    }
}

/// Die anderen Konten und das Plus — unten in der Kontokarte.
///
/// **Das angemeldete Konto steht nicht mehr darin.** Es steht groß darüber;
/// als Kreis in der Reihe stünde es zweimal da. Ein Druck auf ein anderes
/// Konto wechselt, das Plus nimmt eines per Quick Connect auf. Das Plus steht
/// immer da, also gibt es auch mit einem einzigen Konto etwas zu fokussieren,
/// das etwas tut.
private struct Kontenstreifen: View {
    let model: AppModel
    let aufnehmen: () -> Void

    private let groesse: CGFloat = 60

    var body: some View {
        HStack(spacing: 20) {
            // **Alle Konten, nicht nur die dieses Servers.** Seit dem
            // 12.09.2026 haelt der Bund mehrere Server; wer zwei hat, findet
            // hier beide. Unterschieden wird ueber `kontoschluessel` —
            // dieselbe Benutzerkennung kann es auf zwei Servern geben.
            ForEach(model.konten.filter { $0.kontoschluessel != model.session?.kontoschluessel },
                    id: \.kontoschluessel) { konto in
                Button {
                    model.kontoWechseln(zu: konto.kontoschluessel)
                } label: {
                    Profilzeichen(name: konto.userName,
                                  bild: model.benutzerbildURL(fuer: konto),
                                  groesse: groesse)
                }
                .buttonStyle(KontostreifenStil(groesse: groesse))
                .accessibilityLabel(Text("Zu \(konto.userName) wechseln"))
            }

            Button(action: aufnehmen) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Stil.schriftLeise)
                    .frame(width: groesse, height: groesse)
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.28),
                                              style: StrokeStyle(lineWidth: 3, dash: [6, 5]))
                    }
            }
            .buttonStyle(KontostreifenStil(groesse: groesse))
            .accessibilityLabel(Text("Weiteres Konto hinzufügen"))
        }
        .focusSection()
    }
}

/// Fokus als weißer Ring und ein Stück Vergrößerung — dieselbe Sprache wie
/// die Kacheln, nur rund, weil ein Profilbild ein Bild ist.
private struct KontostreifenStil: ButtonStyle {
    let groesse: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration, groesse: groesse)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        let groesse: CGFloat
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                .overlay {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 4)
                        .opacity(fokus ? 1 : 0)
                }
                .frame(width: groesse, height: groesse)
                // Kein Schatten — siehe `PlayerScreen`. Die Lupe sagt es.
                //
                // 1,12 stand hier, 1,10 am `ProfilStil` daneben — zwei Werte
                // fuer denselben 60 Punkt grossen Kreis. Jetzt beide die kleine
                // Stufe.
                .scaleEffect(fokus ? Stil.fokusLupeKlein : 1)
                .animation(Stil.fokusAnimation, value: fokus)
        }
    }
}

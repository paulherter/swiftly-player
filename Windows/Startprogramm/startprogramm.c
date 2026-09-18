/*
 * Das Startprogramm von Swiftly unter Windows.
 *
 * **Warum es das gibt.** Beim ersten Start einer neuen Fassung prueft der
 * Defender jede unbekannte, unsignierte DLL, die `bin\Swiftly.exe` laedt.
 * Gemessen am 16.09.2026 in der VM: 23,1 s bis zum Fenster, die App selbst
 * brauchte davon 0,5 s Rechenzeit, der Rest war Warten auf die Pruefung
 * (Ereignisse 2010 im Defender-Protokoll). Solange Windows die Swift-Laufzeit
 * und GTK prueft, laeuft in der App noch keine Zeile unseres Codes - ein
 * Ladefenster *in* der App kaeme also zu spaet. Ein Nutzer schrieb
 * "installed it, nothing opens".
 *
 * Dieses Programm haengt nur an Systembibliotheken, ist klein und steht
 * deshalb sofort. Es
 *   1. zeigt ein Ladefenster mit dem, was gerade passiert,
 *   2. startet `bin\Swiftly.exe` und leitet deren stdout/stderr in
 *      `%APPDATA%\Swiftly\swiftly.log`,
 *   3. liest dort die Zeilen `[Stufe] <name>` mit, die die App schreibt,
 *   4. schliesst sein Fenster, sobald die App ein sichtbares Fenster hat,
 *   5. bleibt offen und sagt warum, wenn die App vorher endet oder nach
 *      zwei Minuten noch kein Fenster hat,
 *   6. bleibt danach unsichtbar im Hintergrund, bis die App endet: haelt das
 *      Protokoll klein und schreibt den Exitcode hinein.
 *
 * Gebaut von `bauen.ps1` mit MSVC, statisch gegen die C-Laufzeit (`/MT`) -
 * sonst braeuchte es `vcruntime140.dll`, und die liegt auf einem frischen
 * Windows nicht immer da.
 *
 * Zugangsdaten stehen nie im Protokoll: das Startprogramm schreibt nur seine
 * eigenen Zeilen und nicht einmal die Befehlszeile.
 */

#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <objbase.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* ------------------------------------------------------------------ Texte */

typedef struct {
    const wchar_t *startet, *pruefung, *sekunden, *zuLange, *beendet, *beendetCode,
                  *dateiFehlt, *nichtGestartet, *protokollOeffnen, *schliessen,
                  *programmFehlt;
} Texte;

static const Texte deutsch = {
    L"Swiftly startet …",
    L"Beim ersten Start prüft Windows die App. Das kann bis zu einer Minute dauern.",
    L"%d s",
    L"Swiftly läuft noch, hat nach zwei Minuten aber kein Fenster offen. Im Protokoll steht, wie weit es gekommen ist.",
    L"Swiftly wurde beendet, bevor ein Fenster aufging.",
    L"Code 0x%08lX. Zuletzt: %s",
    L"Eine Datei fehlt. Installier Swiftly am besten neu.",
    L"Swiftly ließ sich nicht starten (Fehler %lu).",
    L"Protokoll öffnen",
    L"Schließen",
    L"bin\\Swiftly.exe fehlt. Installier Swiftly am besten neu.",
};

static const Texte englisch = {
    L"Starting Swiftly …",
    L"On first launch, Windows checks the app. This can take up to a minute.",
    L"%d s",
    L"Swiftly is still running but has no window after two minutes. The log shows how far it got.",
    L"Swiftly quit before its window opened.",
    L"Code 0x%08lX. Last step: %s",
    L"A file is missing. Reinstalling Swiftly should fix it.",
    L"Swiftly couldn't be started (error %lu).",
    L"Open log",
    L"Close",
    L"bin\\Swiftly.exe is missing. Reinstalling Swiftly should fix it.",
};

static const Texte *T = &englisch;
static BOOL istDeutsch = FALSE;

/* Die Stufen, die die App meldet. Der Name steht im Protokoll, der Text im
 * Fenster; eine unbekannte Stufe wird roh gezeigt, damit eine neue in der App
 * nicht erst hier nachgetragen werden muss, um sichtbar zu sein. */
typedef struct { const char *name; const wchar_t *de, *en; } Stufe;
static const Stufe stufen[] = {
    { "programm",      L"Oberfläche wird geladen …", L"Loading the interface …" },
    { "oberflaeche",   L"Oberfläche wird gebaut …",  L"Building the interface …" },
    { "einstellungen", L"Einstellungen gelesen",               L"Settings loaded" },
    { "bereit",        L"Fenster geht auf …",             L"Opening the window …" },
    { "server",        L"Verbinde mit Server …",          L"Connecting to server …" },
};

static void stufentext(const char *name, wchar_t *ziel, size_t n) {
    for (size_t i = 0; i < sizeof stufen / sizeof stufen[0]; i++) {
        if (strcmp(stufen[i].name, name) == 0) {
            wcsncpy_s(ziel, n, istDeutsch ? stufen[i].de : stufen[i].en, _TRUNCATE);
            return;
        }
    }
    if (!name[0]) { wcsncpy_s(ziel, n, istDeutsch ? L"noch keine" : L"none yet", _TRUNCATE); return; }
    MultiByteToWideChar(CP_UTF8, 0, name, -1, ziel, (int)n);
}

/* -------------------------------------------------------------- Zustand */

#define WM_GESTARTET   (WM_APP + 1)   /* wParam: 1 = ok, lParam: Fehlercode */
#define WM_BEENDET     (WM_APP + 2)   /* lParam: Exitcode */
#define TAKT_ID        1
#define ZEIGEN_ID      2
#define KNOPF_PROTOKOLL 101
#define KNOPF_SCHLIESSEN 102
#define HINWEIS_NACH_MS   3000
/* **Erst nach einer halben Sekunde zeigen.** Ist die App schon gepruefter
 * Bekannter, steht ihr Fenster in der VM nach 0,5 s; ein Ladefenster, das
 * sofort kommt, blinkt dann nur einmal auf. Beim ersten Start kostet die
 * Frist eine halbe Sekunde, das Warten dort dauert zwanzig. */
#define ZEIGEN_NACH_MS    500
#define FRIST_MS          120000
#define PROTOKOLL_GRENZE  (16LL * 1024 * 1024)

typedef enum { WARTET, ZU_LANGE, FERTIG, FEHLER } Lage;

static HINSTANCE inst;
static HWND fenster, zeileStatus, zeileHinweis, zeileSekunden, balken, knopfProtokoll, knopfSchliessen;
static HFONT schrift, titelschrift;
static HICON grossesSymbol;
static int dpi = 96;
static int zeigeArt = SW_SHOWNORMAL;
static BOOL gezeigt = FALSE;
static Lage lage = WARTET;
static ULONGLONG beginn;
static DWORD kindPid;
static HANDLE kindProzess;
static wchar_t ordner[MAX_PATH], programm[MAX_PATH], protokollPfad[MAX_PATH], altPfad[MAX_PATH];
static wchar_t *kindBefehl;
static HANDLE protokoll = INVALID_HANDLE_VALUE;   /* Anhaengen, vererbbar */
static HANDLE leser = INVALID_HANDLE_VALUE;
static LONGLONG leseStand;
static char zeilenrest[4096];
static size_t restLaenge;
static char letzteStufe[64];

static int S(int wert) { return MulDiv(wert, dpi, 96); }

/* ---------------------------------------------------------- Protokoll */

static void schreib(const char *utf8) {
    if (protokoll == INVALID_HANDLE_VALUE) return;
    DWORD geschrieben;
    WriteFile(protokoll, utf8, (DWORD)strlen(utf8), &geschrieben, NULL);
}

static void protokolliere(const wchar_t *format, ...) {
    wchar_t text[1024];
    va_list args;
    va_start(args, format);
    _vsnwprintf_s(text, _countof(text), _TRUNCATE, format, args);
    va_end(args);
    SYSTEMTIME z;
    GetLocalTime(&z);
    wchar_t zeile[1200];
    _snwprintf_s(zeile, _countof(zeile), _TRUNCATE, L"%02d:%02d:%02d.%03d [Start] %s\r\n",
                 z.wHour, z.wMinute, z.wSecond, z.wMilliseconds, text);
    char utf8[3600];
    if (WideCharToMultiByte(CP_UTF8, 0, zeile, -1, utf8, sizeof utf8, NULL, NULL) > 0) schreib(utf8);
}

/* Die alte Datei wird zu `swiftly.alt.log`, die neue beginnt leer. Klappt das
 * Umbenennen nicht (etwa weil eine zweite Kopie gerade hineinschreibt), wird
 * einfach angehaengt - ein Protokoll ist wichtiger als ein aufgeraeumtes. */
static void protokollOeffnen(void) {
    /* Derselbe Ordner, den ``Plattform.einstellungsordner`` benutzt. */
    wchar_t roaming[MAX_PATH], dir[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"APPDATA", roaming, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    _snwprintf_s(dir, _countof(dir), _TRUNCATE, L"%s\\Swiftly", roaming);
    CreateDirectoryW(dir, NULL);
    _snwprintf_s(protokollPfad, _countof(protokollPfad), _TRUNCATE, L"%s\\swiftly.log", dir);
    _snwprintf_s(altPfad, _countof(altPfad), _TRUNCATE, L"%s\\swiftly.alt.log", dir);
    MoveFileExW(protokollPfad, altPfad, MOVEFILE_REPLACE_EXISTING);

    SECURITY_ATTRIBUTES erben = { sizeof erben, NULL, TRUE };
    /* **Nur FILE_APPEND_DATA.** Die App erbt genau dieses Handle und teilt
     * sich damit dessen Dateizeiger; mit reinem Anhaengen landet jede
     * Schreibung am Ende, egal wer zuletzt geschrieben hat - und nach dem
     * Kuerzen weiter vorn statt hinter einem Loch. */
    protokoll = CreateFileW(protokollPfad, FILE_APPEND_DATA | SYNCHRONIZE,
                            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                            &erben, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    leser = CreateFileW(protokollPfad, GENERIC_READ,
                        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                        NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (leser != INVALID_HANDLE_VALUE) {
        LARGE_INTEGER g;
        if (GetFileSizeEx(leser, &g)) leseStand = g.QuadPart;
    }
}

/* Waechst das Protokoll ueber die Grenze, wird es auf null gekuerzt. Einmal
 * hat eine Schleife 18 GB geschrieben; das soll nicht noch einmal die Platte
 * eines Nutzers fuellen. */
static void protokollBegrenzen(void) {
    if (leser == INVALID_HANDLE_VALUE) return;
    LARGE_INTEGER g;
    if (!GetFileSizeEx(leser, &g) || g.QuadPart < PROTOKOLL_GRENZE) return;
    HANDLE h = CreateFileW(protokollPfad, GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    SetEndOfFile(h);
    CloseHandle(h);
    leseStand = 0;
    restLaenge = 0;
    protokolliere(L"Protokoll war größer als 16 MB und wurde gekürzt");
}

static void zeilePruefen(const char *zeile) {
    const char *marke = strstr(zeile, "[Stufe] ");
    if (!marke) return;
    marke += 8;
    size_t n = 0;
    while (marke[n] && marke[n] != '\r' && marke[n] != '\n' && marke[n] != ' ' && n < sizeof letzteStufe - 1) n++;
    memcpy(letzteStufe, marke, n);
    letzteStufe[n] = 0;
}

/* Liest, was seit dem letzten Takt ins Protokoll kam. */
static BOOL stufenLesen(void) {
    if (leser == INVALID_HANDLE_VALUE) return FALSE;
    char vorher[64];
    strcpy_s(vorher, sizeof vorher, letzteStufe);
    char puffer[8192];
    for (int runde = 0; runde < 64; runde++) {
        LARGE_INTEGER stand = { .QuadPart = leseStand };
        if (!SetFilePointerEx(leser, stand, NULL, FILE_BEGIN)) break;
        DWORD gelesen = 0;
        if (!ReadFile(leser, puffer, sizeof puffer, &gelesen, NULL) || gelesen == 0) break;
        leseStand += gelesen;
        for (DWORD i = 0; i < gelesen; i++) {
            char c = puffer[i];
            if (c == '\n') {
                zeilenrest[restLaenge] = 0;
                zeilePruefen(zeilenrest);
                restLaenge = 0;
            } else if (restLaenge < sizeof zeilenrest - 1) {
                zeilenrest[restLaenge++] = c;
            }
        }
    }
    return strcmp(vorher, letzteStufe) != 0;
}

static void protokollZeigen(void) {
    if ((INT_PTR)ShellExecuteW(fenster, L"open", protokollPfad, NULL, NULL, SW_SHOWNORMAL) <= 32) {
        wchar_t args[MAX_PATH + 4];
        _snwprintf_s(args, _countof(args), _TRUNCATE, L"\"%s\"", protokollPfad);
        ShellExecuteW(fenster, L"open", L"notepad.exe", args, NULL, SW_SHOWNORMAL);
    }
}

/* ------------------------------------------------------------- Kind */

static BOOL CALLBACK fensterSuchen(HWND h, LPARAM gefunden) {
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    if (pid != kindPid || !IsWindowVisible(h) || GetWindow(h, GW_OWNER)) return TRUE;
    if (GetWindowLongW(h, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) return TRUE;
    RECT r;
    if (!GetWindowRect(h, &r) || r.right - r.left < 100 || r.bottom - r.top < 100) return TRUE;
    *(BOOL *)gefunden = TRUE;
    return FALSE;
}

/* **CreateProcess laeuft nicht auf dem Fensterfaden.** Schon das Oeffnen von
 * `bin\Swiftly.exe` wartet auf die Pruefung des Defenders; auf dem
 * Fensterfaden stuende das Ladefenster so lange still und hiesse nach fuenf
 * Sekunden "Keine Rueckmeldung". */
static DWORD WINAPI kindStarten(LPVOID unbenutzt) {
    (void)unbenutzt;
    STARTUPINFOW si = { sizeof si };
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = NULL;
    si.hStdOutput = protokoll;
    si.hStdError = protokoll;
    wchar_t arbeitsordner[MAX_PATH];
    _snwprintf_s(arbeitsordner, _countof(arbeitsordner), _TRUNCATE, L"%s\\bin", ordner);
    PROCESS_INFORMATION pi;
    BOOL erben = protokoll != INVALID_HANDLE_VALUE;
    if (!CreateProcessW(programm, kindBefehl, NULL, NULL, erben, 0, NULL, arbeitsordner, &si, &pi)) {
        PostMessageW(fenster, WM_GESTARTET, 0, (LPARAM)GetLastError());
        return 0;
    }
    CloseHandle(pi.hThread);
    kindProzess = pi.hProcess;
    kindPid = pi.dwProcessId;
    PostMessageW(fenster, WM_GESTARTET, 1, 0);
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    PostMessageW(fenster, WM_BEENDET, 0, (LPARAM)code);
    return 0;
}

/* ------------------------------------------------------------ Fenster */

static void setzeText(HWND h, const wchar_t *text) {
    wchar_t alt[512];
    GetWindowTextW(h, alt, _countof(alt));
    if (wcscmp(alt, text) != 0) SetWindowTextW(h, text);
}

static void knoepfeZeigen(BOOL schliessen) {
    ShowWindow(knopfProtokoll, SW_SHOW);
    ShowWindow(knopfSchliessen, schliessen ? SW_SHOW : SW_HIDE);
}

static void fehlerZeigen(const wchar_t *oben, const wchar_t *unten) {
    lage = FEHLER;
    KillTimer(fenster, TAKT_ID);
    ShowWindow(balken, SW_HIDE);
    ShowWindow(zeileSekunden, SW_HIDE);
    setzeText(zeileStatus, oben);
    setzeText(zeileHinweis, unten);
    ShowWindow(zeileHinweis, SW_SHOW);
    knoepfeZeigen(TRUE);
    ShowWindow(fenster, SW_SHOWNORMAL);
    gezeigt = TRUE;
    SetForegroundWindow(fenster);
}

static void takt(void) {
    DWORD ms = (DWORD)(GetTickCount64() - beginn);
    if (stufenLesen()) {
        wchar_t t[128];
        stufentext(letzteStufe, t, _countof(t));
        if (lage == WARTET || lage == ZU_LANGE) setzeText(zeileStatus, t);
    }

    if (lage == FERTIG) { protokollBegrenzen(); return; }

    if (kindPid) {
        BOOL gefunden = FALSE;
        EnumWindows(fensterSuchen, (LPARAM)&gefunden);
        if (gefunden) {
            protokolliere(L"App-Fenster sichtbar nach %.1f s", ms / 1000.0);
            lage = FERTIG;
            ShowWindow(fenster, SW_HIDE);
            /* Ab jetzt nur noch auf die Groesse achten - dafuer reicht ein
             * langsamer Takt. */
            SetTimer(fenster, TAKT_ID, 5000, NULL);
            return;
        }
    }

    wchar_t sek[32];
    _snwprintf_s(sek, _countof(sek), _TRUNCATE, T->sekunden, (int)(ms / 1000));
    if (ms >= HINWEIS_NACH_MS) {
        setzeText(zeileSekunden, sek);
        ShowWindow(zeileSekunden, SW_SHOW);
        /* Der Hinweis gilt nur, solange die App noch keine Stufe gemeldet
         * hat: danach laeuft unser Code, und die Pruefung ist durch. */
        if (lage == WARTET) {
            setzeText(zeileHinweis, letzteStufe[0] ? L"" : T->pruefung);
            ShowWindow(zeileHinweis, SW_SHOW);
        }
    }
    if (lage == WARTET && ms >= FRIST_MS) {
        lage = ZU_LANGE;
        protokolliere(L"Nach %d s kein App-Fenster, letzte Stufe: %S", FRIST_MS / 1000,
                      letzteStufe[0] ? letzteStufe : "keine");
        setzeText(zeileHinweis, T->zuLange);
        ShowWindow(zeileHinweis, SW_SHOW);
        knoepfeZeigen(FALSE);
        ShowWindow(fenster, SW_SHOWNORMAL);
        gezeigt = TRUE;
    }
}

static void bauen(HWND h) {
    HDC dc = GetDC(h);
    dpi = GetDeviceCaps(dc, LOGPIXELSY);
    ReleaseDC(h, dc);

    NONCLIENTMETRICSW m = { sizeof m };
    SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof m, &m, 0);
    schrift = CreateFontIndirectW(&m.lfMessageFont);
    LOGFONTW titel = m.lfMessageFont;
    titel.lfHeight = MulDiv(titel.lfHeight, 3, 2);
    titel.lfWeight = FW_SEMIBOLD;
    titelschrift = CreateFontIndirectW(&titel);

    grossesSymbol = (HICON)LoadImageW(inst, MAKEINTRESOURCEW(1), IMAGE_ICON, S(48), S(48), 0);

    int links = S(88), breite = S(460) - links - S(24);
    HWND titelzeile = CreateWindowW(L"STATIC", L"Swiftly", WS_CHILD | WS_VISIBLE | SS_NOPREFIX,
                                    links, S(20), S(200), S(28), h, NULL, inst, NULL);
    zeileSekunden = CreateWindowW(L"STATIC", L"", WS_CHILD | SS_RIGHT | SS_NOPREFIX,
                                  links + breite - S(80), S(26), S(80), S(20), h, NULL, inst, NULL);
    zeileStatus = CreateWindowW(L"STATIC", T->startet, WS_CHILD | WS_VISIBLE | SS_NOPREFIX | SS_ENDELLIPSIS,
                                links, S(54), breite, S(20), h, NULL, inst, NULL);
    balken = CreateWindowW(PROGRESS_CLASSW, L"", WS_CHILD | WS_VISIBLE | PBS_MARQUEE,
                           links, S(80), breite, S(6), h, NULL, inst, NULL);
    SendMessageW(balken, PBM_SETMARQUEE, TRUE, 30);
    zeileHinweis = CreateWindowW(L"STATIC", L"", WS_CHILD | SS_NOPREFIX,
                                 links, S(96), breite, S(52), h, NULL, inst, NULL);
    knopfProtokoll = CreateWindowW(L"BUTTON", T->protokollOeffnen, WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON,
                                   S(460) - S(24) - S(96) - S(8) - S(140), S(152), S(140), S(30),
                                   h, (HMENU)(INT_PTR)KNOPF_PROTOKOLL, inst, NULL);
    knopfSchliessen = CreateWindowW(L"BUTTON", T->schliessen, WS_CHILD | WS_TABSTOP | BS_DEFPUSHBUTTON,
                                    S(460) - S(24) - S(96), S(152), S(96), S(30),
                                    h, (HMENU)(INT_PTR)KNOPF_SCHLIESSEN, inst, NULL);
    HWND alle[] = { zeileSekunden, zeileStatus, zeileHinweis, knopfProtokoll, knopfSchliessen };
    for (int i = 0; i < 5; i++) SendMessageW(alle[i], WM_SETFONT, (WPARAM)schrift, FALSE);
    SendMessageW(titelzeile, WM_SETFONT, (WPARAM)titelschrift, FALSE);
}

static LRESULT CALLBACK fensterRuf(HWND h, UINT msg, WPARAM w, LPARAM l) {
    switch (msg) {
    case WM_CREATE:
        fenster = h;
        bauen(h);
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        if (grossesSymbol) DrawIconEx(dc, S(24), S(20), grossesSymbol, S(48), S(48), 0, NULL, DI_NORMAL);
        EndPaint(h, &ps);
        return 0;
    }
    case WM_TIMER:
        if (w == ZEIGEN_ID) {
            KillTimer(h, ZEIGEN_ID);
            takt();
            if (lage == WARTET && !gezeigt) {
                ShowWindow(h, zeigeArt);
                UpdateWindow(h);
                gezeigt = TRUE;
                protokolliere(L"Ladefenster sichtbar nach %llu ms", GetTickCount64() - beginn);
            }
            return 0;
        }
        takt();
        return 0;
    case WM_GESTARTET:
        if (w) {
            protokolliere(L"App gestartet, PID %lu", kindPid);
        } else {
            wchar_t oben[256];
            _snwprintf_s(oben, _countof(oben), _TRUNCATE, T->nichtGestartet, (DWORD)l);
            protokolliere(L"CreateProcess fehlgeschlagen: %lu", (DWORD)l);
            fehlerZeigen(oben, (DWORD)l == ERROR_FILE_NOT_FOUND ? T->programmFehlt : L"");
        }
        return 0;
    case WM_BEENDET: {
        DWORD code = (DWORD)l;
        stufenLesen();
        protokolliere(L"App beendet, Exitcode 0x%08lX, letzte Stufe: %S", code,
                      letzteStufe[0] ? letzteStufe : "keine");
        if (lage == FERTIG) { PostQuitMessage(0); return 0; }
        wchar_t stufe[128], unten[512];
        stufentext(letzteStufe, stufe, _countof(stufe));
        _snwprintf_s(unten, _countof(unten), _TRUNCATE, T->beendetCode, code, stufe);
        /* 0xC0000135: eine DLL fehlt; 0xC0000139: ein Einsprung fehlt - beides
         * heisst, die Installation ist unvollstaendig. */
        if (code == 0xC0000135 || code == 0xC0000139) {
            wcsncat_s(unten, _countof(unten), L"\n", _TRUNCATE);
            wcsncat_s(unten, _countof(unten), T->dateiFehlt, _TRUNCATE);
        }
        fehlerZeigen(T->beendet, unten);
        return 0;
    }
    case WM_COMMAND:
        if (LOWORD(w) == KNOPF_PROTOKOLL) { protokollZeigen(); return 0; }
        if (LOWORD(w) == KNOPF_SCHLIESSEN) { DestroyWindow(h); return 0; }
        break;
    case WM_CLOSE:
        /* **Schliessen beendet die App nicht.** Das Fenster geht weg, der
         * Start laeuft weiter; nur im Fehlerfall ist sonst nichts mehr zu tun. */
        if (lage == FEHLER || !kindPid) { DestroyWindow(h); return 0; }
        ShowWindow(h, SW_HIDE);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, msg, w, l);
}

/* Die Befehlszeile ohne unseren eigenen Programmnamen - der Rest geht an die
 * App durch. */
static const wchar_t *restDerBefehlszeile(void) {
    const wchar_t *c = GetCommandLineW();
    if (*c == L'"') { c++; while (*c && *c != L'"') c++; if (*c) c++; }
    else { while (*c && *c != L' ' && *c != L'\t') c++; }
    while (*c == L' ' || *c == L'\t') c++;
    return c;
}

int WINAPI wWinMain(HINSTANCE h, HINSTANCE vorher, PWSTR befehl, int zeigen) {
    (void)vorher; (void)befehl;
    inst = h;
    beginn = GetTickCount64();
    istDeutsch = PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_GERMAN;
    T = istDeutsch ? &deutsch : &englisch;

    GetModuleFileNameW(NULL, ordner, MAX_PATH);
    wchar_t *schnitt = wcsrchr(ordner, L'\\');
    if (schnitt) *schnitt = 0;
    _snwprintf_s(programm, _countof(programm), _TRUNCATE, L"%s\\bin\\Swiftly.exe", ordner);
    const wchar_t *rest = restDerBefehlszeile();
    size_t laenge = wcslen(programm) + wcslen(rest) + 8;
    kindBefehl = (wchar_t *)HeapAlloc(GetProcessHeap(), 0, laenge * sizeof(wchar_t));
    if (!kindBefehl) return 1;
    _snwprintf_s(kindBefehl, laenge, _TRUNCATE, *rest ? L"\"%s\" %s" : L"\"%s\"%s", programm, rest);

    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    protokollOeffnen();
    protokolliere(L"Startprogramm läuft, Ordner %s, Sprache %s", ordner, istDeutsch ? L"de" : L"en");

    INITCOMMONCONTROLSEX icc = { sizeof icc, ICC_PROGRESS_CLASS | ICC_STANDARD_CLASSES };
    InitCommonControlsEx(&icc);

    WNDCLASSEXW k = { sizeof k };
    k.lpfnWndProc = fensterRuf;
    k.hInstance = h;
    k.hCursor = LoadCursorW(NULL, IDC_APPSTARTING);
    k.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    k.lpszClassName = L"SwiftlyStart";
    k.hIcon = (HICON)LoadImageW(h, MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXICON),
                                GetSystemMetrics(SM_CYICON), 0);
    k.hIconSm = (HICON)LoadImageW(h, MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                                  GetSystemMetrics(SM_CYSMICON), 0);
    RegisterClassExW(&k);

    /* Groesse erst nach dem DPI bekannt - also mit Platzhalter anlegen und
     * dann zurechtruecken. */
    DWORD stil = WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    HWND f = CreateWindowExW(0, L"SwiftlyStart", L"Swiftly", stil, CW_USEDEFAULT, CW_USEDEFAULT,
                             100, 100, NULL, NULL, h, NULL);
    if (!f) return 1;
    RECT r = { 0, 0, S(460), S(194) };
    AdjustWindowRectEx(&r, stil, FALSE, 0);
    int bw = r.right - r.left, bh = r.bottom - r.top;
    RECT arbeit;
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &arbeit, 0);
    SetWindowPos(f, NULL, arbeit.left + (arbeit.right - arbeit.left - bw) / 2,
                 arbeit.top + (arbeit.bottom - arbeit.top - bh) / 2, bw, bh, SWP_NOZORDER);
    zeigeArt = zeigen;

    /* Die App darf ihr Fenster nach vorn holen, obwohl wir gerade vorn sind. */
    AllowSetForegroundWindow(ASFW_ANY);

    if (GetFileAttributesW(programm) == INVALID_FILE_ATTRIBUTES) {
        protokolliere(L"bin\\Swiftly.exe fehlt");
        fehlerZeigen(T->programmFehlt, L"");
    } else {
        SetTimer(f, TAKT_ID, 250, NULL);
        SetTimer(f, ZEIGEN_ID, ZEIGEN_NACH_MS, NULL);
        HANDLE faden = CreateThread(NULL, 0, kindStarten, NULL, 0, NULL);
        if (faden) CloseHandle(faden);
    }

    MSG nachricht;
    while (GetMessageW(&nachricht, NULL, 0, 0) > 0) {
        if (!IsDialogMessageW(f, &nachricht)) {
            TranslateMessage(&nachricht);
            DispatchMessageW(&nachricht);
        }
    }
    if (kindProzess) CloseHandle(kindProzess);
    return 0;
}

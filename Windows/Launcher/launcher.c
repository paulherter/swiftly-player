/*
 * Swiftly's launcher on Windows.
 *
 * **Why it exists.** On the first start of a new version Defender scans every
 * unknown, unsigned DLL that `bin\Swiftly.exe` loads. That took 23 s until the
 * window appeared, of which the app itself used 0.5 s of CPU; the rest was
 * waiting for the scan (events 2010 in the Defender log). While Windows scans
 * the Swift runtime and GTK, none of the app's own code is running, so a
 * loading window *inside* the app would come too late. A user reported
 * "installed it, nothing opens".
 *
 * This program only links against system libraries, is small and therefore
 * appears immediately. It
 *   1. shows a loading window with what is currently happening,
 *   2. starts `bin\Swiftly.exe` and redirects its stdout/stderr to
 *      `%APPDATA%\Swiftly\swiftly.log`,
 *   3. reads the `[Stufe] <name>` lines the app writes there,
 *   4. closes its window as soon as the app has a visible window,
 *   5. stays open and says why if the app exits earlier or still has no
 *      window after two minutes,
 *   6. then stays invisible in the background until the app exits: keeps the
 *      log small and writes the exit code into it.
 *
 * Built by `build.ps1` with MSVC, statically linked against the C runtime
 * (`/MT`); otherwise it would need `vcruntime140.dll`, which a fresh Windows
 * does not always have.
 *
 * Credentials never appear in the log: the launcher writes only its own lines
 * and not even the command line.
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

/* ------------------------------------------------------------------ Texts */

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

/* The stages the app reports. The name goes in the log, the text in the
 * window; an unknown stage is shown raw so that a new stage in the app does
 * not have to be added here to be visible. */
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

/* -------------------------------------------------------------- State */

#define WM_GESTARTET   (WM_APP + 1)   /* wParam: 1 = ok, lParam: error code */
#define WM_BEENDET     (WM_APP + 2)   /* lParam: exit code */
#define TAKT_ID        1
#define ZEIGEN_ID      2
#define KNOPF_PROTOKOLL 101
#define KNOPF_SCHLIESSEN 102
#define HINWEIS_NACH_MS   3000
/* **Show only after half a second.** If the app is already a scanned
 * known quantity, its window appears after 0.5 s; a loading window that
 * shows immediately would just flash once. On the first start the delay
 * costs half a second, while the wait there is twenty. */
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
static HANDLE protokoll = INVALID_HANDLE_VALUE;   /* Append, inheritable */
static HANDLE leser = INVALID_HANDLE_VALUE;
static LONGLONG leseStand;
static char zeilenrest[4096];
static size_t restLaenge;
static char letzteStufe[64];

static int S(int wert) { return MulDiv(wert, dpi, 96); }

/* ---------------------------------------------------------- Log */

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

/* The old file becomes `swiftly.alt.log`, the new one starts empty. If the
 * rename fails (e.g. because a second copy is writing to it), it simply
 * appends: a log matters more than a tidy one. */
static void protokollOeffnen(void) {
    /* The same folder ``Plattform.einstellungsordner`` uses. */
    wchar_t roaming[MAX_PATH], dir[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"APPDATA", roaming, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    _snwprintf_s(dir, _countof(dir), _TRUNCATE, L"%s\\Swiftly", roaming);
    CreateDirectoryW(dir, NULL);
    _snwprintf_s(protokollPfad, _countof(protokollPfad), _TRUNCATE, L"%s\\swiftly.log", dir);
    _snwprintf_s(altPfad, _countof(altPfad), _TRUNCATE, L"%s\\swiftly.alt.log", dir);
    MoveFileExW(protokollPfad, altPfad, MOVEFILE_REPLACE_EXISTING);

    SECURITY_ATTRIBUTES erben = { sizeof erben, NULL, TRUE };
    /* **FILE_APPEND_DATA only.** The app inherits exactly this handle and shares
 * its file pointer; with pure append every write lands at the end no matter
 * who wrote last, and after truncation further up instead of behind a
 * hole. */
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

/* If the log grows past the limit it is truncated to zero. A loop once
 * wrote 18 GB; that must not fill a user's disk again. */
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

/* Reads what was added to the log since the last tick. */
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

/* ------------------------------------------------------------- Child */

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

/* **CreateProcess does not run on the window thread.** Even opening
 * `bin\Swiftly.exe` waits for the Defender scan; on the window thread the
 * loading window would freeze for that long and read "Not responding"
 * after five seconds. */
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

/* ------------------------------------------------------------ Window */

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
            /* From now on only watch the size; a slow tick is enough for that. */
            SetTimer(fenster, TAKT_ID, 5000, NULL);
            return;
        }
    }

    wchar_t sek[32];
    _snwprintf_s(sek, _countof(sek), _TRUNCATE, T->sekunden, (int)(ms / 1000));
    if (ms >= HINWEIS_NACH_MS) {
        setzeText(zeileSekunden, sek);
        ShowWindow(zeileSekunden, SW_SHOW);
        /* The hint only applies while the app has not reported a stage yet:
 * afterwards our code is running and the scan is done. */
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
        /* 0xC0000135: a DLL is missing; 0xC0000139: an entry point is missing.
 * Both mean the installation is incomplete. */
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
        /* **Closing does not end the app.** The window goes away, the start
 * continues; otherwise only an error case would have nothing left to do. */
        if (lage == FEHLER || !kindPid) { DestroyWindow(h); return 0; }
        ShowWindow(h, SW_HIDE);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, msg, w, l);
}

/* The command line without our own program name; the rest is passed on to
 * the app. */
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

    /* **Pass the same language to the app.** The app picks its language itself
 * (`Textkatalog`), first from `LANGUAGE`. If that is unset, it gets the
 * display language already detected here, so loading window and app show
 * the same language. An existing `LANGUAGE` is left alone: that is a manual
 * override. CreateProcessW inherits the environment. */
    if (GetEnvironmentVariableW(L"LANGUAGE", NULL, 0) == 0) {
        wchar_t sprache[LOCALE_NAME_MAX_LENGTH];
        if (LCIDToLocaleName(MAKELCID(GetUserDefaultUILanguage(), SORT_DEFAULT),
                             sprache, LOCALE_NAME_MAX_LENGTH, 0) > 0) {
            SetEnvironmentVariableW(L"LANGUAGE", sprache);
            protokolliere(L"Sprache an die App: %s", sprache);
        }
    }

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

    /* The size is only known after the DPI, so create with a placeholder and
 * adjust afterwards. */
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

    /* The app may bring its window to the front although we are in front now. */
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

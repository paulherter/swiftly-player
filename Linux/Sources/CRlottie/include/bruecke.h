// **rlottie, über seine C-Schnittstelle.**
//
// Die Bibliothek selbst ist C++; `rlottie_capi.h` ist die C-Fassung, die
// Samsung mitliefert, und nur die wird hier eingebunden — Swift kann C++
// nicht ohne Weiteres, und gebraucht werden ohnehin nur vier Aufrufe:
// laden, Bildzahl, Bildrate, ein Bild zeichnen.
#include <rlottie_capi.h>

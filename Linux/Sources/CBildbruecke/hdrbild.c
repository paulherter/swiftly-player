#include "include/hdrbild.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* GTK bringt libepoxy mit, auf Linux wie unter Windows; es holt die
 * GL-Funktionen passend zum aktuellen Kontext. */
#ifdef HDRBILD_PRUEFSTAND
  #include <OpenGL/gl3.h>
  #define epoxy_has_gl_extension(name) 0
#else
  #include <epoxy/gl.h>
#endif

struct Hdrbild {
    GLuint programm, vao, puffer;
    GLuint tex[3];
    int    tex_art;               /* wofuer die Texturen angelegt sind */
    unsigned tex_breite, tex_hoehe;
    unsigned breite, hoehe;       /* das zuletzt geladene Bild */
    bool   hat_bild;
    bool   eingerichtet;
    bool   normiert;              /* GL_R16 mit Filter statt Ganzzahlen */
    GLint  ort_y, ort_u, ort_v, ort_art, ort_kennlinie, ort_eetf,
           ort_gy, ort_gc;
    char   fehler[512];
};

Hdrbild *hdrbild_neu(void) { return calloc(1, sizeof(Hdrbild)); }
void hdrbild_frei(Hdrbild *h) { free(h); }
const char *hdrbild_fehler(const Hdrbild *h) { return h ? h->fehler : ""; }

/* ---- Shader --------------------------------------------------------- */

static const char *ecke_quelle =
    "in vec2 lage;\n"
    "out vec2 tex;\n"
    "void main() {\n"
    "    tex = vec2(lage.x * 0.5 + 0.5, 0.5 - lage.y * 0.5);\n"
    "    gl_Position = vec4(lage, 0.0, 1.0);\n"
    "}\n";

/* **Zwei Arten zu lesen.** Wo es geht, liegen die Ebenen als normierte
 * 16-Bit-Texturen (GL_R16) vor, und die Grafikkarte filtert selbst — ein
 * Zugriff je Ebene. Unter OpenGL ES gibt es GL_R16 nur als Erweiterung; ohne
 * sie bleiben Ganzzahltexturen mit `texelFetch`, gefiltert von Hand (vier
 * Zugriffe je Ebene). Gemessen an 4K auf einer Ryzen-iGPU: der Handfilter
 * kostete das Mehrfache. */
static const char *flaeche_quelle =
    "#ifdef NORMIERT\n"
    "uniform highp sampler2D ebeneY;\n"
    "uniform highp sampler2D ebeneU;\n"
    "uniform highp sampler2D ebeneV;\n"
    "#else\n"
    "uniform highp usampler2D ebeneY;\n"
    "uniform highp usampler2D ebeneU;\n"
    "uniform highp usampler2D ebeneV;\n"
    "#endif\n"
    "uniform int art;\n"          /* 1 = I0AL, 2 = P010 */
    "uniform int kennlinie;\n"    /* 1 = PQ, 2 = HLG */
    /* EETF: PQ der hellsten Stelle, Ziel (relativ) und Knie — je Bild fest,
     * deshalb auf der CPU gerechnet. x = 0: nur abschneiden. */
    "uniform vec3 eetfWerte;\n"
    "uniform vec2 groesseY;\n"
    "uniform vec2 groesseC;\n"
    "in vec2 tex;\n"
    "out vec4 farbe;\n"
    "\n"
    "const float M1 = 0.1593017578125;\n"
    "const float M2 = 78.84375;\n"
    "const float C1 = 0.8359375;\n"
    "const float C2 = 18.8515625;\n"
    "const float C3 = 18.6875;\n"
    /* SDR-Weiss nach BT.2408: 203 Nits entsprechen 1,0 auf dem Bildschirm. */
    "const float WEISS = 203.0;\n"
    "\n"
    "#ifdef NORMIERT\n"
    /* I0AL: zehn Bit in den unteren Stellen, also * 65535; P010: in den
     * oberen, dort ist 65535 / 64 die richtige Stufe. */
    "float stufe() { return art == 2 ? 65535.0 / 64.0 : 65535.0; }\n"
    "float luma(vec2 q) { return texture(ebeneY, q / groesseY).r * stufe(); }\n"
    "vec2 chroma(vec2 q) {\n"
    "    vec2 t = (q + 0.5) / groesseC;\n"
    "    if (art == 2) return texture(ebeneU, t).rg * stufe();\n"
    "    return vec2(texture(ebeneU, t).r, texture(ebeneV, t).r) * stufe();\n"
    "}\n"
    "#else\n"
    "float zehnBit(uint v) { return float(art == 2 ? (v >> 6u) : (v & 1023u)); }\n"
    "\n"
    "float lumaPunkt(ivec2 p) {\n"
    "    p = clamp(p, ivec2(0), ivec2(groesseY) - 1);\n"
    "    return zehnBit(texelFetch(ebeneY, p, 0).r);\n"
    "}\n"
    "vec2 chromaPunkt(ivec2 p) {\n"
    "    p = clamp(p, ivec2(0), ivec2(groesseC) - 1);\n"
    "    if (art == 2) {\n"
    "        uvec2 v = texelFetch(ebeneU, p, 0).rg;\n"
    "        return vec2(zehnBit(v.r), zehnBit(v.g));\n"
    "    }\n"
    "    return vec2(zehnBit(texelFetch(ebeneU, p, 0).r),\n"
    "                zehnBit(texelFetch(ebeneV, p, 0).r));\n"
    "}\n"
    "float luma(vec2 q) {\n"
    "    vec2 p = q - 0.5; ivec2 i = ivec2(floor(p)); vec2 f = p - floor(p);\n"
    "    float a = mix(lumaPunkt(i), lumaPunkt(i + ivec2(1, 0)), f.x);\n"
    "    float b = mix(lumaPunkt(i + ivec2(0, 1)), lumaPunkt(i + ivec2(1, 1)), f.x);\n"
    "    return mix(a, b, f.y);\n"
    "}\n"
    "vec2 chroma(vec2 q) {\n"
    "    ivec2 i = ivec2(floor(q)); vec2 f = q - floor(q);\n"
    "    vec2 a = mix(chromaPunkt(i), chromaPunkt(i + ivec2(1, 0)), f.x);\n"
    "    vec2 b = mix(chromaPunkt(i + ivec2(0, 1)), chromaPunkt(i + ivec2(1, 1)), f.x);\n"
    "    return mix(a, b, f.y);\n"
    "}\n"
    "#endif\n"
    "\n"
    "float pqZuNits(float e) {\n"
    "    float n = pow(clamp(e, 0.0, 1.0), 1.0 / M2);\n"
    "    return 10000.0 * pow(max(n - C1, 0.0) / (C2 - C3 * n), 1.0 / M1);\n"
    "}\n"
    "float nitsZuPq(float l) {\n"
    "    float y = pow(clamp(l / 10000.0, 0.0, 1.0), M1);\n"
    "    return pow((C1 + C2 * y) / (1.0 + C3 * y), M2);\n"
    "}\n"
    "float hlgZuSzene(float e) {\n"
    "    const float A = 0.17883277, B = 0.28466892, C = 0.55991073;\n"
    "    return e <= 0.5 ? e * e / 3.0 : (exp((e - C) / A) + B) / 12.0;\n"
    "}\n"
    "\n"
    /* BT.2390, Abschnitt 5.4: die Kurve bleibt bis zum Knie linear und legt
     * darueber alles bis zur hellsten Stelle des Materials weich unter die
     * Zielhelligkeit. Gerechnet im PQ-Raum, wie die Norm es vorsieht. */
    "float eetf(float nits) {\n"
    "    float quelle = eetfWerte.x, ziel = eetfWerte.y, knie = eetfWerte.z;\n"
    "    if (quelle <= 0.0) return min(nits, WEISS);\n"
    "    float e = min(nitsZuPq(nits) / quelle, 1.0);\n"
    "    if (e > knie) {\n"
    "        float t = (e - knie) / (1.0 - knie);\n"
    "        float t2 = t * t, t3 = t2 * t;\n"
    "        e = (2.0 * t3 - 3.0 * t2 + 1.0) * knie\n"
    "          + (t3 - 2.0 * t2 + t) * (1.0 - knie)\n"
    "          + (-2.0 * t3 + 3.0 * t2) * ziel;\n"
    "    }\n"
    "    return pqZuNits(e * quelle);\n"
    "}\n"
    "\n"
    "void main() {\n"
    "    vec2 q = tex * groesseY;\n"
    /* 4:2:0 wie in HEVC ueblich: waagerecht auf der linken Spalte, senkrecht
     * zwischen zwei Zeilen. */
    "    vec2 qc = vec2((q.x - 0.5) * 0.5, q.y * 0.5 - 0.5);\n"
    "    float y = (luma(q) - 64.0) / 876.0;\n"
    "    vec2 c = (chroma(qc) - 512.0) / 896.0;\n"
    /* BT.2020, nicht konstante Leuchtdichte (Kr 0,2627, Kb 0,0593). */
    "    vec3 rgb = clamp(vec3(y + 1.4746 * c.y,\n"
    "                          y - 0.16455 * c.x - 0.57135 * c.y,\n"
    "                          y + 1.8814 * c.x), 0.0, 1.0);\n"
    "    vec3 nits;\n"
    "    if (kennlinie == 2) {\n"
    /* HLG: szenenbezogen; die OOTF nach BT.2100 fuer einen Schirm mit
     * 1000 Nits (Systemgamma 1,2) macht daraus Anzeigelicht. */
    "        vec3 e = vec3(hlgZuSzene(rgb.r), hlgZuSzene(rgb.g), hlgZuSzene(rgb.b));\n"
    "        float ys = dot(e, vec3(0.2627, 0.6780, 0.0593));\n"
    "        nits = 1000.0 * pow(max(ys, 1e-6), 0.2) * e;\n"
    "    } else {\n"
    "        nits = vec3(pqZuNits(rgb.r), pqZuNits(rgb.g), pqZuNits(rgb.b));\n"
    "    }\n"
    /* Auf die hellste Grundfarbe abbilden und alle drei gleich skalieren:
     * der Farbton bleibt, nur die Helligkeit wird gestaucht. */
    "    float m = max(max(nits.r, nits.g), nits.b);\n"
    "    if (m > 0.0) nits *= eetf(m) / m;\n"
    "    vec3 lin = nits / WEISS;\n"
    "    const mat3 zu709 = mat3( 1.6605, -0.1246, -0.0182,\n"
    "                            -0.5876,  1.1329, -0.1006,\n"
    "                            -0.0728, -0.0083,  1.1187);\n"
    "    lin = clamp(zu709 * lin, 0.0, 1.0);\n"
    "    farbe = vec4(pow(lin, vec3(1.0 / 2.2)), 1.0);\n"
    "}\n";

static GLuint uebersetzen(Hdrbild *h, GLenum art, const char *kopf, const char *quelle) {
    GLuint s = glCreateShader(art);
    const char *teile[2] = { kopf, quelle };
    glShaderSource(s, 2, teile, NULL);
    glCompileShader(s);
    GLint gut = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &gut);
    if (!gut) {
        glGetShaderInfoLog(s, sizeof h->fehler, NULL, h->fehler);
        glDeleteShader(s);
        return 0;
    }
    return s;
}

bool hdrbild_einrichten(Hdrbild *h, bool es) {
    if (h->eingerichtet) return h->programm != 0;
    h->eingerichtet = true;
    h->fehler[0] = 0;
    h->normiert = !es || epoxy_has_gl_extension("GL_EXT_texture_norm16");
    const char *kopf = es
        ? (h->normiert
           ? "#version 300 es\n#define NORMIERT\nprecision highp float;\nprecision highp int;\n"
           : "#version 300 es\nprecision highp float;\nprecision highp int;\n")
        : "#version 150\n#define NORMIERT\n";
    GLuint ecke = uebersetzen(h, GL_VERTEX_SHADER, kopf, ecke_quelle);
    GLuint flaeche = ecke ? uebersetzen(h, GL_FRAGMENT_SHADER, kopf, flaeche_quelle) : 0;
    if (!ecke || !flaeche) {
        if (ecke) glDeleteShader(ecke);
        return false;
    }
    GLuint p = glCreateProgram();
    glAttachShader(p, ecke);
    glAttachShader(p, flaeche);
    glBindAttribLocation(p, 0, "lage");
    glLinkProgram(p);
    glDeleteShader(ecke);
    glDeleteShader(flaeche);
    GLint gut = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &gut);
    if (!gut) {
        glGetProgramInfoLog(p, sizeof h->fehler, NULL, h->fehler);
        glDeleteProgram(p);
        return false;
    }
    h->programm = p;
    h->ort_y = glGetUniformLocation(p, "ebeneY");
    h->ort_u = glGetUniformLocation(p, "ebeneU");
    h->ort_v = glGetUniformLocation(p, "ebeneV");
    h->ort_art = glGetUniformLocation(p, "art");
    h->ort_kennlinie = glGetUniformLocation(p, "kennlinie");
    h->ort_eetf = glGetUniformLocation(p, "eetfWerte");
    h->ort_gy = glGetUniformLocation(p, "groesseY");
    h->ort_gc = glGetUniformLocation(p, "groesseC");

    static const GLfloat ecken[] = { -1, -1,  1, -1,  -1, 1,  1, 1 };
    glGenVertexArrays(1, &h->vao);
    glBindVertexArray(h->vao);
    glGenBuffers(1, &h->puffer);
    glBindBuffer(GL_ARRAY_BUFFER, h->puffer);
    glBufferData(GL_ARRAY_BUFFER, sizeof ecken, ecken, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
    glBindVertexArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    return true;
}

static void textur_anlegen(GLuint t, GLenum intern, GLenum form, unsigned w, unsigned h) {
    GLint filter = (form == GL_RED || form == GL_RG) ? GL_LINEAR : GL_NEAREST;
    glBindTexture(GL_TEXTURE_2D, t);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, (GLint)intern, (GLsizei)w, (GLsizei)h, 0,
                 form, GL_UNSIGNED_SHORT, NULL);
}

static void ebene_laden(GLuint t, GLenum form, unsigned texelbytes,
                        const uint8_t *daten, unsigned takt, unsigned w, unsigned h) {
    glBindTexture(GL_TEXTURE_2D, t);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 2);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, (GLint)(takt / texelbytes));
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, (GLsizei)w, (GLsizei)h, form,
                    GL_UNSIGNED_SHORT, daten);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
}

bool hdrbild_hochladen(Hdrbild *h, const Bildstand *s, bool es) {
    if (!hdrbild_einrichten(h, es)) return false;
    if (s->art != BILDART_I0AL && s->art != BILDART_P010) return false;
    unsigned w = s->breite, hh = s->hoehe;
    unsigned cw = (w + 1) / 2, ch = (hh + 1) / 2;

    /* GL_R16_EXT und GL_RG16_EXT haben dieselben Werte wie GL_R16/GL_RG16. */
    GLenum r = h->normiert ? GL_R16 : GL_R16UI, rg = h->normiert ? GL_RG16 : GL_RG16UI;
    GLenum rf = h->normiert ? GL_RED : GL_RED_INTEGER, rgf = h->normiert ? GL_RG : GL_RG_INTEGER;
    if (h->tex_art != s->art || h->tex_breite != w || h->tex_hoehe != hh) {
        if (h->tex[0]) glDeleteTextures(3, h->tex);
        glGenTextures(3, h->tex);
        textur_anlegen(h->tex[0], r, rf, w, hh);
        if (s->art == BILDART_P010) {
            textur_anlegen(h->tex[1], rg, rgf, cw, ch);
            textur_anlegen(h->tex[2], r, rf, 1, 1);   /* ungenutzt */
        } else {
            textur_anlegen(h->tex[1], r, rf, cw, ch);
            textur_anlegen(h->tex[2], r, rf, cw, ch);
        }
        h->tex_art = s->art;
        h->tex_breite = w;
        h->tex_hoehe = hh;
    }
    ebene_laden(h->tex[0], rf, 2, s->ebene[0], s->takt[0], w, hh);
    if (s->art == BILDART_P010) {
        ebene_laden(h->tex[1], rgf, 4, s->ebene[1], s->takt[1], cw, ch);
    } else {
        ebene_laden(h->tex[1], rf, 2, s->ebene[1], s->takt[1], cw, ch);
        ebene_laden(h->tex[2], rf, 2, s->ebene[2], s->takt[2], cw, ch);
    }
    glBindTexture(GL_TEXTURE_2D, 0);
    h->breite = w;
    h->hoehe = hh;
    h->hat_bild = true;
    return true;
}

static float nits_zu_pq(float nits) {
    float y = powf(nits / 10000.0f, 0.1593017578125f);
    return powf((0.8359375f + 18.8515625f * y) / (1.0f + 18.6875f * y), 78.84375f);
}

typedef struct { float w[3]; } Dreier;

/* BT.2390: Quelle (PQ der hellsten Stelle), Ziel relativ dazu, Knie. */
static Dreier eetf_werte(float spitze) {
    Dreier d = {{0, 0, 0}};
    if (spitze <= 203.0f) return d;
    float quelle = nits_zu_pq(spitze);
    float ziel = nits_zu_pq(203.0f) / quelle;
    d.w[0] = quelle; d.w[1] = ziel; d.w[2] = 1.5f * ziel - 0.5f;
    return d;
}

bool hdrbild_zeichnen(Hdrbild *h, int breite, int hoehe, bool fuellen,
                      int kennlinie, float spitze, bool es) {
    glViewport(0, 0, breite, hoehe);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    if (!h->hat_bild || breite <= 0 || hoehe <= 0 || !hdrbild_einrichten(h, es))
        return false;

    /* Einpassen wie `GtkPicture`: ganz (Balken) oder formatfuellend
     * (beschnitten), nie verzerrt. */
    double sx = (double)breite / h->breite, sy = (double)hoehe / h->hoehe;
    double s = fuellen ? (sx > sy ? sx : sy) : (sx < sy ? sx : sy);
    int w = (int)(h->breite * s + 0.5), hh = (int)(h->hoehe * s + 0.5);
    glViewport((breite - w) / 2, (hoehe - hh) / 2, w, hh);

    glUseProgram(h->programm);
    for (int i = 0; i < 3; i++) {
        glActiveTexture(GL_TEXTURE0 + i);
        glBindTexture(GL_TEXTURE_2D, h->tex[i]);
    }
    glUniform1i(h->ort_y, 0);
    glUniform1i(h->ort_u, 1);
    glUniform1i(h->ort_v, 2);
    glUniform1i(h->ort_art, h->tex_art);
    glUniform1i(h->ort_kennlinie, kennlinie);
    glUniform3fv(h->ort_eetf, 1, eetf_werte(spitze > 0 ? spitze : 1000.0f).w);
    glUniform2f(h->ort_gy, (float)h->breite, (float)h->hoehe);
    glUniform2f(h->ort_gc, (float)((h->breite + 1) / 2), (float)((h->hoehe + 1) / 2));
    glBindVertexArray(h->vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);
    for (int i = 2; i >= 0; i--) {
        glActiveTexture(GL_TEXTURE0 + i);
        glBindTexture(GL_TEXTURE_2D, 0);
    }
    glUseProgram(0);
    glViewport(0, 0, breite, hoehe);
    return true;
}

void hdrbild_aufgeben(Hdrbild *h) {
    if (!h) return;
    if (h->tex[0]) glDeleteTextures(3, h->tex);
    if (h->puffer) glDeleteBuffers(1, &h->puffer);
    if (h->vao) glDeleteVertexArrays(1, &h->vao);
    if (h->programm) glDeleteProgram(h->programm);
    char fehler[sizeof h->fehler];
    memcpy(fehler, h->fehler, sizeof fehler);
    memset(h, 0, sizeof *h);
    memcpy(h->fehler, fehler, sizeof fehler);
}

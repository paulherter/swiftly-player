#include "include/hdrimage.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* GTK ships libepoxy on Linux and Windows; it resolves the GL functions
 * for the current context. */
#ifdef HDR_IMAGE_TEST_BENCH
  #include <OpenGL/gl3.h>
  #define epoxy_has_gl_extension(name) 0
#else
  #include <epoxy/gl.h>
#endif

struct Hdrbild {
    GLuint program, vao, buffer;
    GLuint tex[3];
    int    tex_art;               /* what the textures are allocated for */
    unsigned tex_width, tex_height;
    unsigned width, height;       /* the most recently loaded image */
    bool   has_image;
    bool   setUp;
    bool   normalized;              /* GL_R16 with filtering instead of integers */
    GLint  place_y, place_u, place_v, place_kind, place_curve, place_eetf,
           place_gy, place_gc;
    char   error[512];
};

Hdrbild *hdr_image_new(void) { return calloc(1, sizeof(Hdrbild)); }
void hdr_image_free(Hdrbild *h) { free(h); }
const char *hdr_image_error(const Hdrbild *h) { return h ? h->error : ""; }

/* ---- Shader --------------------------------------------------------- */

static const char *corner_source =
    "in vec2 lage;\n"
    "out vec2 tex;\n"
    "void main() {\n"
    "    tex = vec2(lage.x * 0.5 + 0.5, 0.5 - lage.y * 0.5);\n"
    "    gl_Position = vec4(lage, 0.0, 1.0);\n"
    "}\n";

/* **Two ways to read.** Where possible the planes are normalized 16-bit
 * textures (GL_R16) and the GPU filters them itself: one fetch per plane.
 * OpenGL ES only has GL_R16 as an extension; without it the planes stay
 * integer textures read with `texelFetch` and filtered by hand (four
 * fetches per plane), which cost several times as much on 4K on an
 * integrated GPU. */
static const char *area_source =
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
    /* EETF: PQ of the brightest spot, target (relative) and knee; constant
     * per image, so computed on the CPU. x = 0: clip only. */
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
    /* SDR white per BT.2408: 203 nits equal 1.0 on screen. */
    "const float WEISS = 203.0;\n"
    "\n"
    "#ifdef NORMIERT\n"
    /* I0AL: ten bits in the low bits, so * 65535; P010: in the high bits,
     * where 65535 / 64 is the right step. */
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
    /* BT.2390, section 5.4: linear up to the knee, above it everything up
     * to the brightest spot is rolled off smoothly below the target
     * brightness. Computed in PQ space as the standard specifies. */
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
    /* 4:2:0 as usual in HEVC: horizontally on the left column, vertically
     * between two rows. */
    "    vec2 qc = vec2((q.x - 0.5) * 0.5, q.y * 0.5 - 0.5);\n"
    "    float y = (luma(q) - 64.0) / 876.0;\n"
    "    vec2 c = (chroma(qc) - 512.0) / 896.0;\n"
    /* BT.2020, non-constant luminance (Kr 0.2627, Kb 0.0593). */
    "    vec3 rgb = clamp(vec3(y + 1.4746 * c.y,\n"
    "                          y - 0.16455 * c.x - 0.57135 * c.y,\n"
    "                          y + 1.8814 * c.x), 0.0, 1.0);\n"
    "    vec3 nits;\n"
    "    if (kennlinie == 2) {\n"
    /* HLG is scene-referred; the BT.2100 OOTF for a 1000-nit display (system
     * gamma 1.2) turns it into display light. */
    "        vec3 e = vec3(hlgZuSzene(rgb.r), hlgZuSzene(rgb.g), hlgZuSzene(rgb.b));\n"
    "        float ys = dot(e, vec3(0.2627, 0.6780, 0.0593));\n"
    "        nits = 1000.0 * pow(max(ys, 1e-6), 0.2) * e;\n"
    "    } else {\n"
    "        nits = vec3(pqZuNits(rgb.r), pqZuNits(rgb.g), pqZuNits(rgb.b));\n"
    "    }\n"
    /* Map to the brightest primary and scale all three equally: hue is
     * kept, only brightness is compressed. */
    "    float m = max(max(nits.r, nits.g), nits.b);\n"
    "    if (m > 0.0) nits *= eetf(m) / m;\n"
    "    vec3 lin = nits / WEISS;\n"
    "    const mat3 zu709 = mat3( 1.6605, -0.1246, -0.0182,\n"
    "                            -0.5876,  1.1329, -0.1006,\n"
    "                            -0.0728, -0.0083,  1.1187);\n"
    "    lin = clamp(zu709 * lin, 0.0, 1.0);\n"
    "    farbe = vec4(pow(lin, vec3(1.0 / 2.2)), 1.0);\n"
    "}\n";

static GLuint translate(Hdrbild *h, GLenum art, const char *header, const char *source) {
    GLuint s = glCreateShader(art);
    const char *parts[2] = { header, source };
    glShaderSource(s, 2, parts, NULL);
    glCompileShader(s);
    GLint good = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &good);
    if (!good) {
        glGetShaderInfoLog(s, sizeof h->error, NULL, h->error);
        glDeleteShader(s);
        return 0;
    }
    return s;
}

bool hdr_image_set_up(Hdrbild *h, bool es) {
    if (h->setUp) return h->program != 0;
    h->setUp = true;
    h->error[0] = 0;
    h->normalized = !es || epoxy_has_gl_extension("GL_EXT_texture_norm16");
    const char *header = es
        ? (h->normalized
           ? "#version 300 es\n#define NORMIERT\nprecision highp float;\nprecision highp int;\n"
           : "#version 300 es\nprecision highp float;\nprecision highp int;\n")
        : "#version 150\n#define NORMIERT\n";
    GLuint corner = translate(h, GL_VERTEX_SHADER, header, corner_source);
    GLuint area = corner ? translate(h, GL_FRAGMENT_SHADER, header, area_source) : 0;
    if (!corner || !area) {
        if (corner) glDeleteShader(corner);
        return false;
    }
    GLuint p = glCreateProgram();
    glAttachShader(p, corner);
    glAttachShader(p, area);
    glBindAttribLocation(p, 0, "lage");
    glLinkProgram(p);
    glDeleteShader(corner);
    glDeleteShader(area);
    GLint good = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &good);
    if (!good) {
        glGetProgramInfoLog(p, sizeof h->error, NULL, h->error);
        glDeleteProgram(p);
        return false;
    }
    h->program = p;
    h->place_y = glGetUniformLocation(p, "ebeneY");
    h->place_u = glGetUniformLocation(p, "ebeneU");
    h->place_v = glGetUniformLocation(p, "ebeneV");
    h->place_kind = glGetUniformLocation(p, "art");
    h->place_curve = glGetUniformLocation(p, "kennlinie");
    h->place_eetf = glGetUniformLocation(p, "eetfWerte");
    h->place_gy = glGetUniformLocation(p, "groesseY");
    h->place_gc = glGetUniformLocation(p, "groesseC");

    static const GLfloat corners[] = { -1, -1,  1, -1,  -1, 1,  1, 1 };
    glGenVertexArrays(1, &h->vao);
    glBindVertexArray(h->vao);
    glGenBuffers(1, &h->buffer);
    glBindBuffer(GL_ARRAY_BUFFER, h->buffer);
    glBufferData(GL_ARRAY_BUFFER, sizeof corners, corners, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
    glBindVertexArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    return true;
}

static void texture_create(GLuint t, GLenum intern, GLenum form, unsigned w, unsigned h) {
    GLint filter = (form == GL_RED || form == GL_RG) ? GL_LINEAR : GL_NEAREST;
    glBindTexture(GL_TEXTURE_2D, t);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, (GLint)intern, (GLsizei)w, (GLsizei)h, 0,
                 form, GL_UNSIGNED_SHORT, NULL);
}

static void layer_load(GLuint t, GLenum form, unsigned texelbytes,
                        const uint8_t *data, unsigned tick, unsigned w, unsigned h) {
    glBindTexture(GL_TEXTURE_2D, t);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 2);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, (GLint)(tick / texelbytes));
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, (GLsizei)w, (GLsizei)h, form,
                    GL_UNSIGNED_SHORT, data);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
}

bool hdr_image_upload(Hdrbild *h, const ImageState *s, bool es) {
    if (!hdr_image_set_up(h, es)) return false;
    if (s->art != PIXEL_FORMAT_I0AL && s->art != PIXEL_FORMAT_P010) return false;
    unsigned w = s->width, hh = s->height;
    unsigned cw = (w + 1) / 2, ch = (hh + 1) / 2;

    /* GL_R16_EXT and GL_RG16_EXT have the same values as GL_R16/GL_RG16. */
    GLenum r = h->normalized ? GL_R16 : GL_R16UI, rg = h->normalized ? GL_RG16 : GL_RG16UI;
    GLenum rf = h->normalized ? GL_RED : GL_RED_INTEGER, rgf = h->normalized ? GL_RG : GL_RG_INTEGER;
    if (h->tex_art != s->art || h->tex_width != w || h->tex_height != hh) {
        if (h->tex[0]) glDeleteTextures(3, h->tex);
        glGenTextures(3, h->tex);
        texture_create(h->tex[0], r, rf, w, hh);
        if (s->art == PIXEL_FORMAT_P010) {
            texture_create(h->tex[1], rg, rgf, cw, ch);
            texture_create(h->tex[2], r, rf, 1, 1);   /* unused */
        } else {
            texture_create(h->tex[1], r, rf, cw, ch);
            texture_create(h->tex[2], r, rf, cw, ch);
        }
        h->tex_art = s->art;
        h->tex_width = w;
        h->tex_height = hh;
    }
    layer_load(h->tex[0], rf, 2, s->layer[0], s->tick[0], w, hh);
    if (s->art == PIXEL_FORMAT_P010) {
        layer_load(h->tex[1], rgf, 4, s->layer[1], s->tick[1], cw, ch);
    } else {
        layer_load(h->tex[1], rf, 2, s->layer[1], s->tick[1], cw, ch);
        layer_load(h->tex[2], rf, 2, s->layer[2], s->tick[2], cw, ch);
    }
    glBindTexture(GL_TEXTURE_2D, 0);
    h->width = w;
    h->height = hh;
    h->has_image = true;
    return true;
}

static float nits_to_pq(float nits) {
    float y = powf(nits / 10000.0f, 0.1593017578125f);
    return powf((0.8359375f + 18.8515625f * y) / (1.0f + 18.6875f * y), 78.84375f);
}

typedef struct { float w[3]; } Triple;

/* BT.2390: source (PQ of the brightest spot), target relative to it, knee. */
static Triple eetf_values(float tip) {
    Triple d = {{0, 0, 0}};
    if (tip <= 203.0f) return d;
    float source = nits_to_pq(tip);
    float target = nits_to_pq(203.0f) / source;
    d.w[0] = source; d.w[1] = target; d.w[2] = 1.5f * target - 0.5f;
    return d;
}

bool hdr_image_draw(Hdrbild *h, int width, int height, bool fill,
                      int curve, float tip, bool es) {
    glViewport(0, 0, width, height);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    if (!h->has_image || width <= 0 || height <= 0 || !hdr_image_set_up(h, es))
        return false;

    /* Fit like `GtkPicture`: whole image (letterbox) or fill (cropped),
     * never distorted. */
    double sx = (double)width / h->width, sy = (double)height / h->height;
    double s = fill ? (sx > sy ? sx : sy) : (sx < sy ? sx : sy);
    int w = (int)(h->width * s + 0.5), hh = (int)(h->height * s + 0.5);
    glViewport((width - w) / 2, (height - hh) / 2, w, hh);

    glUseProgram(h->program);
    for (int i = 0; i < 3; i++) {
        glActiveTexture(GL_TEXTURE0 + i);
        glBindTexture(GL_TEXTURE_2D, h->tex[i]);
    }
    glUniform1i(h->place_y, 0);
    glUniform1i(h->place_u, 1);
    glUniform1i(h->place_v, 2);
    glUniform1i(h->place_kind, h->tex_art);
    glUniform1i(h->place_curve, curve);
    glUniform3fv(h->place_eetf, 1, eetf_values(tip > 0 ? tip : 1000.0f).w);
    glUniform2f(h->place_gy, (float)h->width, (float)h->height);
    glUniform2f(h->place_gc, (float)((h->width + 1) / 2), (float)((h->height + 1) / 2));
    glBindVertexArray(h->vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);
    for (int i = 2; i >= 0; i--) {
        glActiveTexture(GL_TEXTURE0 + i);
        glBindTexture(GL_TEXTURE_2D, 0);
    }
    glUseProgram(0);
    glViewport(0, 0, width, height);
    return true;
}

void hdr_image_give_up(Hdrbild *h) {
    if (!h) return;
    if (h->tex[0]) glDeleteTextures(3, h->tex);
    if (h->buffer) glDeleteBuffers(1, &h->buffer);
    if (h->vao) glDeleteVertexArrays(1, &h->vao);
    if (h->program) glDeleteProgram(h->program);
    char error[sizeof h->error];
    memcpy(error, h->error, sizeof error);
    memset(h, 0, sizeof *h);
    memcpy(h->error, error, sizeof error);
}

const char *hdr_image_unstretch_info(void) {
    static char text[384];
    const char *manufacturer = (const char *)glGetString(GL_VENDOR);
    const char *device = (const char *)glGetString(GL_RENDERER);
    const char *version = (const char *)glGetString(GL_VERSION);
    snprintf(text, sizeof text, "%s | %s | %s",
             manufacturer ? manufacturer : "?", device ? device : "?", version ? version : "?");
    return text;
}

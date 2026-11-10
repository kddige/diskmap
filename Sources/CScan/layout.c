// Squarified treemap layout (Bruls, Huizing, van Wijk) with cushion shading
// (van Wijk, van de Wetering) - the look WinDirStat made familiar.
//
// Layout only descends as far as pixels allow: once the items of a directory
// drop below `min_area` the rest is folded into a single cell, so the cost is
// proportional to what is visible, not to the number of files on disk.

#include "tree.h"

#include <dispatch/dispatch.h>
#include <math.h>

struct dm_layout {
    const dm_tree *tree;
    const uint32_t *order; // NULL while the scan is still running
    dm_layout_params p;
    int width, height;
    dm_cell *cells;
    size_t count, cap;
    // Scratch for sorting children while the scan is running.
    uint32_t *tmp;
    size_t tmp_len, tmp_cap;
};

static inline uint64_t node_size(const dm_tree *t, uint32_t n) {
    return atomic_load_explicit(&t->nodes[n].size, memory_order_relaxed);
}

static dm_cell *emit(dm_layout *l, uint32_t node, uint8_t type, int depth, float x, float y,
                     float w, float h, const float s[4]) {
    if (l->count == l->cap) {
        l->cap = l->cap ? l->cap * 2 : 8192;
        l->cells = realloc(l->cells, l->cap * sizeof(dm_cell));
    }
    dm_cell *c = &l->cells[l->count++];
    c->x = x;
    c->y = y;
    c->w = w;
    c->h = h;
    c->node = node;
    c->type = type;
    c->depth = (uint8_t)(depth > 255 ? 255 : depth);
    c->kind = l->tree->nodes[node].kind;
    c->chain = 0;
    if (s) memcpy(c->s, s, sizeof c->s);
    else memset(c->s, 0, sizeof c->s);
    return c;
}

static void add_ridge(float s[4], float x, float y, float w, float h, float height) {
    if (height <= 0) return;
    if (w > 0) {
        s[0] += 4 * height * (2 * x + w) / w;
        s[1] -= 4 * height / w;
    }
    if (h > 0) {
        s[2] += 4 * height * (2 * y + h) / h;
        s[3] -= 4 * height / h;
    }
}

static void layout_dir(dm_layout *l, uint32_t dir, int depth, float x, float y, float w,
                       float h, const float s[4], float height, int chain);

static inline uint32_t live_children(const Node *n) {
    return atomic_load_explicit(&n->child_count, memory_order_acquire);
}

static void place(dm_layout *l, uint32_t node, int depth, float x, float y, float w, float h,
                  const float parent_s[4], float height) {
    const dm_tree *t = l->tree;
    float s[4];
    memcpy(s, parent_s, sizeof s);
    const Node *n = &t->nodes[node];
    bool is_dir = atomic_load_explicit(&n->flags, memory_order_relaxed) & DM_F_DIR;
    uint32_t children = is_dir ? live_children(n) : 0;
    if (children > 0 && w >= l->p.min_side && h >= l->p.min_side) {
        add_ridge(s, x, y, w, h, height);
        // A folder holding nothing but one folder adds no information: fold the
        // chain into a single frame titled "a/b/c".
        int chain = 0;
        while (chain < 255) {
            // "Nothing but": a single child, or one that holds over 99% of the bytes
            // (the leftovers would be a sliver too thin to see).
            uint32_t only = l->order ? l->order[n->first_child] : n->first_child;
            if (children > 1 &&
                (!l->order || (double)node_size(t, only) < 0.99 * (double)node_size(t, node)))
                break;
            const Node *c = &t->nodes[only];
            if (!(atomic_load_explicit(&c->flags, memory_order_relaxed) & DM_F_DIR)) break;
            uint32_t grandchildren = live_children(c);
            if (grandchildren == 0) break;
            emit(l, node, DM_CELL_FRAME, depth, x, y, w, h, s);
            node = only;
            n = c;
            children = grandchildren;
            chain++;
        }
        layout_dir(l, node, depth, x, y, w, h, s, height * l->p.cushion_falloff, chain);
    } else {
        // Every leaf gets a bump of its own, however deep it sits.
        add_ridge(s, x, y, w, h, height > l->p.cushion_leaf ? height : l->p.cushion_leaf);
        emit(l, node, is_dir ? DM_CELL_DIR : DM_CELL_FILE, depth, x, y, w, h, s);
    }
}

static int cmp_live(void *ctx, const void *pa, const void *pb) {
    const dm_tree *t = ctx;
    uint64_t a = node_size(t, *(const uint32_t *)pa), b = node_size(t, *(const uint32_t *)pb);
    return a > b ? -1 : (a < b);
}

static void layout_dir(dm_layout *l, uint32_t dir, int depth, float x, float y, float w,
                       float h, const float s[4], float height, int chain) {
    const dm_tree *t = l->tree;
    const Node *d = &t->nodes[dir];
    uint32_t n = atomic_load_explicit(&d->child_count, memory_order_acquire);
    emit(l, dir, DM_CELL_FRAME, depth, x, y, w, h, s);

    // Framed directories get a title strip and a thin gutter.
    if (depth > 0 && depth <= l->p.header_max_depth && l->p.header_h > 0 &&
        w >= l->p.header_min_w && h >= l->p.header_min_h) {
        float pad = l->p.pad;
        x += pad;
        y += pad;
        w -= 2 * pad;
        h -= 2 * pad;
        emit(l, dir, DM_CELL_HEADER, depth, x, y, w, l->p.header_h, NULL)->chain = (uint8_t)chain;
        y += l->p.header_h;
        h -= l->p.header_h;
    }
    if (n == 0 || w <= 0 || h <= 0) return;

    // Children, largest first. After the scan the order is precomputed; while
    // it runs we sort a private copy of the ids.
    const uint32_t *ids;
    size_t tmp_mark = l->tmp_len;
    double total;
    if (l->order) {
        ids = l->order + d->first_child;
        total = (double)node_size(t, dir);
    } else {
        if (l->tmp_len + n > l->tmp_cap) {
            l->tmp_cap = (l->tmp_len + n) * 2;
            l->tmp = realloc(l->tmp, l->tmp_cap * sizeof(uint32_t));
        }
        uint32_t *mine = l->tmp + l->tmp_len;
        l->tmp_len += n;
        total = 0;
        for (uint32_t i = 0; i < n; i++) {
            mine[i] = d->first_child + i;
            total += (double)node_size(t, mine[i]);
        }
        qsort_r(mine, n, sizeof(uint32_t), (void *)t, cmp_live);
        ids = NULL; // `tmp` may move while we recurse; index it instead
    }
#define CHILD(i) (ids ? ids[i] : l->tmp[tmp_mark + (i)])

    if (total <= 0) {
        l->tmp_len = tmp_mark;
        return;
    }
    double scale = (double)w * h / total; // px^2 per byte
    float rx = x, ry = y, rw = w, rh = h;
    uint32_t i = 0;
    while (i < n && rw > 0.25f && rh > 0.25f) {
        double first = (double)node_size(t, CHILD(i)) * scale;
        if (first < l->p.min_area) break;
        double side = rw < rh ? rw : rh;
        double side2 = side * side;
        double sum = 0, best = INFINITY;
        uint32_t j = i;
        while (j < n) {
            double a = (double)node_size(t, CHILD(j)) * scale;
            if (a <= 0) break;
            double ns = sum + a;
            double worst = fmax(side2 * first / (ns * ns), (ns * ns) / (side2 * a));
            if (j > i && worst > best) break;
            best = worst;
            sum = ns;
            j++;
        }
        if (j == i) break;
        float thick = (float)(sum / side);
        bool column = rw >= rh; // lay the row along the shorter side
        if (thick > (column ? rw : rh)) thick = column ? rw : rh;
        double pos = 0;
        for (uint32_t k = i; k < j; k++) {
            double len = (double)node_size(t, CHILD(k)) * scale / thick;
            if (pos + len > side) len = side - pos;
            if (len <= 0) break;
            if (column) place(l, CHILD(k), depth + 1, rx, ry + (float)pos, thick, (float)len, s, height);
            else place(l, CHILD(k), depth + 1, rx + (float)pos, ry, (float)len, thick, s, height);
            pos += len;
        }
        if (column) {
            rx += thick;
            rw -= thick;
        } else {
            ry += thick;
            rh -= thick;
        }
        i = j;
    }
    // Whatever is left is too small to draw item by item.
    if (i < n && rw > 0.25f && rh > 0.25f && node_size(t, CHILD(i)) > 0) {
        float rs[4];
        memcpy(rs, s, sizeof rs);
        add_ridge(rs, rx, ry, rw, rh, height);
        emit(l, dir, DM_CELL_REST, depth + 1, rx, ry, rw, rh, rs);
    }
#undef CHILD
    l->tmp_len = tmp_mark;
}

dm_layout *dm_layout_create(const dm_tree *t, uint32_t root, int width, int height,
                            const dm_layout_params *p) {
    dm_layout *l = calloc(1, sizeof *l);
    l->tree = t;
    l->order = atomic_load_explicit(&t->order, memory_order_acquire);
    l->p = *p;
    l->width = width;
    l->height = height;
    float s[4] = {0, 0, 0, 0};
    if (width > 0 && height > 0 && root < atomic_load(&t->count))
        layout_dir(l, root, 0, 0, 0, (float)width, (float)height, s, p->cushion_height, 0);
    free(l->tmp);
    l->tmp = NULL;
    return l;
}

void dm_layout_free(dm_layout *l) {
    if (!l) return;
    free(l->cells);
    free(l);
}

const dm_cell *dm_layout_cells(const dm_layout *l, size_t *count) {
    *count = l->count;
    return l->cells;
}

bool dm_layout_find(const dm_layout *l, uint32_t node, float *x, float *y, float *w, float *h) {
    for (size_t i = 0; i < l->count; i++) {
        const dm_cell *c = &l->cells[i];
        if (c->node != node || c->type == DM_CELL_HEADER || c->type == DM_CELL_REST) continue;
        *x = c->x;
        *y = c->y;
        *w = c->w;
        *h = c->h;
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

static inline int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

void dm_layout_render(const dm_layout *l, uint8_t *rgba, uint32_t *ids,
                      const dm_render_params *rp) {
    const int W = l->width, H = l->height;
    if (W <= 0 || H <= 0) return;

    // Background doubles as the gutter between framed directories.
    uint32_t bg;
    uint8_t bgb[4] = {rp->background[0], rp->background[1], rp->background[2], 255};
    memcpy(&bg, bgb, 4);
    memset_pattern4(rgba, &bg, (size_t)W * H * 4);
    if (ids) memset(ids, 0xFF, (size_t)W * H * sizeof(uint32_t));

    // Light from the top-left, slightly towards the viewer.
    const float lx = -0.09759f, ly = -0.19518f, lz = 0.97590f;
    const float ambient = rp->ambient;
    const float diffuse = (1.0f - ambient) / lz; // a flat surface renders at full color

    float colors[DM_KIND_COUNT][3];
    for (int k = 0; k < DM_KIND_COUNT; k++) {
        for (int c = 0; c < 3; c++) colors[k][c] = rp->kind_rgb[k][c];
        if (rp->highlight_kind >= 0 && k != rp->highlight_kind) {
            // Dim everything that is not the highlighted kind.
            float g = 0.30f * colors[k][0] + 0.59f * colors[k][1] + 0.11f * colors[k][2];
            for (int c = 0; c < 3; c++) colors[k][c] = (g * 0.8f + colors[k][c] * 0.2f) * 0.38f;
        }
    }

    const float (*palette)[3] = colors; // blocks cannot capture arrays
    const size_t chunk = 512;
    size_t chunks = (l->count + chunk - 1) / chunk;
    const dm_cell *cells = l->cells;
    size_t count = l->count;
    dispatch_apply(chunks, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(size_t ci) {
        size_t end = (ci + 1) * chunk < count ? (ci + 1) * chunk : count;
        for (size_t i = ci * chunk; i < end; i++) {
            const dm_cell *c = &cells[i];
            if (c->type == DM_CELL_FRAME) continue;
            int x0 = clampi((int)lroundf(c->x), 0, W), x1 = clampi((int)lroundf(c->x + c->w), 0, W);
            int y0 = clampi((int)lroundf(c->y), 0, H), y1 = clampi((int)lroundf(c->y + c->h), 0, H);
            if (x1 <= x0 || y1 <= y0) continue;

            if (c->type == DM_CELL_HEADER) {
                uint32_t px;
                uint8_t b[4] = {rp->header[0], rp->header[1], rp->header[2], 255};
                memcpy(&px, b, 4);
                for (int y = y0; y < y1; y++) {
                    uint32_t *row = (uint32_t *)(rgba + ((size_t)y * W + x0) * 4);
                    for (int x = 0; x < x1 - x0; x++) row[x] = px;
                    if (ids) {
                        uint32_t *idrow = ids + (size_t)y * W + x0;
                        for (int x = 0; x < x1 - x0; x++) idrow[x] = c->node;
                    }
                }
                continue;
            }

            int kind = c->kind < DM_KIND_COUNT ? c->kind : 0;
            float r = palette[kind][0], g = palette[kind][1], b = palette[kind][2];
            if (c->type == DM_CELL_REST) { // many tiny items: recede a little
                r *= 0.72f;
                g *= 0.72f;
                b *= 0.72f;
            }
            const float sx1 = c->s[0], sx2 = c->s[1], sy1 = c->s[2], sy2 = c->s[3];
            for (int y = y0; y < y1; y++) {
                float ny = -(2 * sy2 * (y + 0.5f) + sy1);
                float nyl = ny * ly + lz, ny2 = ny * ny + 1.0f;
                uint8_t *row = rgba + ((size_t)y * W + x0) * 4;
                for (int x = x0; x < x1; x++, row += 4) {
                    float nx = -(2 * sx2 * (x + 0.5f) + sx1);
                    float cosa = (nx * lx + nyl) / sqrtf(nx * nx + ny2);
                    float in = ambient + diffuse * (cosa > 0 ? cosa : 0);
                    float pr = r * in, pg = g * in, pb = b * in;
                    row[0] = (uint8_t)(pr > 255 ? 255 : pr);
                    row[1] = (uint8_t)(pg > 255 ? 255 : pg);
                    row[2] = (uint8_t)(pb > 255 ? 255 : pb);
                    row[3] = 255;
                }
                if (ids) {
                    uint32_t *idrow = ids + (size_t)y * W + x0;
                    for (int x = 0; x < x1 - x0; x++) idrow[x] = c->node;
                }
            }
        }
    });
}

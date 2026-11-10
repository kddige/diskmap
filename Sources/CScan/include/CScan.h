#ifndef CSCAN_H
#define CSCAN_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// ---------------------------------------------------------------------------
// Tree
// ---------------------------------------------------------------------------

#define DM_NONE 0xFFFFFFFFu

// Node flags
#define DM_F_DIR 1
#define DM_F_UNREADABLE 2 // directory we were not allowed to open
#define DM_F_MOUNT 4      // another filesystem is mounted here; not descended
#define DM_F_HARDLINK 8   // extra link to a file already counted (size 0)
#define DM_F_SYMLINK 16
#define DM_F_REMOVED 32
#define DM_F_DATALESS 64 // cloud-only directory; not descended
#define DM_F_CLONE 128 // APFS clone whose shared data is counted on another file

// File kinds. Directories carry the kind of their largest descendant chain
// once the scan is finalized.
#define DM_KIND_OTHER 0
#define DM_KIND_VIDEO 1
#define DM_KIND_IMAGE 2
#define DM_KIND_AUDIO 3
#define DM_KIND_ARCHIVE 4
#define DM_KIND_DOCUMENT 5
#define DM_KIND_CODE 6
#define DM_KIND_BINARY 7
#define DM_KIND_DATA 8
#define DM_KIND_COUNT 9

// Scan states
#define DM_STATE_SCANNING 0
#define DM_STATE_FINALIZING 1
#define DM_STATE_DONE 2

typedef struct dm_tree dm_tree;

typedef struct {
    uint64_t size;        // allocated bytes (directories: everything beneath)
    uint32_t parent;      // DM_NONE for the root
    uint32_t child_count; // directories only
    uint32_t file_count;  // directories: files beneath
    uint16_t name_len;
    uint8_t kind;
    uint8_t flags;
    const char *name; // NUL-terminated, owned by the tree
} dm_node_info;

typedef struct {
    uint64_t files;
    uint64_t dirs;
    uint64_t bytes;
    uint64_t denied;        // directories we could not open (permissions)
    uint64_t errors;        // other failures
    uint64_t hardlink_dupes;
    uint64_t clone_files; // clones whose shared data was counted elsewhere
    uint64_t clone_bytes; // bytes left out because of that (valid once done)
    uint32_t nodes;
    int state;
    bool cancelled;
    double elapsed; // seconds
} dm_progress;

// Starts scanning `root_path` on background threads and returns immediately.
// `threads` <= 0 picks a default. Node 0 is always the root.
dm_tree *dm_scan_start(const char *root_path, int threads);
void dm_scan_cancel(dm_tree *t);
// Blocks until the scan is finalized (state DONE).
void dm_scan_wait(dm_tree *t);
// Waits for the scan to finish, then frees everything.
void dm_tree_free(dm_tree *t);

void dm_progress_get(const dm_tree *t, dm_progress *out);
const char *dm_root_path(const dm_tree *t);

// Safe to call while the scan is running (for nodes already published).
void dm_node_get(const dm_tree *t, uint32_t node, dm_node_info *out);
// i-th child; sorted by size descending once the scan is finalized.
uint32_t dm_child_at(const dm_tree *t, uint32_t dir, uint32_t i);
// Writes the absolute path; returns its length (excluding NUL).
size_t dm_node_path(const dm_tree *t, uint32_t node, char *buf, size_t cap);
// True if `node` is `ancestor` or lies beneath it.
bool dm_is_within(const dm_tree *t, uint32_t node, uint32_t ancestor);

// After the scan: forget a node (it was deleted on disk). Subtracts its size
// from every ancestor and re-sorts the affected sibling lists.
void dm_remove_node(dm_tree *t, uint32_t node);

// Directories that could not be read.
uint32_t dm_denied_count(const dm_tree *t);
uint32_t dm_denied_at(const dm_tree *t, uint32_t i);

// After the scan: per-kind byte totals and the largest files under `node`.
void dm_subtree_stats(const dm_tree *t, uint32_t node,
                      uint64_t kind_bytes[DM_KIND_COUNT],
                      uint32_t *top, uint32_t top_cap, uint32_t *top_count);

const char *dm_kind_name(int kind);

// ---------------------------------------------------------------------------
// Treemap layout + rendering
// ---------------------------------------------------------------------------

#define DM_CELL_FILE 0   // a file
#define DM_CELL_DIR 1    // a directory too small to subdivide
#define DM_CELL_REST 2   // the tail of small items in a directory
#define DM_CELL_HEADER 3 // title strip of a framed directory
#define DM_CELL_FRAME 4  // bounds of a subdivided directory (not drawn)

typedef struct {
    float x, y, w, h; // pixels, origin top-left
    uint32_t node;
    uint8_t type;
    uint8_t depth;
    uint8_t kind;
    uint8_t chain; // HEADER: single-child ancestors folded into this frame
    float s[4]; // cushion surface: x linear, x quadratic, y linear, y quadratic
} dm_cell;

typedef struct {
    float header_h;       // title strip height in px; 0 disables headers
    float header_min_w;   // a directory needs at least this size to get one
    float header_min_h;
    int header_max_depth; // relative to the layout root
    float pad;            // inset of framed directories, px
    float min_side;       // directories narrower than this are not subdivided
    float min_area;       // items smaller than this (px^2) fold into "rest"
    float cushion_height; // 0 = flat
    float cushion_falloff;
    float cushion_leaf; // minimum ridge height for leaf cells
} dm_layout_params;

typedef struct {
    uint8_t kind_rgb[DM_KIND_COUNT][3];
    uint8_t background[3];
    uint8_t header[3];
    int highlight_kind; // -1 = none; otherwise other kinds are dimmed
    float ambient;      // 0..1
} dm_render_params;

typedef struct dm_layout dm_layout;

dm_layout *dm_layout_create(const dm_tree *t, uint32_t root, int width, int height,
                            const dm_layout_params *p);
void dm_layout_free(dm_layout *l);
const dm_cell *dm_layout_cells(const dm_layout *l, size_t *count);
// Bounds of `node` in this layout. Returns false if it is not drawn on its own.
bool dm_layout_find(const dm_layout *l, uint32_t node, float *x, float *y, float *w, float *h);
// Fills `rgba` (width*height*4, top row first) and, if non-NULL, `ids`
// (width*height node ids, DM_NONE where nothing is drawn).
void dm_layout_render(const dm_layout *l, uint8_t *rgba, uint32_t *ids,
                      const dm_render_params *rp);

#endif

// Internal tree representation shared by the scanner and the layout engine.
#ifndef DM_TREE_H
#define DM_TREE_H

#include "CScan.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>

typedef struct {
    _Atomic uint64_t size;
    uint32_t parent;
    union {
        uint32_t first_child; // directories
        // Files flagged DM_F_CLONE: what was left out of `size` because it is
        // counted on another file, in 512-byte blocks.
        uint32_t cut;
    };
    _Atomic uint32_t child_count; // published last; readers load this first
    _Atomic uint32_t file_count;
    uint32_t name_off;
    uint16_t name_len;
    uint8_t kind;
    _Atomic uint8_t flags;
} Node;

_Static_assert(sizeof(Node) == 32, "Node must stay 32 bytes");

typedef struct {
    char *path;
    uint32_t path_len;
    uint32_t node;
    uint32_t dev;
    uint32_t expected; // entry count from the parent listing; UINT32_MAX = unknown
} Task;

// Which node the data behind an id is counted on. Used for hard links (id =
// inode) and for clone families whose original was not scanned (id = the id
// of that original). Kept after the scan so that rescanning one folder can
// tell what is already counted outside it.
typedef struct {
    uint64_t id;
    uint32_t dev;
    uint32_t used;
    // DM_NONE: counted outside the folder this (re)scan covers. Hard links
    // while scanning: the directory the counted link is in.
    uint32_t node;
    uint32_t index; // hard links while scanning: position within that directory
} Owner;

typedef struct {
    Owner *slots;
    size_t cap, len;
} OwnerMap;

// A file that was cloned from another one (APFS copy-on-write copy).
typedef struct {
    uint64_t clone_id; // file id of the file it was cloned from
    uint64_t file_id;
    uint32_t node; // index within the directory until published, then global
    uint32_t dev;
} Clone;

struct dm_tree {
    Node *nodes;
    size_t cap, nodes_bytes;
    _Atomic uint32_t count;
    char *names;
    size_t names_cap, names_len, names_bytes;
    // order[first_child + i] = i-th largest child. NULL until finalized.
    // Lives in `order_map`, reserved up front so a rescanned folder can be
    // appended in place.
    _Atomic(uint32_t *) order;
    uint32_t *order_map;
    size_t order_bytes;

    pthread_mutex_t mu; // guards the queue, appends and `denied`
    pthread_cond_t cv;
    Task *queue;
    size_t qlen, qcap;
    int active;

    pthread_mutex_t hl_mu; // guards `links` while scanning
    OwnerMap links;
    OwnerMap families; // written by the finalizer only

    Clone *clones; // guarded by `mu`; resolved and freed when finalizing
    size_t clones_len, clones_cap;
    // Ids of every file that is not itself a clone, one list per worker, so
    // the finalizer can tell whether a clone's original was scanned too.
    uint64_t **id_lists;
    size_t *id_lens;
    int id_lists_len;
    _Atomic uint64_t clone_files, clone_bytes;

    uint32_t *denied;
    size_t denied_len, denied_cap;

    _Atomic int cancel;
    _Atomic int state;
    _Atomic uint64_t dirs, errors, hl_dupes, denied_count;
    uint64_t t_start;
    _Atomic uint64_t t_end;

    int nthreads;
    pthread_t *threads;
    pthread_t finisher;
    bool joined;
    // Root is on an APFS volume other than the sealed system volume: entry
    // counts are trustworthy and there are no firmlinks to follow.
    bool fast_apfs;
    char *root_path;
    uint32_t root_dev;
    fsid_t root_fsid;

    // After the scan, readers on background threads (layout, statistics) hold
    // this for reading; removing a node and applying a rescan hold it for
    // writing. The main thread reads without it: it is the only writer.
    pthread_rwlock_t rw;
    uint64_t version; // bumped by every change after the scan

    // A rescan of one folder of `base`. `base` must not change or be freed
    // while this scan runs.
    dm_tree *base;
    uint32_t base_node;
    uint64_t base_version;
    int64_t lookup_budget;
    bool applied;
    // What the folder held in `base` before, to take out of its counters.
    uint64_t old_dirs, old_dupes, old_clone_files, old_clone_bytes;
};

void dm_sort_children(const dm_tree *t, uint32_t *ids, uint32_t n);

#endif

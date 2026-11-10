// Internal tree representation shared by the scanner and the layout engine.
#ifndef DM_TREE_H
#define DM_TREE_H

#include "CScan.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    _Atomic uint64_t size;
    uint32_t parent;
    uint32_t first_child;
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

typedef struct {
    uint64_t ino;
    uint32_t dev;
    uint32_t used;
} HardLink;

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
    _Atomic(uint32_t *) order;

    pthread_mutex_t mu; // guards the queue, appends and `denied`
    pthread_cond_t cv;
    Task *queue;
    size_t qlen, qcap;
    int active;

    pthread_mutex_t hl_mu;
    HardLink *hl;
    size_t hl_cap, hl_len;

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
};

void dm_sort_children(const dm_tree *t, uint32_t *ids, uint32_t n);

#endif

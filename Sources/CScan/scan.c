// Parallel directory scanner for macOS.
//
// One getattrlistbulk() call returns names, types and allocated sizes for a
// whole batch of directory entries, so a directory costs open + a few bulk
// reads + close instead of one stat per file. Directories are handed out to a
// pool of worker threads from a LIFO queue.
//
// The tree is a flat append-only array of 32-byte nodes; the children of a
// directory are contiguous. The arrays live in a large lazily-committed
// mapping so they never move, which lets the UI read the tree while it grows.

#include "tree.h"

#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <pthread/qos.h>
#include <stdio.h>
#include <sys/attr.h>
#include <sys/fsgetpath.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/vnode.h>
#include <unistd.h>

#ifndef SF_DATALESS
#define SF_DATALESS 0x40000000
#endif

#define ATTR_BUF_SIZE (256 * 1024)
#define MAX_NODES ((size_t)1 << 28)        // 268M entries, 8 GB of address space
#define MAX_NAME_BYTES (((size_t)1 << 32) - 4096)
// Rescanning a folder looks originals of clones up by name in the full scan.
// Past this many names compared, it settles for where the original is.
#define LOOKUP_BUDGET 20000000

// ---------------------------------------------------------------------------
// File kinds by extension
// ---------------------------------------------------------------------------

static const char *const KIND_NAMES[DM_KIND_COUNT] = {
    "Other", "Video", "Images", "Audio", "Archives & disk images",
    "Documents", "Code & text", "Apps & binaries", "Data & models",
};

const char *dm_kind_name(int kind) {
    return (kind >= 0 && kind < DM_KIND_COUNT) ? KIND_NAMES[kind] : "Other";
}

static const char *const EXT_VIDEO =
    "mp4 mov mkv avi m4v webm wmv flv mts m2ts mpg mpeg braw r3d mxf 3gp";
static const char *const EXT_IMAGE =
    "jpg jpeg png gif heic heif tiff tif cr2 cr3 nef arw dng raf orf rw2 psd psb webp bmp "
    "svg ico icns avif exr hdr tga ai sketch fig xcf";
static const char *const EXT_AUDIO =
    "mp3 m4a wav flac aac ogg aiff aif opus caf mid midi wma m4b";
static const char *const EXT_ARCHIVE =
    "zip tar gz tgz bz2 tbz2 xz txz 7z rar zst pkg dmg iso xip ipa jar war deb rpm lz4 br "
    "img raw qcow2 vmdk vdi vhd vhdx hdd sparseimage cpio crate whl gem nupkg apk aab cab "
    "msi asar pak";
static const char *const EXT_DOCUMENT =
    "pdf doc docx xls xlsx ppt pptx pages numbers key epub rtf odt ods odp mobi djvu";
static const char *const EXT_CODE =
    "c h cc cpp hpp m mm rs swift js mjs cjs ts tsx jsx py go java kt rb php html htm css "
    "scss json xml yaml yml toml md txt sh zsh lua sql csv tsv log map vue svelte ipynb "
    "lock plist strings xib storyboard cs r pl ex exs hs scala dart gradle cmake mk";
static const char *const EXT_BINARY =
    "dylib so a o exe dll node wasm rlib rmeta pcm swiftmodule class pyc pyo dex lib obj "
    "pdb tbd bc nib car metallib";
static const char *const EXT_DATA =
    "sqlite sqlite3 db realm mdb ldb sst parquet bin dat pack idx npy npz safetensors gguf "
    "ggml ckpt pt pth onnx h5 hdf5 mlmodel tflite pb arrow feather wal shm sqlite-wal "
    "sqlite-shm db-wal db-shm rdb dump bak pickle pkl tfrecord";

#define EXT_MAX 15
#define EXT_SLOTS 1024 // power of two, comfortably sparse

static struct {
    char ext[EXT_MAX + 1];
    uint8_t kind;
} g_ext[EXT_SLOTS];
static pthread_once_t g_ext_once = PTHREAD_ONCE_INIT;

static uint32_t ext_hash(const char *s, size_t n) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < n; i++) h = (h ^ (uint8_t)s[i]) * 16777619u;
    return h;
}

static void ext_add_list(const char *list, uint8_t kind) {
    const char *p = list;
    while (*p) {
        while (*p == ' ') p++;
        const char *e = p;
        while (*e && *e != ' ') e++;
        size_t n = (size_t)(e - p);
        if (n > 0 && n <= EXT_MAX) {
            uint32_t i = ext_hash(p, n) & (EXT_SLOTS - 1);
            while (g_ext[i].ext[0]) i = (i + 1) & (EXT_SLOTS - 1);
            memcpy(g_ext[i].ext, p, n);
            g_ext[i].ext[n] = 0;
            g_ext[i].kind = kind;
        }
        p = e;
    }
}

static void ext_init(void) {
    ext_add_list(EXT_VIDEO, DM_KIND_VIDEO);
    ext_add_list(EXT_IMAGE, DM_KIND_IMAGE);
    ext_add_list(EXT_AUDIO, DM_KIND_AUDIO);
    ext_add_list(EXT_ARCHIVE, DM_KIND_ARCHIVE);
    ext_add_list(EXT_DOCUMENT, DM_KIND_DOCUMENT);
    ext_add_list(EXT_CODE, DM_KIND_CODE);
    ext_add_list(EXT_BINARY, DM_KIND_BINARY);
    ext_add_list(EXT_DATA, DM_KIND_DATA);
}

static uint8_t kind_for_name(const char *name, size_t len) {
    size_t i = len;
    while (i > 0 && name[i - 1] != '.' && len - i <= EXT_MAX) i--;
    if (i <= 1 || name[i - 1] != '.') return DM_KIND_OTHER; // no dot, or a dotfile
    size_t dot = i - 1;
    size_t n = len - dot - 1;
    if (n == 0 || n > EXT_MAX) return DM_KIND_OTHER;
    char ext[EXT_MAX + 1];
    for (size_t i = 0; i < n; i++) {
        char c = name[dot + 1 + i];
        ext[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
    }
    ext[n] = 0;
    uint32_t slot = ext_hash(ext, n) & (EXT_SLOTS - 1);
    while (g_ext[slot].ext[0]) {
        if (memcmp(g_ext[slot].ext, ext, n + 1) == 0) return g_ext[slot].kind;
        slot = (slot + 1) & (EXT_SLOTS - 1);
    }
    return DM_KIND_OTHER;
}

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

static double seconds_between(uint64_t a, uint64_t b) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)(b - a) * tb.numer / tb.denom / 1e9;
}

// ---------------------------------------------------------------------------
// Hard links: count each inode once
// ---------------------------------------------------------------------------

static uint64_t hl_hash(uint64_t ino, uint32_t dev) {
    uint64_t x = ino ^ ((uint64_t)dev << 40);
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;
    return x;
}

static const Owner *owner_find(const OwnerMap *m, uint32_t dev, uint64_t id) {
    if (!m->cap) return NULL;
    size_t i = hl_hash(id, dev) & (m->cap - 1);
    while (m->slots[i].used) {
        if (m->slots[i].id == id && m->slots[i].dev == dev) return &m->slots[i];
        i = (i + 1) & (m->cap - 1);
    }
    return NULL;
}

// The entry for (dev, id), added if it was not there yet.
static Owner *owner_get(OwnerMap *m, uint32_t dev, uint64_t id, bool *added) {
    if ((m->len + 1) * 10 > m->cap * 7) {
        size_t ncap = m->cap ? m->cap * 2 : 4096;
        Owner *ntab = calloc(ncap, sizeof(Owner));
        for (size_t i = 0; i < m->cap; i++) {
            if (!m->slots[i].used) continue;
            size_t j = hl_hash(m->slots[i].id, m->slots[i].dev) & (ncap - 1);
            while (ntab[j].used) j = (j + 1) & (ncap - 1);
            ntab[j] = m->slots[i];
        }
        free(m->slots);
        m->slots = ntab;
        m->cap = ncap;
    }
    size_t i = hl_hash(id, dev) & (m->cap - 1);
    while (m->slots[i].used) {
        if (m->slots[i].id == id && m->slots[i].dev == dev) {
            *added = false;
            return &m->slots[i];
        }
        i = (i + 1) & (m->cap - 1);
    }
    m->slots[i] = (Owner){.id = id, .dev = dev, .used = 1, .node = DM_NONE};
    m->len++;
    *added = true;
    return &m->slots[i];
}

// During a rescan of one folder: is `owner`, a node of the full scan, still
// there and outside the folder being rescanned?
static bool counted_outside(const dm_tree *base, uint32_t owner, uint32_t folder) {
    if (owner == DM_NONE) return false;
    for (uint32_t n = owner; n != DM_NONE; n = base->nodes[n].parent) {
        if (n == folder) return false;
        if (atomic_load_explicit(&base->nodes[n].flags, memory_order_relaxed) & DM_F_REMOVED)
            return false;
    }
    return true;
}

// Returns true if (dev, ino) is already counted on another link. Otherwise
// this link, entry `index` of directory `dir`, becomes the one that counts.
static bool hardlink_seen(dm_tree *t, uint32_t dev, uint64_t ino, uint32_t dir, uint32_t index) {
    bool added;
    pthread_mutex_lock(&t->hl_mu);
    Owner *o = owner_get(&t->links, dev, ino, &added);
    if (added) {
        o->node = dir;
        o->index = index;
        if (t->base) {
            const Owner *b = owner_find(&t->base->links, dev, ino);
            if (b && counted_outside(t->base, b->node, t->base_node)) {
                o->node = DM_NONE;
                added = false;
            }
        }
    }
    pthread_mutex_unlock(&t->hl_mu);
    return !added;
}

// Once the tree is complete, turn (directory, position) into node ids.
static void resolve_links(dm_tree *t) {
    for (size_t i = 0; i < t->links.cap; i++) {
        Owner *o = &t->links.slots[i];
        if (!o->used || o->node == DM_NONE) continue;
        const Node *dir = &t->nodes[o->node];
        // The directory may not have fitted in the tree.
        bool there = o->index < atomic_load_explicit(&dir->child_count, memory_order_relaxed);
        o->node = there ? dir->first_child + o->index : DM_NONE;
        o->index = 0;
    }
}

// ---------------------------------------------------------------------------
// Workers
// ---------------------------------------------------------------------------

typedef struct {
    char *attr_buf;
    Node *nodes; // children of the directory being read
    size_t nodes_len, nodes_cap;
    char *names;
    size_t names_len, names_cap;
    uint32_t *subdirs; // indexes into `nodes` that should be descended
    uint32_t *expected; // their entry counts, parallel to `subdirs`
    size_t subdirs_len, subdirs_cap;
    Task *tasks;
    size_t tasks_cap;
    Clone *clones;
    size_t clones_len, clones_cap;
    uint64_t *ids; // whole scan, not per directory
    size_t ids_len, ids_cap;
} Scratch;

static inline uint64_t id_key(uint32_t dev, uint64_t file_id) {
    return file_id ^ ((uint64_t)dev << 40);
}

static void mark_denied(dm_tree *t, uint32_t node) {
    atomic_fetch_or(&t->nodes[node].flags, DM_F_UNREADABLE);
    pthread_mutex_lock(&t->mu);
    if (t->denied_len == t->denied_cap) {
        t->denied_cap = t->denied_cap ? t->denied_cap * 2 : 64;
        t->denied = realloc(t->denied, t->denied_cap * sizeof(uint32_t));
    }
    t->denied[t->denied_len++] = node;
    pthread_mutex_unlock(&t->mu);
    atomic_fetch_add(&t->denied_count, 1);
}

// open() for paths longer than PATH_MAX: walk down one component at a time.
static int open_long(const char *path) {
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    const char *p = path;
    char comp[NAME_MAX + 1];
    while (fd >= 0 && *p) {
        while (*p == '/') p++;
        const char *e = p;
        while (*e && *e != '/') e++;
        size_t n = (size_t)(e - p);
        if (n == 0) break;
        if (n > NAME_MAX) {
            close(fd);
            errno = ENAMETOOLONG;
            return -1;
        }
        memcpy(comp, p, n);
        comp[n] = 0;
        int next = openat(fd, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int saved = errno;
        close(fd);
        errno = saved;
        fd = next;
        p = e;
    }
    return fd;
}

static void scan_dir(dm_tree *t, Scratch *sc, const Task *task) {
    int fd = open(task->path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0 && errno == ENAMETOOLONG) fd = open_long(task->path);
    if (fd < 0) {
        if (errno == EACCES || errno == EPERM) mark_denied(t, task->node);
        else atomic_fetch_add(&t->errors, 1);
        return;
    }

    // Stay on one filesystem. A directory on a different device is either a
    // mount point (skip) or an APFS firmlink from the system volume into the
    // data volume (follow). Mounted volume roots have inode 2.
    // Only the sealed system volume has firmlinks, so everywhere else the
    // mount flag reported by the parent listing is enough and fstat is skipped.
    struct stat st;
    uint32_t dev = task->dev;
    if (!t->fast_apfs && fstat(fd, &st) == 0 && (uint32_t)st.st_dev != task->dev) {
        struct statfs sfs;
        bool firmlink = task->node != 0 && st.st_ino != 2 && fstatfs(fd, &sfs) == 0 &&
                        strcmp(sfs.f_fstypename, "apfs") == 0;
        if (task->node != 0 && !firmlink) {
            atomic_fetch_or(&t->nodes[task->node].flags, DM_F_MOUNT);
            close(fd);
            return;
        }
        dev = (uint32_t)st.st_dev;
    }

    struct attrlist al = {0};
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME |
                    ATTR_CMN_OBJTYPE | ATTR_CMN_ACCESSMASK | ATTR_CMN_FLAGS | ATTR_CMN_FILEID;
    al.dirattr = ATTR_DIR_ENTRYCOUNT | ATTR_DIR_MOUNTSTATUS;
    al.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE;
    // Clones share their data; this lets the finalizer count it once. (The
    // clone id costs nothing extra; EXT_FLAGS and PRIVATESIZE halve the speed.)
    al.forkattr = ATTR_CMNEXT_CLONEID;

    sc->nodes_len = sc->names_len = sc->subdirs_len = sc->clones_len = 0;
    uint64_t bytes = 0;
    uint32_t files = 0, folders = 0;
    bool denied = false;
    uint32_t received = 0;

    // When the parent listing told us how many entries to expect, stop as soon
    // as we have them instead of paying for one more call that returns zero.
    while (received < task->expected) {
        int n = getattrlistbulk(fd, &al, sc->attr_buf, ATTR_BUF_SIZE, FSOPT_ATTR_CMN_EXTENDED);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EACCES || errno == EPERM) denied = true;
            else atomic_fetch_add(&t->errors, 1);
        }
        if (n <= 0) break;
        received += (uint32_t)n;
        char *p = sc->attr_buf;
        for (int i = 0; i < n; i++) {
            uint32_t entry_len;
            memcpy(&entry_len, p, 4);
            char *f = p + 4;
            p += entry_len;

            attribute_set_t ret;
            memcpy(&ret, f, sizeof ret);
            f += sizeof ret;

            uint32_t err = 0;
            if (ret.commonattr & ATTR_CMN_ERROR) {
                memcpy(&err, f, 4);
                f += 4;
            }
            const char *name = NULL;
            size_t name_len = 0;
            if (ret.commonattr & ATTR_CMN_NAME) {
                attrreference_t ref;
                memcpy(&ref, f, sizeof ref);
                name = f + ref.attr_dataoffset;
                name_len = ref.attr_length ? ref.attr_length - 1 : 0;
                f += sizeof ref;
            }
            if (!name || name_len == 0) continue;
            if (err) {
                atomic_fetch_add(&t->errors, 1);
                continue;
            }
            uint32_t type = VNON, mode = 0, bsd_flags = 0, mount_status = 0, links = 1;
            uint32_t entry_count = UINT32_MAX;
            uint64_t file_id = 0, alloc = 0, clone_id = 0;
            if (ret.commonattr & ATTR_CMN_OBJTYPE) {
                memcpy(&type, f, 4);
                f += 4;
            }
            if (ret.commonattr & ATTR_CMN_ACCESSMASK) {
                memcpy(&mode, f, 4);
                f += 4;
            }
            if (ret.commonattr & ATTR_CMN_FLAGS) {
                memcpy(&bsd_flags, f, 4);
                f += 4;
            }
            if (ret.commonattr & ATTR_CMN_FILEID) {
                memcpy(&file_id, f, 8);
                f += 8;
            }
            if (ret.dirattr & ATTR_DIR_ENTRYCOUNT) {
                memcpy(&entry_count, f, 4);
                f += 4;
            }
            if (ret.dirattr & ATTR_DIR_MOUNTSTATUS) {
                memcpy(&mount_status, f, 4);
                f += 4;
            }
            if (ret.fileattr & ATTR_FILE_LINKCOUNT) {
                memcpy(&links, f, 4);
                f += 4;
            }
            if (ret.fileattr & ATTR_FILE_ALLOCSIZE) {
                memcpy(&alloc, f, 8);
                f += 8;
            }
            if (ret.forkattr & ATTR_CMNEXT_CLONEID) {
                memcpy(&clone_id, f, 8);
                f += 8;
            }
            if (name_len > UINT16_MAX) name_len = UINT16_MAX;

            if (sc->nodes_len == sc->nodes_cap) {
                sc->nodes_cap = sc->nodes_cap ? sc->nodes_cap * 2 : 1024;
                sc->nodes = realloc(sc->nodes, sc->nodes_cap * sizeof(Node));
            }
            if (sc->names_len + name_len + 1 > sc->names_cap) {
                sc->names_cap = (sc->names_cap ? sc->names_cap * 2 : 65536) + name_len + 1;
                sc->names = realloc(sc->names, sc->names_cap);
            }

            Node *nd = &sc->nodes[sc->nodes_len];
            memset(nd, 0, sizeof *nd);
            nd->parent = task->node;
            nd->name_off = (uint32_t)sc->names_len; // rebased when published
            nd->name_len = (uint16_t)name_len;
            memcpy(sc->names + sc->names_len, name, name_len);
            sc->names[sc->names_len + name_len] = 0;
            sc->names_len += name_len + 1;

            uint8_t flags = 0;
            if (type == VDIR) {
                flags = DM_F_DIR;
                folders++;
                if (mount_status & DIR_MNTSTATUS_MNTPOINT) flags |= DM_F_MOUNT;
                else if (bsd_flags & SF_DATALESS) flags |= DM_F_DATALESS;
                else if (!t->fast_apfs || entry_count != 0) { // empty: nothing to open
                    if (sc->subdirs_len == sc->subdirs_cap) {
                        sc->subdirs_cap = sc->subdirs_cap ? sc->subdirs_cap * 2 : 256;
                        sc->subdirs = realloc(sc->subdirs, sc->subdirs_cap * sizeof(uint32_t));
                        sc->expected = realloc(sc->expected, sc->subdirs_cap * sizeof(uint32_t));
                    }
                    sc->expected[sc->subdirs_len] = t->fast_apfs ? entry_count : UINT32_MAX;
                    sc->subdirs[sc->subdirs_len++] = (uint32_t)sc->nodes_len;
                }
            } else {
                if (type == VLNK) flags |= DM_F_SYMLINK;
                if (links > 1 && type == VREG &&
                    hardlink_seen(t, dev, file_id, task->node, (uint32_t)sc->nodes_len)) {
                    flags |= DM_F_HARDLINK;
                    alloc = 0;
                    atomic_fetch_add(&t->hl_dupes, 1);
                }
                // A file that was never cloned carries its own id as clone id.
                if (type == VREG && alloc > 0 && (ret.forkattr & ATTR_CMNEXT_CLONEID)) {
                    if (clone_id == file_id) {
                        if (sc->ids_len == sc->ids_cap) {
                            sc->ids_cap = sc->ids_cap ? sc->ids_cap * 2 : 16384;
                            sc->ids = realloc(sc->ids, sc->ids_cap * sizeof(uint64_t));
                        }
                        sc->ids[sc->ids_len++] = id_key(dev, file_id);
                    } else {
                        if (sc->clones_len == sc->clones_cap) {
                            sc->clones_cap = sc->clones_cap ? sc->clones_cap * 2 : 256;
                            sc->clones = realloc(sc->clones, sc->clones_cap * sizeof(Clone));
                        }
                        sc->clones[sc->clones_len++] = (Clone){
                            .clone_id = clone_id, .file_id = file_id,
                            .node = (uint32_t)sc->nodes_len, .dev = dev};
                    }
                }
                nd->kind = kind_for_name(name, name_len);
                // Unix executables carry no extension ("Electron Framework", "node").
                if (nd->kind == DM_KIND_OTHER && type == VREG && (mode & 0111) &&
                    !memchr(name, '.', name_len))
                    nd->kind = DM_KIND_BINARY;
                atomic_store_explicit(&nd->size, alloc, memory_order_relaxed);
                bytes += alloc;
                files++;
            }
            atomic_store_explicit(&nd->flags, flags, memory_order_relaxed);
            sc->nodes_len++;
        }
    }
    close(fd);
    if (denied && sc->nodes_len == 0) mark_denied(t, task->node);

    // Build the tasks for the subdirectories outside the lock.
    size_t nsub = sc->subdirs_len;
    if (nsub > sc->tasks_cap) {
        sc->tasks_cap = nsub * 2;
        sc->tasks = realloc(sc->tasks, sc->tasks_cap * sizeof(Task));
    }
    bool root_slash = task->path_len == 1 && task->path[0] == '/';
    for (size_t i = 0; i < nsub; i++) {
        const Node *nd = &sc->nodes[sc->subdirs[i]];
        size_t base = root_slash ? 0 : task->path_len;
        size_t len = base + 1 + nd->name_len;
        char *path = malloc(len + 1);
        memcpy(path, task->path, base);
        path[base] = '/';
        memcpy(path + base + 1, sc->names + nd->name_off, nd->name_len);
        path[len] = 0;
        sc->tasks[i].path = path;
        sc->tasks[i].path_len = (uint32_t)len;
        sc->tasks[i].node = sc->subdirs[i]; // rebased below
        sc->tasks[i].dev = dev;
        sc->tasks[i].expected = sc->expected[i];
    }

    // Publish the children and queue the subdirectories.
    size_t count = sc->nodes_len;
    bool published = false;
    if (count > 0) {
        pthread_mutex_lock(&t->mu);
        uint32_t base = atomic_load_explicit(&t->count, memory_order_relaxed);
        if ((size_t)base + count <= t->cap && t->names_len + sc->names_len <= t->names_cap) {
            uint32_t names_base = (uint32_t)t->names_len;
            memcpy(t->names + t->names_len, sc->names, sc->names_len);
            t->names_len += sc->names_len;
            for (size_t i = 0; i < count; i++) sc->nodes[i].name_off += names_base;
            memcpy(&t->nodes[base], sc->nodes, count * sizeof(Node));
            atomic_store_explicit(&t->count, base + (uint32_t)count, memory_order_release);

            Node *dir = &t->nodes[task->node];
            dir->first_child = base;
            atomic_store_explicit(&dir->child_count, (uint32_t)count, memory_order_release);

            if (t->qlen + nsub > t->qcap) {
                t->qcap = (t->qcap + nsub) * 2;
                t->queue = realloc(t->queue, t->qcap * sizeof(Task));
            }
            for (size_t i = 0; i < nsub; i++) {
                sc->tasks[i].node += base;
                t->queue[t->qlen++] = sc->tasks[i];
            }
            if (sc->clones_len) {
                if (t->clones_len + sc->clones_len > t->clones_cap) {
                    t->clones_cap = (t->clones_cap + sc->clones_len) * 2;
                    t->clones = realloc(t->clones, t->clones_cap * sizeof(Clone));
                }
                for (size_t i = 0; i < sc->clones_len; i++) {
                    sc->clones[i].node += base;
                    t->clones[t->clones_len++] = sc->clones[i];
                }
            }
            published = true;
            if (nsub > 1) pthread_cond_broadcast(&t->cv);
            else if (nsub == 1) pthread_cond_signal(&t->cv);
        } else {
            atomic_fetch_add(&t->errors, 1); // out of room; drop this directory
        }
        pthread_mutex_unlock(&t->mu);
    }
    if (!published) {
        for (size_t i = 0; i < nsub; i++) free(sc->tasks[i].path);
        return;
    }

    if (folders) atomic_fetch_add_explicit(&t->dirs, folders, memory_order_relaxed);
    // Roll the sizes up to the root so every directory's total is always live.
    if (files) {
        for (uint32_t n = task->node; n != DM_NONE; n = t->nodes[n].parent) {
            atomic_fetch_add_explicit(&t->nodes[n].size, bytes, memory_order_relaxed);
            atomic_fetch_add_explicit(&t->nodes[n].file_count, files, memory_order_relaxed);
        }
    }
}

static void *worker_main(void *arg) {
    dm_tree *t = arg;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    // Never pull cloud-only files or folders down just to measure them.
    setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                   IOPOL_MATERIALIZE_DATALESS_FILES_OFF);

    Scratch sc = {0};
    sc.attr_buf = malloc(ATTR_BUF_SIZE);
    bool working = false;

    pthread_mutex_lock(&t->mu);
    for (;;) {
        if (working) {
            working = false;
            t->active--;
        }
        while (t->qlen == 0 && t->active > 0 && !atomic_load(&t->cancel))
            pthread_cond_wait(&t->cv, &t->mu);
        if (t->qlen == 0 || atomic_load(&t->cancel)) {
            pthread_cond_broadcast(&t->cv);
            break;
        }
        Task task = t->queue[--t->qlen];
        t->active++;
        working = true;
        pthread_mutex_unlock(&t->mu);

        scan_dir(t, &sc, &task);
        free(task.path);

        pthread_mutex_lock(&t->mu);
    }
    pthread_mutex_unlock(&t->mu);

    free(sc.attr_buf);
    free(sc.nodes);
    free(sc.names);
    free(sc.subdirs);
    free(sc.expected);
    free(sc.tasks);
    free(sc.clones);
    pthread_mutex_lock(&t->mu);
    t->id_lists = realloc(t->id_lists, (size_t)(t->id_lists_len + 1) * sizeof *t->id_lists);
    t->id_lens = realloc(t->id_lens, (size_t)(t->id_lists_len + 1) * sizeof *t->id_lens);
    t->id_lists[t->id_lists_len] = sc.ids;
    t->id_lens[t->id_lists_len++] = sc.ids_len;
    pthread_mutex_unlock(&t->mu);
    return NULL;
}

// ---------------------------------------------------------------------------
// Finalize: sorted child order + directory kinds
// ---------------------------------------------------------------------------

static int cmp_children(void *ctx, const void *pa, const void *pb) {
    const dm_tree *t = ctx;
    uint32_t a = *(const uint32_t *)pa, b = *(const uint32_t *)pb;
    const Node *na = &t->nodes[a], *nb = &t->nodes[b];
    int ra = (atomic_load_explicit(&na->flags, memory_order_relaxed) & DM_F_REMOVED) != 0;
    int rb = (atomic_load_explicit(&nb->flags, memory_order_relaxed) & DM_F_REMOVED) != 0;
    if (ra != rb) return ra - rb;
    uint64_t sa = atomic_load_explicit(&na->size, memory_order_relaxed);
    uint64_t sb = atomic_load_explicit(&nb->size, memory_order_relaxed);
    if (sa != sb) return sa > sb ? -1 : 1;
    return a < b ? -1 : (a > b);
}

void dm_sort_children(const dm_tree *t, uint32_t *ids, uint32_t n) {
    if (n > 1) qsort_r(ids, n, sizeof(uint32_t), (void *)t, cmp_children);
}

// Clones at least this big are checked for data of their own.
#define CLONE_VERIFY_MIN (8u << 20)

static int cmp_clones(const void *pa, const void *pb) {
    const Clone *a = pa, *b = pb;
    if (a->dev != b->dev) return a->dev < b->dev ? -1 : 1;
    if (a->clone_id != b->clone_id) return a->clone_id < b->clone_id ? -1 : 1;
    if (a->file_id != b->file_id) return a->file_id < b->file_id ? -1 : 1;
    return 0;
}

static void free_clone_data(dm_tree *t) {
    for (int i = 0; i < t->id_lists_len; i++) free(t->id_lists[i]);
    free(t->id_lists);
    free(t->id_lens);
    free(t->clones);
    t->id_lists = NULL;
    t->id_lens = NULL;
    t->id_lists_len = 0;
    t->clones = NULL;
    t->clones_len = t->clones_cap = 0;
}

// Bytes of `node` that no other file shares, or UINT64_MAX if unknown.
static uint64_t private_size(const dm_tree *t, uint32_t node) {
    char path[PATH_MAX * 2];
    size_t len = dm_node_path(t, node, path, sizeof path);
    if (len == 0 || len >= sizeof path) return UINT64_MAX;
    struct attrlist al = {0};
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.forkattr = ATTR_CMNEXT_PRIVATESIZE;
    struct {
        uint32_t len;
        uint64_t size;
    } __attribute__((packed)) buf;
    if (getattrlist(path, &al, &buf, sizeof buf, FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW) != 0)
        return UINT64_MAX;
    return buf.size;
}

// "/System/Volumes/Data/Users/a" and "/Users/a" are the same folder; so are
// "/System/Volumes/Data" and "/". Returns the common form: "/Users/a" and "".
static const char *volume_relative(const char *path) {
    static const char data[] = "/System/Volumes/Data";
    size_t n = sizeof data - 1;
    if (strncmp(path, data, n) == 0 && (path[n] == '/' || path[n] == 0)) path += n;
    if (path[0] == '/' && path[1] == 0) path++;
    return path;
}

// The part of `path` after `dir` (starting with '/') if it lies beneath it.
static const char *beneath(const char *path, const char *dir) {
    size_t n = strlen(dir);
    return strncmp(path, dir, n) == 0 && path[n] == '/' ? path + n : NULL;
}

// During a rescan of one folder: is the file a clone was made from part of
// the full scan, outside this folder? Then its data is counted there.
static bool original_in_base(dm_tree *t, uint32_t dev, uint64_t file_id) {
    const dm_tree *base = t->base;
    if (dev != t->root_dev) return false;
    char path[PATH_MAX];
    ssize_t len = fsgetpath(path, sizeof path, &t->root_fsid, file_id);
    if (len <= 0 || (size_t)len >= sizeof path) return false; // deleted since
    path[len] = 0;
    const char *p = volume_relative(path);
    // In this folder, yet this scan did not come across it: do not rely on it.
    if (beneath(p, volume_relative(t->root_path))) return false;
    const char *rest = beneath(p, volume_relative(base->root_path));
    if (!rest) return false;

    const uint32_t *order = atomic_load_explicit(&base->order, memory_order_acquire);
    uint32_t node = 0;
    while (*rest == '/') {
        const char *name = rest + 1;
        size_t name_len = strcspn(name, "/");
        const Node *dir = &base->nodes[node];
        uint32_t cc = atomic_load_explicit(&dir->child_count, memory_order_relaxed);
        if ((t->lookup_budget -= cc) < 0) return true;
        uint32_t found = DM_NONE;
        for (uint32_t i = 0; i < cc && found == DM_NONE; i++) {
            uint32_t c = order[dir->first_child + i];
            const Node *nd = &base->nodes[c];
            if (nd->name_len == name_len && memcmp(base->names + nd->name_off, name, name_len) == 0)
                found = c;
        }
        if (found == DM_NONE) return false; // not there when the full scan ran
        node = found;
        rest = name + name_len;
    }
    return node != 0;
}

static bool counted_in_base(dm_tree *t, uint32_t dev, uint64_t clone_id) {
    const Owner *o = owner_find(&t->base->families, dev, clone_id);
    if (o && counted_outside(t->base, o->node, t->base_node)) return true;
    return original_in_base(t, dev, clone_id);
}

// Clones of one file share their blocks, so adding each one up in full counts
// the same data many times over. Each family is counted once: on the file it
// was cloned from if that was scanned, otherwise on its oldest clone. When
// rescanning one folder, a family already counted in the rest of the full
// scan is not counted here at all.
static void resolve_clones(dm_tree *t) {
    size_t count = t->clones_len;
    Clone *clones = t->clones;
    if (count == 0) {
        free_clone_data(t);
        return;
    }
    qsort(clones, count, sizeof(Clone), cmp_clones);

    // Which families have their original in the scan?
    size_t cap = 1024;
    while (cap < count * 2) cap *= 2;
    uint64_t *keys = calloc(cap, sizeof(uint64_t)); // 0 = empty; ids are never 0
    _Atomic uint8_t *present = calloc(cap, 1);
    for (size_t i = 0; i < count; i++) {
        if (i > 0 && clones[i].dev == clones[i - 1].dev && clones[i].clone_id == clones[i - 1].clone_id)
            continue;
        uint64_t key = id_key(clones[i].dev, clones[i].clone_id);
        size_t j = hl_hash(key, 0) & (cap - 1);
        while (keys[j] && keys[j] != key) j = (j + 1) & (cap - 1);
        keys[j] = key;
    }
    dispatch_apply((size_t)t->id_lists_len, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t l) {
        const uint64_t *ids = t->id_lists[l];
        for (size_t i = 0, n = t->id_lens[l]; i < n; i++) {
            size_t j = hl_hash(ids[i], 0) & (cap - 1);
            while (keys[j]) {
                if (keys[j] == ids[i]) {
                    atomic_store_explicit(&present[j], 1, memory_order_relaxed);
                    break;
                }
                j = (j + 1) & (cap - 1);
            }
        }
    });

    uint64_t files = 0, bytes = 0;
    bool family_has_owner = false;
    for (size_t i = 0; i < count; i++) {
        const Clone *c = &clones[i];
        if (i == 0 || c->dev != clones[i - 1].dev || c->clone_id != clones[i - 1].clone_id) {
            uint64_t key = id_key(c->dev, c->clone_id);
            size_t j = hl_hash(key, 0) & (cap - 1);
            while (keys[j] != key) j = (j + 1) & (cap - 1);
            family_has_owner = atomic_load_explicit(&present[j], memory_order_relaxed);
            if (!family_has_owner) {
                family_has_owner = true;
                if (!t->base || !counted_in_base(t, c->dev, c->clone_id)) {
                    bool added;
                    owner_get(&t->families, c->dev, c->clone_id, &added)->node = c->node;
                    continue; // this one keeps its full size
                }
            }
        }
        Node *nd = &t->nodes[c->node];
        uint64_t size = atomic_load_explicit(&nd->size, memory_order_relaxed);
        // A clone that was changed afterwards owns the changed part. Finding
        // out is slow, so only ask where the answer could matter.
        uint64_t own = 0;
        if (size >= CLONE_VERIFY_MIN) {
            own = private_size(t, c->node);
            if (own >= size) continue; // nothing shared after all (or unknown)
        }
        uint64_t shared = size - own;
        atomic_fetch_or_explicit(&nd->flags, DM_F_CLONE, memory_order_relaxed);
        nd->cut = shared / 512 > UINT32_MAX ? UINT32_MAX : (uint32_t)(shared / 512);
        for (uint32_t n = c->node; n != DM_NONE; n = t->nodes[n].parent)
            atomic_fetch_sub_explicit(&t->nodes[n].size, shared, memory_order_relaxed);
        files++;
        bytes += shared;
    }
    atomic_store(&t->clone_files, files);
    atomic_store(&t->clone_bytes, bytes);
    free(keys);
    free(present);
    free_clone_data(t);
}

static void finalize(dm_tree *t) {
    resolve_clones(t);
    uint32_t n = atomic_load(&t->count);
    uint32_t *order = t->order_map;
    for (uint32_t i = 0; i < n; i++) order[i] = i;

    const size_t chunk = 16384;
    size_t chunks = (n + chunk - 1) / chunk;
    dispatch_apply(chunks, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t c) {
        size_t end = (c + 1) * chunk < n ? (c + 1) * chunk : n;
        for (size_t i = c * chunk; i < end; i++) {
            const Node *d = &t->nodes[i];
            uint32_t cc = atomic_load_explicit(&d->child_count, memory_order_relaxed);
            if (cc > 1) dm_sort_children(t, order + d->first_child, cc);
        }
    });

    // Children always have higher indexes than their parent, so one backwards
    // pass sees every child before its directory.
    for (uint32_t i = n; i-- > 0;) {
        Node *d = &t->nodes[i];
        if (!(atomic_load_explicit(&d->flags, memory_order_relaxed) & DM_F_DIR)) continue;
        uint32_t cc = atomic_load_explicit(&d->child_count, memory_order_relaxed);
        d->kind = cc ? t->nodes[order[d->first_child]].kind : DM_KIND_OTHER;
    }
    atomic_store(&t->order, order);
}

// What the scan-wide counters hold for `node` and everything beneath it.
typedef struct {
    uint64_t dirs, dupes, clone_files, clone_bytes;
} Counts;

static void subtree_counts(const dm_tree *t, uint32_t node, Counts *out) {
    const uint32_t *order = atomic_load_explicit(&t->order, memory_order_acquire);
    size_t cap = 4096, len = 0;
    uint32_t *stack = malloc(cap * sizeof(uint32_t));
    stack[len++] = node;
    while (len) {
        const Node *n = &t->nodes[stack[--len]];
        uint8_t flags = atomic_load_explicit(&n->flags, memory_order_relaxed);
        if (flags & DM_F_REMOVED) continue;
        if (flags & DM_F_HARDLINK) out->dupes++;
        if (flags & DM_F_CLONE) {
            out->clone_files++;
            out->clone_bytes += (uint64_t)n->cut * 512;
        }
        if (!(flags & DM_F_DIR)) continue;
        out->dirs++;
        uint32_t cc = atomic_load_explicit(&n->child_count, memory_order_relaxed);
        if (len + cc > cap) {
            cap = (len + cc) * 2;
            stack = realloc(stack, cap * sizeof(uint32_t));
        }
        for (uint32_t i = 0; i < cc; i++) stack[len++] = order[n->first_child + i];
    }
    free(stack);
}

static void *finisher_main(void *arg) {
    dm_tree *t = arg;
    for (int i = 0; i < t->nthreads; i++) pthread_join(t->threads[i], NULL);
    // Anything still queued (after a cancel) is dropped.
    for (size_t i = 0; i < t->qlen; i++) free(t->queue[i].path);
    t->qlen = 0;
    atomic_store(&t->state, DM_STATE_FINALIZING);
    finalize(t);
    resolve_links(t);
    if (t->base) {
        Counts old = {0};
        subtree_counts(t->base, t->base_node, &old);
        t->old_dirs = old.dirs - 1; // the folder itself stays
        t->old_dupes = old.dupes;
        t->old_clone_files = old.clone_files;
        t->old_clone_bytes = old.clone_bytes;
    }
    atomic_store(&t->t_end, mach_absolute_time());
    atomic_store(&t->state, DM_STATE_DONE);
    return NULL;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

static void *reserve(size_t *bytes) {
    for (;;) {
        void *p = mmap(NULL, *bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (p != MAP_FAILED) return p;
        if (*bytes < ((size_t)64 << 20)) return NULL;
        *bytes /= 2;
    }
}

// Starts a scan of `resolved`, a directory. With `base`, it is a rescan of
// the folder at `base_node` of that tree.
static dm_tree *scan_begin(const char *resolved, const struct stat *root_st, int threads,
                           dm_tree *base, uint32_t base_node) {
    pthread_once(&g_ext_once, ext_init);
    struct stat st = *root_st;

    dm_tree *t = calloc(1, sizeof *t);
    size_t node_bytes = MAX_NODES * sizeof(Node);
    t->nodes = reserve(&node_bytes);
    size_t name_bytes = MAX_NAME_BYTES;
    t->names = reserve(&name_bytes);
    size_t order_bytes = t->nodes ? node_bytes / sizeof(Node) * sizeof(uint32_t) : 0;
    t->order_map = order_bytes ? reserve(&order_bytes) : NULL;
    if (!t->nodes || !t->names || !t->order_map) {
        if (t->nodes) munmap(t->nodes, node_bytes);
        if (t->names) munmap(t->names, name_bytes);
        if (t->order_map) munmap(t->order_map, order_bytes);
        free(t);
        return NULL;
    }
    t->nodes_bytes = node_bytes;
    t->names_bytes = name_bytes;
    t->order_bytes = order_bytes;
    t->cap = node_bytes / sizeof(Node);
    if (t->cap > order_bytes / sizeof(uint32_t)) t->cap = order_bytes / sizeof(uint32_t);
    t->names_cap = name_bytes;
    t->root_path = strdup(resolved);
    t->root_dev = (uint32_t)st.st_dev;
    t->base = base;
    t->base_node = base_node;
    t->base_version = base ? base->version : 0;
    t->lookup_budget = LOOKUP_BUDGET;
    pthread_mutex_init(&t->mu, NULL);
    pthread_mutex_init(&t->hl_mu, NULL);
    pthread_cond_init(&t->cv, NULL);
    pthread_rwlock_init(&t->rw, NULL);

    // Node 0: the root. Its name is the full path.
    size_t root_len = strlen(resolved);
    Node *root = &t->nodes[0];
    root->parent = DM_NONE;
    root->name_off = 0;
    root->name_len = (uint16_t)(root_len > UINT16_MAX ? UINT16_MAX : root_len);
    atomic_store(&root->flags, DM_F_DIR);
    memcpy(t->names, resolved, root_len + 1);
    t->names_len = root_len + 1;
    atomic_store(&t->count, 1);
    atomic_store(&t->dirs, 1);

    t->qcap = 1024;
    t->queue = malloc(t->qcap * sizeof(Task));
    t->queue[0] = (Task){strdup(resolved), (uint32_t)root_len, 0, (uint32_t)st.st_dev, UINT32_MAX};

    struct statfs sfs;
    struct stat sys;
    bool mounted = statfs(resolved, &sfs) == 0;
    if (mounted) t->root_fsid = sfs.f_fsid;
    t->fast_apfs = mounted && strcmp(sfs.f_fstypename, "apfs") == 0 &&
                   stat("/", &sys) == 0 && sys.st_dev != st.st_dev;
    t->qlen = 1;

    if (threads <= 0) {
        int ncpu = 8;
        size_t sz = sizeof ncpu;
        // Performance cores only; efficiency cores mostly add lock contention.
        if (sysctlbyname("hw.perflevel0.logicalcpu", &ncpu, &sz, NULL, 0) != 0 || ncpu <= 0) {
            sz = sizeof ncpu;
            if (sysctlbyname("hw.ncpu", &ncpu, &sz, NULL, 0) != 0) ncpu = 8;
        }
        threads = ncpu < 2 ? 2 : (ncpu > 16 ? 16 : ncpu);
    }
    t->nthreads = threads;
    t->threads = calloc((size_t)threads, sizeof(pthread_t));
    t->t_start = mach_absolute_time();
    for (int i = 0; i < threads; i++) pthread_create(&t->threads[i], NULL, worker_main, t);
    pthread_create(&t->finisher, NULL, finisher_main, t);
    return t;
}

dm_tree *dm_scan_start(const char *root_path, int threads) {
    char resolved[PATH_MAX];
    if (!realpath(root_path, resolved)) return NULL;
    struct stat st;
    if (stat(resolved, &st) != 0 || !S_ISDIR(st.st_mode)) return NULL;
    return scan_begin(resolved, &st, threads, NULL, 0);
}

dm_tree *dm_rescan_start(dm_tree *t, uint32_t node, int threads) {
    if (!t || atomic_load(&t->state) != DM_STATE_DONE) return NULL;
    if (node == 0 || !dm_node_alive(t, node)) return NULL;
    uint8_t flags = atomic_load(&t->nodes[node].flags);
    if (!(flags & DM_F_DIR) || (flags & (DM_F_MOUNT | DM_F_DATALESS))) return NULL;
    char path[PATH_MAX];
    size_t len = dm_node_path(t, node, path, sizeof path);
    if (len == 0 || len >= sizeof path) return NULL;
    struct stat st;
    // Still a folder, and not one another volume was mounted on since (the
    // root of a volume has inode 2): that volume is not part of this scan.
    if (lstat(path, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_ino == 2) return NULL;
    return scan_begin(path, &st, threads, t, node);
}

void dm_scan_cancel(dm_tree *t) {
    atomic_store(&t->cancel, 1);
    pthread_mutex_lock(&t->mu);
    pthread_cond_broadcast(&t->cv);
    pthread_mutex_unlock(&t->mu);
}

void dm_scan_wait(dm_tree *t) {
    if (!t->joined) {
        pthread_join(t->finisher, NULL);
        t->joined = true;
    }
}

void dm_tree_free(dm_tree *t) {
    if (!t) return;
    dm_scan_cancel(t);
    dm_scan_wait(t);
    munmap(t->nodes, t->nodes_bytes);
    munmap(t->names, t->names_bytes);
    munmap(t->order_map, t->order_bytes);
    free(t->links.slots);
    free(t->families.slots);
    free(t->queue);
    free(t->threads);
    free(t->denied);
    free_clone_data(t);
    free(t->root_path);
    pthread_mutex_destroy(&t->mu);
    pthread_mutex_destroy(&t->hl_mu);
    pthread_cond_destroy(&t->cv);
    pthread_rwlock_destroy(&t->rw);
    free(t);
}

void dm_progress_get(const dm_tree *t, dm_progress *out) {
    out->files = atomic_load_explicit(&t->nodes[0].file_count, memory_order_relaxed);
    out->bytes = atomic_load_explicit(&t->nodes[0].size, memory_order_relaxed);
    out->dirs = atomic_load(&t->dirs);
    out->denied = atomic_load(&t->denied_count);
    out->errors = atomic_load(&t->errors);
    out->hardlink_dupes = atomic_load(&t->hl_dupes);
    out->clone_files = atomic_load(&t->clone_files);
    out->clone_bytes = atomic_load(&t->clone_bytes);
    out->nodes = atomic_load(&t->count);
    out->state = atomic_load(&t->state);
    out->cancelled = atomic_load(&t->cancel) != 0;
    uint64_t end = atomic_load(&t->t_end);
    out->elapsed = seconds_between(t->t_start, end ? end : mach_absolute_time());
}

const char *dm_root_path(const dm_tree *t) { return t->root_path; }

void dm_node_get(const dm_tree *t, uint32_t node, dm_node_info *out) {
    const Node *n = &t->nodes[node];
    out->size = atomic_load_explicit(&n->size, memory_order_relaxed);
    out->parent = n->parent;
    out->child_count = atomic_load_explicit(&n->child_count, memory_order_acquire);
    out->file_count = atomic_load_explicit(&n->file_count, memory_order_relaxed);
    out->name_len = n->name_len;
    out->kind = n->kind;
    out->flags = atomic_load_explicit(&n->flags, memory_order_relaxed);
    out->name = t->names + n->name_off;
}

uint32_t dm_child_at(const dm_tree *t, uint32_t dir, uint32_t i) {
    const Node *d = &t->nodes[dir];
    const uint32_t *order = atomic_load_explicit(&t->order, memory_order_acquire);
    return order ? order[d->first_child + i] : d->first_child + i;
}

size_t dm_node_path(const dm_tree *t, uint32_t node, char *buf, size_t cap) {
    uint32_t chain[1024];
    size_t depth = 0;
    for (uint32_t n = node; n != DM_NONE && depth < 1024; n = t->nodes[n].parent) chain[depth++] = n;
    size_t len = 0;
    for (size_t i = depth; i-- > 0;) {
        const Node *n = &t->nodes[chain[i]];
        bool is_root = n->parent == DM_NONE;
        // The root's name is its full path; "/" needs no extra separator.
        if (!is_root && !(len == 1 && buf[0] == '/')) {
            if (len + 1 < cap) buf[len] = '/';
            len++;
        }
        for (size_t k = 0; k < n->name_len; k++, len++)
            if (len + 1 < cap) buf[len] = t->names[n->name_off + k];
    }
    if (cap) buf[len < cap ? len : cap - 1] = 0;
    return len;
}

bool dm_is_within(const dm_tree *t, uint32_t node, uint32_t ancestor) {
    for (uint32_t n = node; n != DM_NONE; n = t->nodes[n].parent)
        if (n == ancestor) return true;
    return false;
}

bool dm_node_alive(const dm_tree *t, uint32_t node) {
    if (node >= atomic_load(&t->count)) return false;
    for (uint32_t n = node; n != DM_NONE; n = t->nodes[n].parent)
        if (atomic_load_explicit(&t->nodes[n].flags, memory_order_relaxed) & DM_F_REMOVED)
            return false;
    return true;
}

static void counter_adjust(_Atomic uint64_t *counter, uint64_t add, uint64_t sub) {
    uint64_t v = atomic_load(counter) + add;
    atomic_store(counter, v > sub ? v - sub : 0);
}

// Drops the unreadable folders that are gone, and `also` (DM_NONE for none).
static void prune_denied(dm_tree *t, uint32_t also) {
    size_t kept = 0;
    for (size_t i = 0; i < t->denied_len; i++)
        if (t->denied[i] != also && dm_node_alive(t, t->denied[i])) t->denied[kept++] = t->denied[i];
    t->denied_len = kept;
    atomic_store(&t->denied_count, kept);
}

void dm_remove_node(dm_tree *t, uint32_t node) {
    uint32_t *order = atomic_load(&t->order);
    if (!order || node == 0) return;
    Node *nd = &t->nodes[node];
    uint8_t flags = atomic_load(&nd->flags);
    if (flags & DM_F_REMOVED) return;
    uint64_t size = atomic_load(&nd->size);
    uint32_t files = (flags & DM_F_DIR) ? atomic_load(&nd->file_count) : 1;
    Counts gone = {0};
    subtree_counts(t, node, &gone);

    pthread_rwlock_wrlock(&t->rw);
    atomic_fetch_or(&nd->flags, DM_F_REMOVED);
    atomic_store(&nd->size, 0);
    for (uint32_t n = nd->parent; n != DM_NONE; n = t->nodes[n].parent) {
        atomic_fetch_sub(&t->nodes[n].size, size);
        atomic_fetch_sub(&t->nodes[n].file_count, files);
    }
    // The removed node sorts last in its parent's list and is then cut off;
    // every ancestor shrank, so its position among its siblings may change.
    bool first = true;
    for (uint32_t n = node; t->nodes[n].parent != DM_NONE; n = t->nodes[n].parent) {
        Node *p = &t->nodes[t->nodes[n].parent];
        uint32_t cc = atomic_load(&p->child_count);
        dm_sort_children(t, order + p->first_child, cc);
        if (first) {
            atomic_store(&p->child_count, cc - 1);
            first = false;
        }
    }
    counter_adjust(&t->dirs, 0, gone.dirs);
    counter_adjust(&t->hl_dupes, 0, gone.dupes);
    counter_adjust(&t->clone_files, 0, gone.clone_files);
    counter_adjust(&t->clone_bytes, 0, gone.clone_bytes);
    prune_denied(t, DM_NONE);
    t->version++;
    pthread_rwlock_unlock(&t->rw);
}

bool dm_rescan_apply(dm_tree *t, dm_tree *r) {
    if (!t || !r || r->base != t || r->applied) return false;
    if (atomic_load(&r->state) != DM_STATE_DONE || atomic_load(&r->cancel)) return false;
    uint32_t node = r->base_node;
    if (r->base_version != t->version || !dm_node_alive(t, node)) return false;
    uint32_t n = atomic_load(&r->count), base = atomic_load(&t->count);
    if ((size_t)base + n - 1 > t->cap || t->names_len + r->names_len > t->names_cap) return false;
    uint32_t *order = atomic_load(&t->order);
    const uint32_t *new_order = atomic_load(&r->order);
    // The rescan's node 0 is the folder itself; its node i becomes i + shift.
    // The copy keeps both properties the tree relies on: the children of a
    // directory are contiguous and come after it.
    uint32_t shift = base - 1;

    pthread_rwlock_wrlock(&t->rw);
    Node *folder = &t->nodes[node];
    const Node *root = &r->nodes[0];

    // What the folder held is left where it is (the tree only grows) and
    // marked as gone, so anyone still holding one of those ids can tell.
    uint32_t old_children = atomic_load(&folder->child_count);
    for (uint32_t i = 0; i < old_children; i++)
        atomic_fetch_or(&t->nodes[order[folder->first_child + i]].flags, DM_F_REMOVED);

    uint32_t names_base = (uint32_t)t->names_len;
    memcpy(t->names + t->names_len, r->names, r->names_len);
    t->names_len += r->names_len;
    for (uint32_t i = 1; i < n; i++) {
        Node *nd = &t->nodes[i + shift];
        memcpy(nd, &r->nodes[i], sizeof *nd);
        nd->parent = nd->parent == 0 ? node : nd->parent + shift;
        nd->name_off += names_base;
        if ((atomic_load_explicit(&nd->flags, memory_order_relaxed) & DM_F_DIR) &&
            atomic_load_explicit(&nd->child_count, memory_order_relaxed) > 0)
            nd->first_child += shift;
        order[i + shift] = new_order[i] + shift;
    }
    atomic_store_explicit(&t->count, base + n - 1, memory_order_release);

    uint32_t children = atomic_load(&root->child_count);
    atomic_store(&folder->child_count, 0);
    folder->first_child = children ? root->first_child + shift : 0;
    atomic_store(&folder->child_count, children);
    folder->kind = root->kind;
    if (atomic_load(&root->flags) & DM_F_UNREADABLE) atomic_fetch_or(&folder->flags, DM_F_UNREADABLE);
    else atomic_fetch_and(&folder->flags, (uint8_t)~DM_F_UNREADABLE);

    // New totals for the folder and everything above it; unsigned wrap-around
    // makes the same addition work when the folder shrank.
    uint64_t size_delta = atomic_load(&root->size) - atomic_load(&folder->size);
    uint32_t files_delta = atomic_load(&root->file_count) - atomic_load(&folder->file_count);
    for (uint32_t a = node; a != DM_NONE; a = t->nodes[a].parent) {
        atomic_fetch_add(&t->nodes[a].size, size_delta);
        atomic_fetch_add(&t->nodes[a].file_count, files_delta);
    }
    for (uint32_t a = node; t->nodes[a].parent != DM_NONE; a = t->nodes[a].parent) {
        Node *p = &t->nodes[t->nodes[a].parent];
        uint32_t cc = atomic_load(&p->child_count);
        dm_sort_children(t, order + p->first_child, cc);
        p->kind = cc ? t->nodes[order[p->first_child]].kind : DM_KIND_OTHER;
    }

    counter_adjust(&t->dirs, atomic_load(&r->dirs) - 1, r->old_dirs);
    counter_adjust(&t->hl_dupes, atomic_load(&r->hl_dupes), r->old_dupes);
    counter_adjust(&t->clone_files, atomic_load(&r->clone_files), r->old_clone_files);
    counter_adjust(&t->clone_bytes, atomic_load(&r->clone_bytes), r->old_clone_bytes);
    atomic_fetch_add(&t->errors, atomic_load(&r->errors));

    prune_denied(t, node);
    if (t->denied_len + r->denied_len > t->denied_cap) {
        t->denied_cap = (t->denied_len + r->denied_len) * 2;
        t->denied = realloc(t->denied, t->denied_cap * sizeof(uint32_t));
    }
    for (size_t i = 0; i < r->denied_len; i++)
        t->denied[t->denied_len++] = r->denied[i] == 0 ? node : r->denied[i] + shift;
    atomic_store(&t->denied_count, t->denied_len);

    // From now on the links and clone families found in the folder are
    // counted on their new nodes. Entries for what the folder used to hold
    // point at nodes that are gone, which reads as "counted nowhere".
    const OwnerMap *from[2] = {&r->links, &r->families};
    OwnerMap *into[2] = {&t->links, &t->families};
    for (int m = 0; m < 2; m++) {
        for (size_t i = 0; i < from[m]->cap; i++) {
            const Owner *o = &from[m]->slots[i];
            if (!o->used || o->node == DM_NONE) continue;
            bool added;
            owner_get(into[m], o->dev, o->id, &added)->node = o->node + shift;
        }
    }
    t->version++;
    r->applied = true;
    pthread_rwlock_unlock(&t->rw);
    return true;
}

uint32_t dm_denied_count(const dm_tree *t) { return (uint32_t)atomic_load(&t->denied_count); }

uint32_t dm_denied_at(const dm_tree *t, uint32_t i) {
    return i < t->denied_len ? t->denied[i] : DM_NONE;
}

void dm_subtree_stats(const dm_tree *t, uint32_t node, uint64_t kind_bytes[DM_KIND_COUNT],
                      uint32_t *top, uint32_t top_cap, uint32_t *top_count) {
    memset(kind_bytes, 0, sizeof(uint64_t) * DM_KIND_COUNT);
    if (top_count) *top_count = 0;
    const uint32_t *order = atomic_load(&t->order);
    if (!order) return;
    pthread_rwlock_rdlock((pthread_rwlock_t *)&t->rw);

    // Min-heap of the largest files seen so far, keyed by size.
    uint64_t *heap_size = top_cap ? malloc(top_cap * sizeof(uint64_t)) : NULL;
    uint32_t heap_len = 0;

    size_t cap = 4096, len = 0;
    uint32_t *stack = malloc(cap * sizeof(uint32_t));
    stack[len++] = node;
    while (len) {
        uint32_t id = stack[--len];
        const Node *n = &t->nodes[id];
        uint8_t flags = atomic_load_explicit(&n->flags, memory_order_relaxed);
        if (flags & DM_F_REMOVED) continue;
        if (flags & DM_F_DIR) {
            uint32_t cc = atomic_load_explicit(&n->child_count, memory_order_relaxed);
            if (len + cc > cap) {
                cap = (len + cc) * 2;
                stack = realloc(stack, cap * sizeof(uint32_t));
            }
            for (uint32_t i = 0; i < cc; i++) {
                uint32_t c = order[n->first_child + i];
                // Skip empty files early; they contribute nothing.
                if (atomic_load_explicit(&t->nodes[c].size, memory_order_relaxed) == 0) break;
                stack[len++] = c;
            }
            continue;
        }
        uint64_t size = atomic_load_explicit(&n->size, memory_order_relaxed);
        kind_bytes[n->kind < DM_KIND_COUNT ? n->kind : 0] += size;
        if (!top_cap) continue;
        if (heap_len < top_cap) {
            uint32_t i = heap_len++;
            while (i > 0 && heap_size[(i - 1) / 2] > size) {
                heap_size[i] = heap_size[(i - 1) / 2];
                top[i] = top[(i - 1) / 2];
                i = (i - 1) / 2;
            }
            heap_size[i] = size;
            top[i] = id;
        } else if (size > heap_size[0]) {
            uint32_t i = 0;
            for (;;) {
                uint32_t l = 2 * i + 1, r = l + 1, m = i;
                uint64_t ms = size;
                if (l < heap_len && heap_size[l] < ms) { m = l; ms = heap_size[l]; }
                if (r < heap_len && heap_size[r] < ms) { m = r; }
                if (m == i) break;
                heap_size[i] = heap_size[m];
                top[i] = top[m];
                i = m;
            }
            heap_size[i] = size;
            top[i] = id;
        }
    }
    free(stack);
    pthread_rwlock_unlock((pthread_rwlock_t *)&t->rw);

    // Heap -> descending order (simple selection; top_cap is small).
    for (uint32_t i = 0; i < heap_len; i++) {
        uint32_t best = i;
        for (uint32_t j = i + 1; j < heap_len; j++)
            if (heap_size[j] > heap_size[best]) best = j;
        uint64_t ts = heap_size[i]; heap_size[i] = heap_size[best]; heap_size[best] = ts;
        uint32_t tn = top[i]; top[i] = top[best]; top[best] = tn;
    }
    if (top_count) *top_count = heap_len;
    free(heap_size);
}

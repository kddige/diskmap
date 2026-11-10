// dmscan: headless scanner. Prints the largest directories as a tree.
//
//   dmscan [path] [--depth N] [--top N] [--min-gb X] [--threads N] [--files N]

#include "CScan.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void human(uint64_t bytes, char *out, size_t cap) {
    const char *units[] = {"B", "KB", "MB", "GB", "TB"};
    double v = (double)bytes;
    int u = 0;
    while (v >= 1000 && u < 4) {
        v /= 1000;
        u++;
    }
    snprintf(out, cap, u == 0 ? "%.0f %s" : (v < 10 ? "%.2f %s" : (v < 100 ? "%.1f %s" : "%.0f %s")), v, units[u]);
}

static void print_tree(const dm_tree *t, uint32_t node, int depth, int max_depth, int top,
                       uint64_t min_bytes) {
    dm_node_info info;
    dm_node_get(t, node, &info);
    char size[32];
    human(info.size, size, sizeof size);
    const char *note = "";
    if (info.flags & DM_F_UNREADABLE) note = "  [no permission]";
    else if (info.flags & DM_F_MOUNT) note = "  [other volume, skipped]";
    else if (info.flags & DM_F_DATALESS) note = "  [cloud-only, skipped]";
    printf("%10s  %*s%s%s%s\n", size, depth * 2, "", info.name,
           (info.flags & DM_F_DIR) && depth > 0 ? "/" : "", note);
    if (!(info.flags & DM_F_DIR) || depth >= max_depth) return;
    uint32_t shown = 0;
    for (uint32_t i = 0; i < info.child_count && shown < (uint32_t)top; i++) {
        uint32_t c = dm_child_at(t, node, i);
        dm_node_info ci;
        dm_node_get(t, c, &ci);
        if (ci.size < min_bytes) break;
        print_tree(t, c, depth + 1, max_depth, top, min_bytes);
        shown++;
    }
}

int main(int argc, char **argv) {
    const char *path = ".";
    int depth = 3, top = 12, threads = 0, files = 0;
    double min_gb = 0.5;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--depth") && i + 1 < argc) depth = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--top") && i + 1 < argc) top = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--threads") && i + 1 < argc) threads = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--min-gb") && i + 1 < argc) min_gb = atof(argv[++i]);
        else if (!strcmp(argv[i], "--files") && i + 1 < argc) files = atoi(argv[++i]);
        else if (argv[i][0] == '-') {
            fprintf(stderr, "usage: dmscan [path] [--depth N] [--top N] [--min-gb X] [--threads N] [--files N]\n");
            return 2;
        } else path = argv[i];
    }

    dm_tree *t = dm_scan_start(path, threads);
    if (!t) {
        fprintf(stderr, "dmscan: cannot scan %s\n", path);
        return 1;
    }
    dm_progress p;
    bool tty = isatty(STDERR_FILENO);
    for (;;) {
        dm_progress_get(t, &p);
        if (p.state == DM_STATE_DONE) break;
        if (tty) {
            char size[32];
            human(p.bytes, size, sizeof size);
            fprintf(stderr, "\r%llu files, %s, %.1fs   ", (unsigned long long)p.files, size, p.elapsed);
        }
        usleep(100000);
    }
    dm_scan_wait(t);
    dm_progress_get(t, &p);
    if (tty) fprintf(stderr, "\r                                              \r");

    char size[32];
    human(p.bytes, size, sizeof size);
    printf("%s in %llu files, %llu folders - scanned in %.2fs (%.0f items/s)\n", size,
           (unsigned long long)p.files, (unsigned long long)p.dirs, p.elapsed,
           (double)(p.files + p.dirs) / (p.elapsed > 0 ? p.elapsed : 1));
    if (p.denied) printf("%llu folders could not be read (no permission)\n", (unsigned long long)p.denied);
    if (p.errors) printf("%llu other errors\n", (unsigned long long)p.errors);
    if (p.hardlink_dupes) printf("%llu extra hard links counted once\n", (unsigned long long)p.hardlink_dupes);
    if (p.clone_files) {
        char shared[32];
        human(p.clone_bytes, shared, sizeof shared);
        printf("%llu clones share %s with other files (counted once)\n", (unsigned long long)p.clone_files, shared);
    }
    printf("\n");

    print_tree(t, 0, 0, depth, top, (uint64_t)(min_gb * 1e9));

    if (files > 0) {
        uint64_t kinds[DM_KIND_COUNT];
        uint32_t *topf = malloc(sizeof(uint32_t) * (size_t)files);
        uint32_t n = 0;
        dm_subtree_stats(t, 0, kinds, topf, (uint32_t)files, &n);
        printf("\nBy kind:\n");
        for (int k = 0; k < DM_KIND_COUNT; k++) {
            human(kinds[k], size, sizeof size);
            printf("%10s  %s\n", size, dm_kind_name(k));
        }
        printf("\nLargest files:\n");
        char buf[4096];
        for (uint32_t i = 0; i < n; i++) {
            dm_node_info info;
            dm_node_get(t, topf[i], &info);
            dm_node_path(t, topf[i], buf, sizeof buf);
            human(info.size, size, sizeof size);
            printf("%10s  %s\n", size, buf);
        }
        free(topf);
    }

    if (p.denied) {
        printf("\nNot readable:\n");
        char buf[4096];
        uint32_t n = dm_denied_count(t);
        for (uint32_t i = 0; i < n && i < 25; i++) {
            dm_node_path(t, dm_denied_at(t, i), buf, sizeof buf);
            printf("  %s\n", buf);
        }
        if (n > 25) printf("  ... and %u more\n", n - 25);
    }
    dm_tree_free(t);
    return 0;
}

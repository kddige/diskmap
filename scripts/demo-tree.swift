// Fills a folder with a made-up Mac: believable names and sizes, no content.
//
//   swift scripts/demo-tree.swift <empty folder> [total GB, default 60]
//
// Files are given their size by reserving blocks, not by writing data, so this
// takes a second or two. The space is really reserved until the files are
// deleted, so it refuses to run unless twice the total is free. Used by
// make-screenshot.sh.

import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: demo-tree.swift <empty folder> [total GB]\n".data(using: .utf8)!)
    exit(2)
}
let root = CommandLine.arguments[1]
let targetBytes = (CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 60 : 60) * 1e9

// The same tree every time.
var seed: UInt64 = 0x00D1_5CAB_1E5E_ED00
func random() -> Double {
    seed &+= 0x9E37_79B9_7F4A_7C15
    var z = seed
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z ^= z >> 31
    return Double(z >> 11) / Double(1 << 53)
}
/// Skewed towards the low end, like real file sizes.
func between(_ low: Double, _ high: Double) -> Double {
    let r = random()
    return low + (high - low) * r * r
}
func pick<T>(_ items: [T]) -> T { items[Int(random() * Double(items.count))] }
func hex(_ digits: Int) -> String {
    (0..<digits).map { _ in String(Int(random() * 16), radix: 16) }.joined()
}

/// The plan: every file and its relative weight. Sizes are settled at the end,
/// once the weights are known, so the tree adds up to the requested total.
var plan: [(path: String, weight: Double)] = []
func file(_ path: String, _ weight: Double) { plan.append((path, weight)) }

let home = "Users/alex"

// Movies
file("\(home)/Movies/Iceland 2025 - final cut.mov", 7400)
file("\(home)/Movies/Wedding film.mp4", 4100)
file("\(home)/Movies/Conference talk (raw).mkv", 1900)
for i in 1...14 { file("\(home)/Movies/Drone/DJI_\(String(format: "%04d", 212 + i)).MP4", between(120, 900)) }
for i in 1...7 {
    file("\(home)/Movies/Screen Recordings/Screen Recording 2026-0\(i)-1\(i) at 10.2\(i).mov", between(40, 700))
}

// Photos
let shelves = (0..<16).map { String($0, radix: 16).uppercased() }
for _ in 1...1500 {
    let name = hex(8).uppercased() + "-" + hex(4).uppercased()
    file("\(home)/Pictures/Photos Library.photoslibrary/originals/\(pick(shelves))/\(name).\(pick(["heic", "heic", "heic", "jpeg"]))",
         between(1.6, 9))
}
for _ in 1...36 {
    file("\(home)/Pictures/Photos Library.photoslibrary/originals/\(pick(shelves))/\(hex(8).uppercased()).mov", between(30, 260))
}
file("\(home)/Pictures/Photos Library.photoslibrary/database/Photos.sqlite", 310)
for i in 1...70 { file("\(home)/Pictures/RAW/2025-06 Lofoten/DSC0\(4100 + i).dng", between(31, 52)) }
for i in 1...45 { file("\(home)/Pictures/RAW/2026-02 Dolomites/DSC0\(6220 + i).dng", between(31, 52)) }

// Music
let artists = ["Boards of Canada", "Khruangbin", "Nils Frahm", "Bonobo", "Röyksopp", "Tycho", "Kiasmos", "Air",
               "Four Tet", "Caribou", "Jon Hopkins", "Ólafur Arnalds"]
let albums = ["Night Drive", "Low Tide", "Paper Maps", "Slow Light", "Field Notes", "North Shore", "Afterglow"]
for artist in artists {
    for album in albums where random() < 0.45 {
        for track in 1...Int(between(8, 14)) {
            file("\(home)/Music/Music/Media/\(artist)/\(album)/\(String(format: "%02d", track)) Track \(track).\(pick(["m4a", "m4a", "flac"]))",
                 between(7, 38))
        }
    }
}
for name in ["Demo v3", "Demo v4 (mix)", "Live set"] {
    for stem in ["Drums", "Bass", "Keys", "Vox"] { file("\(home)/Music/Logic/\(name)/Audio Files/\(stem).wav", between(60, 240)) }
}

// Documents
let subjects = ["Invoice", "Contract", "Report", "Scan", "Manual", "Statement", "Thesis draft", "Receipt", "Slides"]
for i in 1...170 {
    file("\(home)/Documents/\(pick(["Work", "Taxes", "Home", "Archive/2023", "Archive/2024"]))/\(pick(subjects)) \(1000 + i).pdf",
         between(0.2, 28))
}
for name in ["Q3 review", "Launch plan", "All-hands", "Workshop"] { file("\(home)/Documents/Work/\(name).key", between(90, 520)) }
for i in 1...24 { file("\(home)/Documents/Work/Budget \(2003 + i).xlsx", between(0.1, 6)) }
file("\(home)/Documents/Archive/Old laptop backup.zip", 2600)

// Downloads
file("\(home)/Downloads/ubuntu-26.04-desktop-arm64.iso", 5300)
file("\(home)/Downloads/Xcode_27.xip", 3900)
file("\(home)/Downloads/dataset-export-2026-08.tar.gz", 1700)
for name in ["Blender-4.5", "Figma", "OBS-31.2", "Docker", "Postgres-17", "VLC-3.0.21", "Zed", "Affinity-Photo"] {
    file("\(home)/Downloads/\(name).dmg", between(90, 900))
}
for i in 1...18 { file("\(home)/Downloads/export (\(i)).zip", between(2, 260)) }
for i in 1...30 { file("\(home)/Downloads/IMG_\(2040 + i).png", between(0.4, 9)) }

// Developer
let packages = ["react", "typescript", "esbuild", "vite", "lodash", "next", "zod", "prettier", "eslint", "rollup",
                "postcss", "tailwindcss", "sharp", "playwright-core", "webpack", "date-fns", "rxjs", "three"]
for project in ["storefront", "mobile-app", "design-system", "api-gateway", "notebooks"] {
    let base = "\(home)/Developer/\(project)"
    for package in packages where random() < 0.8 {
        for _ in 1...Int(between(6, 26)) { file("\(base)/node_modules/\(package)/dist/chunk-\(hex(6)).\(pick(["js", "js", "mjs", "d.ts", "map"]))", between(0.02, 1.8)) }
        if random() < 0.3 { file("\(base)/node_modules/\(package)/build/Release/\(package).node", between(6, 70)) }
    }
    for i in 1...40 { file("\(base)/src/\(pick(["components", "lib", "routes", "hooks"]))/module\(i).\(pick(["ts", "tsx", "css"]))", between(0.004, 0.06)) }
    file("\(base)/.git/objects/pack/pack-\(hex(40)).pack", between(40, 520))
}
for crate in ["engine", "renderer"] {
    for _ in 1...130 { file("\(home)/Developer/\(crate)/target/debug/deps/lib\(pick(packages).replacingOccurrences(of: "-", with: "_"))-\(hex(16)).\(pick(["rlib", "rlib", "rmeta", "o"]))", between(0.3, 34)) }
    for i in 1...30 { file("\(home)/Developer/\(crate)/src/part\(i).rs", between(0.004, 0.09)) }
}

// Library
file("\(home)/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", 9800)
file("\(home)/.ollama/models/blobs/qwen3-14b-q4_k_m.gguf", 6900)
file("\(home)/.ollama/models/blobs/nomic-embed-text-v2.gguf", 520)
file("\(home)/Library/Developer/CoreSimulator/Devices/\(hex(8).uppercased())/data/Containers/Shared/system.img", 2300)
for app in ["Slack", "Code", "Arc", "Spotify", "Notion", "Signal", "Linear", "Obsidian"] {
    for _ in 1...Int(between(5, 30)) {
        file("\(home)/Library/Application Support/\(app)/\(pick(["Cache", "IndexedDB", "Service Worker", "blob_storage"]))/\(hex(12)).\(pick(["db", "ldb", "sqlite", "bin", "dat"]))",
             between(0.5, 95))
    }
}
for cache in ["com.apple.Safari", "Homebrew", "pip", "com.spotify.client", "org.swift.swiftpm", "Yarn"] {
    for _ in 1...Int(between(10, 60)) { file("\(home)/Library/Caches/\(cache)/\(hex(2))/\(hex(20))", between(0.1, 40)) }
}
for _ in 1...160 { file("\(home)/Library/Messages/Attachments/\(hex(2))/\(hex(8)).\(pick(["heic", "jpeg", "mov", "pdf", "m4a"]))", between(0.3, 30)) }

// Applications
let apps: [(String, Double)] = [
    ("Xcode", 4200), ("Final Cut Pro", 2100), ("Logic Pro", 1500), ("Blender", 1100), ("Docker", 900),
    ("Figma", 520), ("Slack", 480), ("Arc", 610), ("Visual Studio Code", 560), ("Spotify", 300), ("Zed", 260),
    ("Keynote", 640), ("Pages", 520), ("Numbers", 500), ("Affinity Photo", 780), ("OBS", 420), ("VLC", 150),
    ("Signal", 380), ("Obsidian", 330), ("1Password", 410), ("Notion", 290), ("Raycast", 180),
]
for (app, megabytes) in apps {
    let base = "Applications/\(app).app/Contents"
    file("\(base)/MacOS/\(app)", megabytes * 0.12)
    let frameworks = Int(between(4, 16))
    for i in 1...frameworks {
        file("\(base)/Frameworks/lib\(pick(["core", "ui", "media", "sync", "render", "crypto", "net"]))\(i).dylib",
             megabytes * 0.55 / Double(frameworks) * between(0.4, 1.8))
    }
    file("\(base)/Resources/Assets.car", megabytes * 0.14)
    for i in 1...Int(between(8, 40)) {
        file("\(base)/Resources/\(pick(["en", "de", "fr", "ja", "Base"])).lproj/View\(i).\(pick(["nib", "strings", "png", "json"]))",
             megabytes * 0.19 / 24 * between(0.2, 2.2))
    }
}

// The rest of the system
file("private/var/vm/sleepimage", 2100)
file("private/var/db/uuidtext/dsc/\(hex(32).uppercased())", 610)
for i in 1...40 { file("private/var/log/system.log.\(i).gz", between(0.5, 22)) }
file("Library/Developer/CoreSimulator/Caches/dyld/27A266/dyld_sim_shared_cache_arm64", 1900)
for i in 1...22 { file("Library/Fonts/Family \(i).ttc", between(2, 45)) }
for name in ["Mojave", "Sonoma Horizon", "Tahoe Dawn", "Sequoia Sunrise"] { file("Library/Desktop Pictures/\(name).heic", between(20, 130)) }

// MARK: Create it

func freeBytes(at path: String) -> Double {
    var stats = statfs()
    guard statfs(path, &stats) == 0 else { return 0 }
    return Double(stats.f_bavail) * Double(stats.f_bsize)
}

try! FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
let free = freeBytes(at: root)
guard free >= targetBytes * 2 else {
    FileHandle.standardError.write(String(
        format: "demo-tree: %.0f GB free at %@, need %.0f GB (twice the %.0f GB total)\n",
        free / 1e9, root, targetBytes * 2 / 1e9, targetBytes / 1e9).data(using: .utf8)!)
    exit(1)
}

let bytesPerWeight = targetBytes / plan.reduce(0) { $0 + $1.weight }
var total: UInt64 = 0
var madeDirectories = Set<String>()
for (path, weight) in plan {
    let full = root + "/" + path
    let directory = (full as NSString).deletingLastPathComponent
    if madeDirectories.insert(directory).inserted {
        try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }
    let size = max(4096, off_t(weight * bytesPerWeight))
    let fd = open(full, O_CREAT | O_RDWR | O_TRUNC, 0o644)
    guard fd >= 0 else { fatalError("cannot create \(full)") }
    var store = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE,
                         fst_offset: 0, fst_length: size, fst_bytesalloc: 0)
    guard fcntl(fd, F_PREALLOCATE, &store) == 0 else { fatalError("out of space at \(full)") }
    ftruncate(fd, size)
    close(fd)
    total += UInt64(size)
}

print(String(format: "%d files, %.1f GB in %@", plan.count, Double(total) / 1e9, root))

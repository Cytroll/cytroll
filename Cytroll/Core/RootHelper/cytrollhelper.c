#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

/*
 * cytrollhelper — TrollStore root execution proxy (Sileo/Filza/Dopamine pattern)
 *
 * Security (rootless):
 *   - Allowlisted executables only
 *   - Blocks signed system volume (SSV) paths
 *   - Jailbreak state confined to /var/mobile/.lara_jb
 *   - Legacy /var/jb only as rm/mv/cp args during bootstrap relocate
 */

static int path_has_prefix(const char *path, const char *prefix) {
    size_t plen = strlen(prefix);
    if (strncmp(path, prefix, plen) != 0) return 0;
    if (path[plen] == '\0' || path[plen] == '/') return 1;
    return 0;
}

static int is_blocked_system_path(const char *path) {
    static const char *blocked[] = {
        "/System",
        "/private/preboot",
        NULL
    };

    for (int i = 0; blocked[i]; i++) {
        if (path_has_prefix(path, blocked[i])) return 1;
    }
    return 0;
}

static int contains_path_traversal(const char *path) {
    if (strstr(path, "/../") != NULL) return 1;
    size_t len = strlen(path);
    if (len >= 3 && strcmp(path + len - 3, "/..") == 0) return 1;
    return 0;
}

/*
 * Bundled tools (tar/zstd/ldid/cytrollhelper itself) live at
 * <AppBundle>/Binaries/<tool>. Only trust this when the bundle sits inside
 * the *installed, read-only* app container (Bundle/Application) — never
 * the Data container, which is writable at runtime and could be used to
 * smuggle in a malicious "fake.app/Binaries/evil" path.
 *
 * NOTE: these root prefixes are deliberately written WITHOUT a trailing
 * slash. path_has_prefix() already requires whatever follows the matched
 * prefix to be '/' or end-of-string — feeding it a prefix that itself
 * already ends in '/' makes that boundary check look for a character
 * right after that slash (e.g. the first digit of a UUID directory name),
 * which is never '/' or '\0' for any real path, so the prefix would never
 * match ANY actual file.
 */
static const char *kBundleApplicationRoots[] = {
    "/private/var/containers/Bundle/Application",
    "/var/containers/Bundle/Application",
    NULL
};

static int is_bundled_binary_path(const char *path) {
    if (contains_path_traversal(path)) return 0;

    for (int i = 0; kBundleApplicationRoots[i]; i++) {
        if (path_has_prefix(path, kBundleApplicationRoots[i]) && strstr(path, ".app/Binaries/") != NULL) {
            return 1;
        }
    }
    return 0;
}

/*
 * Per-app tweak injection targets (AppInjectionManager) live at
 * /private/var/containers/Bundle/Application/<UUID>/<Name>.app/...
 * This is intentionally broader than is_bundled_binary_path() above (which
 * only ever covers OUR OWN read-only Binaries/ folder as the *executable*
 * to run): here we allowlist *arguments* so cp/insert_dylib/ldid/chmod can
 * operate on files strictly inside a third-party app's .app bundle
 * (main executable, Frameworks/) for injection/backup/restore.
 *
 * Still structurally confined to real Bundle/Application paths that
 * contain an actual ".app/" component — a bare
 * "/private/var/containers/Bundle/Application/evil" with no ".app/" is
 * still rejected. Apple's own system apps and SpringBoard never live
 * under this path (they ship on the sealed, read-only system volume), so
 * they are excluded by construction, not by an extra name check.
 *
 * Three shapes of argument are allowed here, all strictly rooted under a
 * real Bundle/Application path:
 *   1. Anything *inside* a `.app` bundle (main executable, Frameworks/...).
 *   2. The bare `.app` bundle directory itself (whole-bundle cp/mv/rm —
 *      taking/restoring a full backup, or the atomic-swap rename).
 *   3. Cytroll's own sibling temp directories next to a bundle, named
 *      "<Name>.app.cytroll_<suffix>" (staged rebuild copy / renamed-aside
 *      original during AppInjectionManager's atomic swap) — never a path
 *      inside another app, always a sibling of the real bundle.
 */
static int is_third_party_app_bundle_path(const char *path) {
    if (contains_path_traversal(path)) return 0;

    for (int i = 0; kBundleApplicationRoots[i]; i++) {
        if (!path_has_prefix(path, kBundleApplicationRoots[i])) continue;

        if (strstr(path, ".app/") != NULL) return 1;

        size_t len = strlen(path);
        if (len >= 4 && strcmp(path + len - 4, ".app") == 0) return 1;

        if (strstr(path, ".app.cytroll_") != NULL) return 1;
    }
    return 0;
}

/*
 * App Manager uninstall: allow rm -rf of the install UUID directory
 *   /private/var/containers/Bundle/Application/<UUID>
 * Exactly one path component after the root (never the root itself).
 * Deeper .app paths are already covered by is_third_party_app_bundle_path().
 */
static int is_third_party_install_container_path(const char *path) {
    if (!path || contains_path_traversal(path)) return 0;

    for (int i = 0; kBundleApplicationRoots[i]; i++) {
        const char *root = kBundleApplicationRoots[i];
        size_t rlen = strlen(root);
        if (!path_has_prefix(path, root)) continue;
        if (path[rlen] != '/') continue;

        const char *rest = path + rlen + 1;
        if (rest[0] == '\0') return 0; /* bare Application/ — forbidden */

        /* Must be a single segment (the UUID), no further '/'. */
        if (strchr(rest, '/') != NULL) return 0;

        size_t ulen = strlen(rest);
        if (ulen < 8 || ulen > 64) return 0;
        return 1;
    }
    return 0;
}

static int is_lara_jb_path(const char *path) {
    return path_has_prefix(path, "/var/mobile/.lara_jb") ||
           path_has_prefix(path, "/private/var/mobile/.lara_jb");
}

static int is_mobile_path(const char *path) {
    return path_has_prefix(path, "/var/mobile") ||
           path_has_prefix(path, "/private/var/mobile");
}

/* Temporary Procursus unpack path — only for bootstrap relocate. */
static int is_legacy_jb_path(const char *path) {
    return path_has_prefix(path, "/var/jb") ||
           path_has_prefix(path, "/private/var/jb");
}

static int is_relocate_tool(const char *exe) {
    return strcmp(exe, "/bin/rm") == 0 ||
           strcmp(exe, "/bin/mv") == 0 ||
           strcmp(exe, "/bin/cp") == 0 ||
           strcmp(exe, "/usr/bin/rm") == 0 ||
           strcmp(exe, "/usr/bin/mv") == 0 ||
           strcmp(exe, "/usr/bin/cp") == 0;
}

static int is_allowed_executable(const char *path) {
    if (!path || path[0] != '/') return 0;
    if (is_blocked_system_path(path)) return 0;
    if (contains_path_traversal(path)) return 0;

    /* NOTE: deliberately WITHOUT a trailing slash — see the comment above
     * kBundleApplicationRoots for why a trailing slash here breaks
     * path_has_prefix()'s boundary check. */
    static const char *allowed_prefixes[] = {
        "/var/mobile/.lara_jb",
        "/private/var/mobile/.lara_jb",
        "/bin",
        "/usr/bin",
        NULL
    };

    for (int i = 0; allowed_prefixes[i]; i++) {
        if (path_has_prefix(path, allowed_prefixes[i]) ||
            strcmp(path, allowed_prefixes[i]) == 0) {
            return 1;
        }
    }

    return is_bundled_binary_path(path);
}

/* Returns 1 when the argument is unsafe (should be blocked). */
static int argument_targets_system(const char *exe, const char *arg) {
    if (!arg || arg[0] != '/') return 0;
    if (is_blocked_system_path(arg)) return 1;
    if (contains_path_traversal(arg)) return 1;

    /* Procursus bootstrap extracts via tar -C / */
    if (strcmp(arg, "/") == 0) return 0;

    /* Cytroll rootless prefix */
    if (is_lara_jb_path(arg)) return 0;

    /* /var/mobile (Data containers, vault, .lara_jb parent, etc.) */
    if (is_mobile_path(arg)) return 0;

    /* Bootstrap relocate: allow rm/mv/cp against temporary /var/jb only */
    if (is_relocate_tool(exe) && is_legacy_jb_path(arg)) return 0;

    /* Per-app tweak injection */
    if (is_third_party_app_bundle_path(arg)) return 0;

    /* App Manager uninstall of a third-party install UUID container. */
    if (is_third_party_install_container_path(arg)) return 0;

    /* Block remaining /var subtree */
    if (path_has_prefix(arg, "/var/")) return 1;
    if (path_has_prefix(arg, "/private/var/") &&
        !path_has_prefix(arg, "/private/var/tmp")) {
        return 1;
    }

    return 0;
}

static int validate_arguments(char *const args[]) {
    const char *exe = args[0];
    for (int i = 0; args[i] != NULL; i++) {
        if (argument_targets_system(exe, args[i])) {
            fprintf(stderr, "cytrollhelper: blocked unsafe path: %s\n", args[i]);
            return 0;
        }
    }
    return 1;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <executable> [args...]\n", argv[0]);
        return 1;
    }

    const char *target = argv[1];

    if (!is_allowed_executable(target)) {
        fprintf(stderr, "cytrollhelper: executable not allowlisted: %s\n", target);
        return 1;
    }

    if (!validate_arguments(&argv[1])) {
        return 1;
    }

    /* Best-effort privilege escalation, NOT a hard requirement.
     *
     * This only actually succeeds when the binary on disk is owned by
     * root with the setuid bit set (mode 4755) — which requires something
     * that already has root to set up (e.g. this package's own `postinst`
     * when installed via an existing rootless jailbreak's dpkg). The
     * primary TrollStore `.tipa` install path can never grant that: a
     * TrollStore app (and therefore this very file) is always owned by
     * `mobile`, and chown-to-root itself requires pre-existing root —
     * there is no legitimate way for an app to grant itself real root on
     * a device that isn't already jailbroken.
     *
     * That's fine: Cytroll keeps /var/mobile/.lara_jb owned by `mobile`
     * so an unsandboxed-but-unprivileged TrollStore process can manage it
     * without needing real root at all. So: try to escalate — it helps
     * on top of an existing jailbreak/manually-rooted setup — but fall
     * through and execv as whatever we already are if it doesn't take.
     * The allowlist checks above already apply regardless of the
     * resulting privilege level. */
    if (setgid(0) != 0 || setuid(0) != 0) {
        fprintf(stderr, "cytrollhelper: could not escalate to root — continuing as uid %d (fine for mobile-owned .lara_jb).\n", getuid());
    }

    execv(target, &argv[1]);
    perror("cytrollhelper: execv failed");
    return 1;
}

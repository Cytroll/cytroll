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
 *   - Jailbreak state confined to /var/jb
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
 * match ANY actual file. (Contrast with the "/var/jb" prefix a few lines
 * up, which has no trailing slash and works correctly for exactly this
 * reason — that inconsistency was the bug.)
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
 */
static int is_third_party_install_container_path(const char *path) {
    if (!path || contains_path_traversal(path)) return 0;

    for (int i = 0; kBundleApplicationRoots[i]; i++) {
        const char *root = kBundleApplicationRoots[i];
        size_t rlen = strlen(root);
        if (!path_has_prefix(path, root)) continue;
        if (path[rlen] != '/') continue;

        const char *rest = path + rlen + 1;
        if (rest[0] == '\0') return 0;

        if (strchr(rest, '/') != NULL) return 0;

        size_t ulen = strlen(rest);
        if (ulen < 8 || ulen > 64) return 0;
        return 1;
    }
    return 0;
}

static int is_allowed_executable(const char *path) {
    if (!path || path[0] != '/') return 0;
    if (is_blocked_system_path(path)) return 0;
    if (contains_path_traversal(path)) return 0;

    /* NOTE: deliberately WITHOUT a trailing slash — see the comment above
     * kBundleApplicationRoots for why a trailing slash here breaks
     * path_has_prefix()'s boundary check. */
    static const char *allowed_prefixes[] = {
        "/var/jb",
        "/private/var/jb",
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

static int argument_targets_system(const char *arg) {
    if (!arg || arg[0] != '/') return 0;
    if (is_blocked_system_path(arg)) return 1;
    if (contains_path_traversal(arg)) return 1;

    /* Procursus bootstrap extracts var/jb/ tree via tar -C / */
    if (strcmp(arg, "/") == 0) return 0;

    /* Per-app tweak injection */
    if (is_third_party_app_bundle_path(arg)) return 0;

    /* App Manager uninstall of a third-party install UUID container. */
    if (is_third_party_install_container_path(arg)) return 0;

    /* Block /var subtree outside /var/jb; allow mobile for vault/data ops */
    if (path_has_prefix(arg, "/var/") &&
        !path_has_prefix(arg, "/var/jb") &&
        !path_has_prefix(arg, "/var/mobile")) {
        return 1;
    }
    if (path_has_prefix(arg, "/private/var/") &&
        !path_has_prefix(arg, "/private/var/jb") &&
        !path_has_prefix(arg, "/private/var/mobile") &&
        !path_has_prefix(arg, "/private/var/tmp")) {
        return 1;
    }

    return 0;
}

static int validate_arguments(char *const args[]) {
    for (int i = 0; args[i] != NULL; i++) {
        if (argument_targets_system(args[i])) {
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
     * That's fine: standard rootless convention keeps /var/jb (and
     * everything under it) owned by `mobile` specifically so an
     * unsandboxed-but-unprivileged TrollStore process can manage it
     * without needing real root at all. */
    if (setgid(0) != 0 || setuid(0) != 0) {
        fprintf(stderr, "cytrollhelper: could not escalate to root — continuing as uid %d (fine for mobile-owned /var/jb).\n", getuid());
    }

    execv(target, &argv[1]);
    perror("cytrollhelper: execv failed");
    return 1;
}

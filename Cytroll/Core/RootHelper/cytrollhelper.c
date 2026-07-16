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

static int is_allowed_executable(const char *path) {
    if (!path || path[0] != '/') return 0;
    if (is_blocked_system_path(path)) return 0;
    if (contains_path_traversal(path)) return 0;

    /* NOTE: deliberately WITHOUT a trailing slash — see the comment above
     * kBundleApplicationRoots for why a trailing slash here breaks
     * path_has_prefix()'s boundary check. This exact bug (present here
     * until now) meant bare "/bin/rm", "/bin/mv", "/bin/cp", "/bin/mkdir"
     * and "/usr/bin/..." targets were silently rejected as "not
     * allowlisted" — breaking bootstrap removal, the entire per-app
     * injection pipeline, tweak enable/disable, and backup cleanup, all
     * of which invoke these via CytrollCoreBridge as bare executable
     * paths (not under /var/jb). */
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

    /* Per-app tweak injection: allow cp/insert_dylib/ldid/chmod to touch
     * paths strictly inside a third-party app's .app bundle. See
     * is_third_party_app_bundle_path() for the exact structural rule. */
    if (is_third_party_app_bundle_path(arg)) return 0;

    /* Block /var/* outside /var/jb */
    if (path_has_prefix(arg, "/var/") && !path_has_prefix(arg, "/var/jb")) return 1;
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
     * That's fine: standard rootless convention keeps /var/jb (and
     * everything under it) owned by `mobile` specifically so an
     * unsandboxed-but-unprivileged TrollStore process can manage it
     * without needing real root at all. So: try to escalate — it helps
     * on top of an existing jailbreak/manually-rooted setup — but fall
     * through and execv as whatever we already are if it doesn't take.
     * The allowlist checks above already apply regardless of the
     * resulting privilege level. */
    if (setgid(0) != 0 || setuid(0) != 0) {
        fprintf(stderr, "cytrollhelper: could not escalate to root — continuing as uid %d (fine for mobile-owned /var/jb).\n", getuid());
    }

    execv(target, &argv[1]);
    perror("cytrollhelper: execv failed");
    return 1;
}

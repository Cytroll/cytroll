# Packaging

Debian package layout for installing Cytroll into the Cytroll rootless prefix
(`/var/mobile/.lara_jb`).

## Layout

```
packaging/
├── debian/
│   ├── control      # Package metadata
│   ├── postinst     # Runs uicache after install
│   └── prerm        # Pre-removal hook
└── layout/          # Optional static files merged into .deb
```

Installed paths on device:

```
/var/mobile/.lara_jb/Applications/Cytroll.app/
/var/mobile/.lara_jb/usr/bin/          # (future CLI tools)
/var/mobile/.lara_jb/etc/apt/sources.list.d/cytroll.list
```

## Build

After `./build.sh`:

```bash
./Scripts/build-deb.sh
```

Output: `dist/com.cytroll.app_1.0.0_iphoneos-arm64.deb`

Install on device (after bootstrap):

```bash
/var/mobile/.lara_jb/usr/bin/dpkg -i com.cytroll.app_*.deb
```

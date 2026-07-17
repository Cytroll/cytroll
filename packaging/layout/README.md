# layout/

Optional static files that should be merged verbatim into the `.deb` staging
tree by `Scripts/build-deb.sh`, using the same relative paths they should
have on-device under the rootless prefix.

Example: to ship a CLI helper at `/var/jb/usr/bin/cytroll-cli`, place it at:

```
packaging/layout/var/jb/usr/bin/cytroll-cli
```

`Scripts/build-deb.sh` copies everything under `layout/` on top of the
staging directory before calling `dpkg-deb -b`. Leave this directory empty
(only this README) if you have nothing extra to ship — the app bundle and
default sources file are already staged directly by the script.

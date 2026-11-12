"""Packs a BeamNG mod folder into a zip whose entries start at the mod's root.

Usage: python pack.py <mod folder> <target zip>
Writes to <target zip>.part first and renames at the end, so the game never sees a half-written mod.
"""
import os
import sys
import zipfile


REPOSITORY_FOLDERS = {".git", "tools"}
REPOSITORY_FILES = {"README.md", "LICENSE", ".gitattributes", ".gitignore"}


def main(source, target):
    part = target + ".part"
    count, size = 0, 0
    with zipfile.ZipFile(part, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for directory, folders, files in os.walk(source):
            # Repository files stay out of the mod: the game only needs the mod's own tree.
            skipped = REPOSITORY_FOLDERS if directory == source else ()
            folders[:] = sorted(folder for folder in folders if folder not in skipped)
            for name in sorted(files):
                if directory == source and name in REPOSITORY_FILES:
                    continue
                path = os.path.join(directory, name)
                entry = os.path.relpath(path, source).replace(os.sep, "/")
                archive.write(path, entry)
                count += 1
                size += os.path.getsize(path)
    with zipfile.ZipFile(part) as archive:
        broken = archive.testzip()
        if broken:
            print("CORRUPT ENTRY:", broken)
            return 1
    if os.path.exists(target):
        os.remove(target)
    os.rename(part, target)
    print(f"packed {count} files, {size / 1e6:.0f} MB -> {os.path.getsize(target) / 1e6:.0f} MB at {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))

#!/usr/bin/env python3
"""Sync Sources/WonderBox/Resources/Localizable.xcstrings with the strings the compiler finds in source.

    scripts/sync_localization.py            # add new keys, mark vanished ones stale
    scripts/sync_localization.py --check    # exit 1 if the catalog is out of date or has untranslated keys

The compiler (not a regex) decides what is localizable, so interpolations get their real format
specifiers (%lld, %@). Entries marked `extractionState: manual` are kept regardless of source — that
is where messages coming from the helper daemon and the SMC layer live. Entries with
`shouldTranslate: false` (numbers, brand names) are never reported as untranslated.
"""
import glob, json, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Sources/WonderBox/Resources/Localizable.xcstrings"
LANGUAGES = ["zh-Hans"]


def source_keys() -> set[str]:
    with tempfile.TemporaryDirectory() as out:
        subprocess.run(
            ["swift", "build", "--product", "WonderBox",
             "-Xswiftc", "-emit-localized-strings", "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", out],
            cwd=ROOT, check=True, stdout=subprocess.DEVNULL,
        )
        keys = set()
        for path in glob.glob(f"{out}/*.stringsdata"):
            for entries in json.load(open(path))["tables"].values():
                keys.update(entry["key"] for entry in entries)
        return keys


def translation(entry: dict, language: str) -> str:
    return entry.get("localizations", {}).get(language, {}).get("stringUnit", {}).get("value", "")


def main() -> int:
    check = "--check" in sys.argv
    original = CATALOG.read_text()
    catalog = json.loads(original)
    strings = catalog["strings"]
    found = source_keys()

    added = sorted(key for key in found if key not in strings)
    for key in found:
        entry = strings.setdefault(key, {})
        if entry.get("extractionState") == "stale":
            del entry["extractionState"]

    stale, untranslated = [], []
    for key, entry in strings.items():
        if entry.get("extractionState") == "manual" or entry.get("shouldTranslate") is False:
            continue
        if key not in found:
            entry["extractionState"] = "stale"
            stale.append(key)
            continue
        untranslated += [(language, key) for language in LANGUAGES if not translation(entry, language)]

    catalog["strings"] = dict(sorted(strings.items()))
    rendered = json.dumps(catalog, ensure_ascii=False, indent=2) + "\n"

    for key in added:
        print(f"new:          {key}")
    for key in stale:
        print(f"stale:        {key}")
    for language, key in untranslated:
        print(f"untranslated: [{language}] {key}")

    if check:
        return 1 if (rendered != original or untranslated) else 0
    if rendered != original:
        CATALOG.write_text(rendered)
        print(f"updated {CATALOG.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

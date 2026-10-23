#!/usr/bin/env bash
set -euo pipefail

repo_dir="${1:-.}"

if [[ ! -f "$repo_dir/platformio.ini" || ! -f "$repo_dir/lib/Epub/Epub/ParsedText.cpp" ]]; then
  echo "HIBA: Ez nem tunik CrossPoint forraskonyvtarnak: $repo_dir" >&2
  echo "Hasznalat: bash apply-crosspoint-hu-fixes.sh /utvonal/crosspoint-reader" >&2
  exit 1
fi

repo_dir="$(cd "$repo_dir" && pwd)"

python3 - "$repo_dir" <<'PY'
from __future__ import annotations

import datetime
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])

paths = {
    "utf8_h": root / "lib/Utf8/Utf8.h",
    "utf8_cpp": root / "lib/Utf8/Utf8.cpp",
    "parsed": root / "lib/Epub/Epub/ParsedText.cpp",
    "section": root / "lib/Epub/Epub/Section.cpp",
    "qr": root / "src/util/QrUtils.cpp",
    "pio": root / "platformio.ini",
}

missing = [str(path.relative_to(root)) for path in paths.values() if not path.is_file()]
if missing:
    raise SystemExit("HIBA: Hianyzo fajl(ok): " + ", ".join(missing))

original = {name: path.read_text(encoding="utf-8") for name, path in paths.items()}
updated = dict(original)
notes: list[str] = []
warnings: list[str] = []

# Older versions of this guide used an inline byte-replacement loop directly in
# ParsedText.cpp. Recognise that form as well as the later modular Utf8 helper,
# otherwise running this script on an already hand-patched tree would install a
# second equivalent repair and unnecessarily bump the section-cache version.
inline_hex_tokens = (
    "0xB5", "0x95", "0xBB", "0x9B",  # õ Õ û Û UTF-8 trailing bytes
    "0x91", "0x90", "0xB1", "0xB0",  # ő Ő ű Ű UTF-8 trailing bytes
)
inline_literal_tokens = ("õ", "Õ", "û", "Û", "ő", "Ő", "ű", "Ű")
parsed_has_inline_fix = (
    "utf8ComposeNfc(word)" in updated["parsed"]
    and (
        all(token in updated["parsed"] for token in inline_hex_tokens)
        or all(token in updated["parsed"] for token in inline_literal_tokens)
    )
)
modular_call = "  utf8FixHungarianLegacyAccents(word);"
parsed_has_modular_fix = modular_call in updated["parsed"]
hungarian_fix_already_present = parsed_has_inline_fix or parsed_has_modular_fix

# 1. Hungarian legacy accent repair declaration.
declaration = "void utf8FixHungarianLegacyAccents(std::string& text);"
if not hungarian_fix_already_present and declaration not in updated["utf8_h"]:
    anchor = "std::string utf8ComposeNfc(const std::string& in);\n"
    if updated["utf8_h"].count(anchor) != 1:
        raise SystemExit("HIBA: Nem talalom egyertelmuen az Utf8.h beszurasi pontjat.")
    addition = """

// Repairs the legacy Hungarian substitutions used by some older ebooks:
// õ/Õ stood for ő/Ő and û/Û stood for ű/Ű. Each replacement has the same
// UTF-8 byte length, so the conversion can be performed in place.
void utf8FixHungarianLegacyAccents(std::string& text);
"""
    updated["utf8_h"] = updated["utf8_h"].replace(anchor, anchor + addition, 1)
    notes.append("Utf8.h: magyar javitofuggveny deklaralva")

# 2. Hungarian legacy accent repair implementation.
signature = "void utf8FixHungarianLegacyAccents(std::string& text)"
if not hungarian_fix_already_present and signature not in updated["utf8_cpp"]:
    anchor = "\nint utf8CodepointLen(const unsigned char c) {"
    if updated["utf8_cpp"].count(anchor) != 1:
        raise SystemExit("HIBA: Nem talalom egyertelmuen az Utf8.cpp beszurasi pontjat.")
    implementation = r'''

void utf8FixHungarianLegacyAccents(std::string& text) {
  for (size_t i = 0; i + 1 < text.size(); ++i) {
    const auto first = static_cast<uint8_t>(text[i]);
    const auto second = static_cast<uint8_t>(text[i + 1]);
    if (first != 0xC3) continue;

    switch (second) {
      case 0xB5:  // õ -> ő
        text[i] = static_cast<char>(0xC5);
        text[i + 1] = static_cast<char>(0x91);
        break;
      case 0x95:  // Õ -> Ő
        text[i] = static_cast<char>(0xC5);
        text[i + 1] = static_cast<char>(0x90);
        break;
      case 0xBB:  // û -> ű
        text[i] = static_cast<char>(0xC5);
        text[i + 1] = static_cast<char>(0xB1);
        break;
      case 0x9B:  // Û -> Ű
        text[i] = static_cast<char>(0xC5);
        text[i + 1] = static_cast<char>(0xB0);
        break;
      default:
        break;
    }
    ++i;
  }
}
'''
    updated["utf8_cpp"] = updated["utf8_cpp"].replace(anchor, implementation + anchor, 1)
    notes.append("Utf8.cpp: õ/Õ/û/Û csere implementalva")

# 3. Run the repair after the existing NFC composition, before layout/cache generation.
hungarian_call_added = False
if not hungarian_fix_already_present:
    anchor = "  word = utf8ComposeNfc(word);\n"
    if updated["parsed"].count(anchor) != 1:
        raise SystemExit("HIBA: Nem talalom egyertelmuen a ParsedText.cpp beszurasi pontjat.")
    updated["parsed"] = updated["parsed"].replace(anchor, anchor + modular_call + "\n", 1)
    hungarian_call_added = True
    notes.append("ParsedText.cpp: magyar javitas bekotve az EPUB tordelesebe")

# 4. Correct byte-mode capacities for the coarse QR version selection.
wrong_qr = """  int version = 4;
  if (len > 114) version = 10;
  if (len > 395) version = 20;
  if (len > 1066) version = 30;
  if (len > 2110) version = 40;"""
correct_qr = """  int version = 4;
  if (len > 78) version = 10;
  if (len > 271) version = 20;
  if (len > 858) version = 30;
  if (len > 1732) version = 40;"""

if correct_qr in updated["qr"]:
    pass
elif wrong_qr in updated["qr"]:
    updated["qr"] = updated["qr"].replace(wrong_qr, correct_qr, 1)
    notes.append("QrUtils.cpp: QR byte-kapacitasok javitva")
else:
    warnings.append(
        "A QR-verziovalasztas megvaltozott az uj forrasban. A script nem nyult hozza; "
        "ellenorizd kezzel a src/util/QrUtils.cpp fajlt."
    )

# 5. Force regeneration of pages cached by an unpatched build.
if hungarian_call_added:
    pattern = re.compile(r"constexpr uint8_t SECTION_FILE_VERSION = (\d+);")
    matches = list(pattern.finditer(updated["section"]))
    if len(matches) != 1:
        raise SystemExit("HIBA: Nem talalom egyertelmuen a SECTION_FILE_VERSION erteket.")
    old_version = int(matches[0].group(1))
    if old_version >= 249:
        raise SystemExit("HIBA: A SECTION_FILE_VERSION tul magas az automatikus novelesehez.")
    new_version = old_version + 1
    updated["section"] = pattern.sub(
        f"constexpr uint8_t SECTION_FILE_VERSION = {new_version};", updated["section"], count=1
    )
    notes.append(f"Section.cpp: cache-verzio {old_version} -> {new_version}")

# 6. Add a recognizable suffix to the firmware version.
version_pattern = re.compile(r"(?m)^(version\s*=\s*)([^\s;]+)\s*$")
version_matches = list(version_pattern.finditer(updated["pio"]))
if version_matches:
    current_version = version_matches[0].group(2)
    if "-hu" not in current_version:
        new_firmware_version = current_version + "-hu1"
        start, end = version_matches[0].span(2)
        updated["pio"] = updated["pio"][:start] + new_firmware_version + updated["pio"][end:]
        notes.append(f"platformio.ini: verzio {current_version} -> {new_firmware_version}")
else:
    warnings.append("Nem talaltam firmware-verziot a platformio.ini fajlban; nem modositottam.")

changed = [name for name in paths if updated[name] != original[name]]
if not changed:
    print("Nincs teendo: az ismert javitasok mar szerepelnek a forrasban.")
    for warning in warnings:
        print("FIGYELMEZTETES:", warning)
    raise SystemExit(0)

stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
backup = root / f".crosspoint-hu-fix-backup-{stamp}"
backup.mkdir()

for name in changed:
    path = paths[name]
    relative = path.relative_to(root)
    backup_path = backup / relative
    backup_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, backup_path)

for name in changed:
    path = paths[name]
    fd, temp_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(updated[name])
        os.chmod(temp_name, path.stat().st_mode)
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)

print("A javitasok elkészültek:")
for note in notes:
    print(" -", note)
print("Biztonsagi mentes:", backup)
for warning in warnings:
    print("FIGYELMEZTETES:", warning)
PY

echo
echo "Ellenorzes: git diff --check && git diff"
echo "Forditas:   pio run -e gh_release"

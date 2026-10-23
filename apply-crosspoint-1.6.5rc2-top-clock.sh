#!/bin/bash
set -euo pipefail

ROOT="${1:-$(pwd)}"

FILES=(
  "src/CrossPointSettings.h"
  "src/SettingsList.h"
  "src/activities/settings/StatusBarSettingsActivity.cpp"
  "src/components/themes/BaseTheme.cpp"
)

for f in "${FILES[@]}"; do
  if [ ! -f "$ROOT/$f" ]; then
    echo "HIBA: nem találom: $ROOT/$f" >&2
    exit 1
  fi
done

BACKUP="$ROOT/.crosspoint-top-clock-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"

for f in "${FILES[@]}"; do
  mkdir -p "$BACKUP/$(dirname "$f")"
  cp "$ROOT/$f" "$BACKUP/$f"
done

python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

def replace_once(path, old, new, label):
    text = path.read_text()
    if new in text:
        print(f"OK: {label} már benne van")
        return
    n = text.count(old)
    if n != 1:
        raise SystemExit(
            f"HIBA: {label}: a keresett eredeti rész {n} példányban található "
            f"(pontosan 1 kellene)."
        )
    path.write_text(text.replace(old, new, 1))
    print(f"OK: {label}")

# 1) Új órapozíció enum.
p = root / "src/CrossPointSettings.h"
old = """  enum STATUS_BAR_CLOCK_MODE {
    STATUS_BAR_CLOCK_HIDE = 0,
    STATUS_BAR_CLOCK_RIGHT = 1,
    STATUS_BAR_CLOCK_LEFT = 2,
    STATUS_BAR_CLOCK_MODE_COUNT
  };"""
new = """  enum STATUS_BAR_CLOCK_MODE {
    STATUS_BAR_CLOCK_HIDE = 0,
    STATUS_BAR_CLOCK_RIGHT = 1,
    STATUS_BAR_CLOCK_LEFT = 2,
    STATUS_BAR_CLOCK_TOP = 3,
    STATUS_BAR_CLOCK_MODE_COUNT
  };"""
replace_once(p, old, new, "STATUS_BAR_CLOCK_TOP enum")

# 2) Top módban az óra ne foglaljon helyet az alsó text lane-ben.
p = root / "src/CrossPointSettings.h"
old = """    bool textLaneVisible(bool clockAvailable) const {
      return showChapterPageCount || showBookProgressPercent || showsTitle() || showBattery ||
             (showsClock() && clockAvailable);
    }"""
new = """    bool textLaneVisible(bool clockAvailable) const {
      const bool bottomClockVisible =
          showsClock() && clockMode != STATUS_BAR_CLOCK_TOP && clockAvailable;
      return showChapterPageCount || showBookProgressPercent || showsTitle() || showBattery ||
             bottomClockVisible;
    }"""
replace_once(p, old, new, "Top óra kivétele az alsó text lane-ből")

# 3) Webes settings lista.
p = root / "src/SettingsList.h"
old = """    statusBarClockValues[CrossPointSettings::STATUS_BAR_CLOCK_HIDE] = StrId::STR_HIDE;
    statusBarClockValues[CrossPointSettings::STATUS_BAR_CLOCK_RIGHT] = StrId::STR_DIR_RIGHT;
    statusBarClockValues[CrossPointSettings::STATUS_BAR_CLOCK_LEFT] = StrId::STR_DIR_LEFT;"""
new = """    statusBarClockValues[CrossPointSettings::STATUS_BAR_CLOCK_HIDE] = StrId::STR_HIDE;
    statusBarClockValues[CrossPointSettings::STATUS_BAR_CLOCK_RIGHT] = StrId::STR_DIR_RIGHT;
    statusBarClockValues[CrossPointSettings::STATUS_BAR_CLOCK_LEFT] = StrId::STR_DIR_LEFT;
    statusBarClockValues[CrossPointSettings::STATUS_BAR_CLOCK_TOP] = StrId::STR_TOP;"""
replace_once(p, old, new, "SettingsList: Top opció")

# 4) Device UI: Hide / Right / Left / Top.
p = root / "src/activities/settings/StatusBarSettingsActivity.cpp"
text = p.read_text()
new_line = (
    "const StrId statusBarClockNames[STATUS_BAR_CLOCK_ITEMS] = "
    "{StrId::STR_HIDE, StrId::STR_DIR_RIGHT, StrId::STR_DIR_LEFT, StrId::STR_TOP};"
)
if new_line in text:
    print("OK: StatusBarSettingsActivity: Top opció már benne van")
else:
    pattern = re.compile(
        r"const StrId statusBarClockNames\[STATUS_BAR_CLOCK_ITEMS\]\s*=\s*"
        r"\{\s*StrId::STR_HIDE\s*,\s*StrId::STR_DIR_RIGHT\s*,\s*"
        r"StrId::STR_DIR_LEFT\s*\};"
    )
    text2, n = pattern.subn(new_line, text, count=1)
    if n != 1:
        raise SystemExit(
            "HIBA: StatusBarSettingsActivity: nem találtam egyértelműen "
            "a régi statusBarClockNames definíciót."
        )
    p.write_text(text2)
    print("OK: StatusBarSettingsActivity: Top opció")

# 5) Clock render: Top esetén a reader felső screenMargin sávjában középen.
p = root / "src/components/themes/BaseTheme.cpp"
text = p.read_text()

marker = "STATUS_BAR_CLOCK_TOP"
comment = "Top-centred clock"
if marker in text and comment in text:
    print("OK: BaseTheme: top-center óra már benne van")
else:
    start_marker = "  // Draw Clock (X3 only — DS3231 RTC)\n"
    end_marker = "\n  // Draw Bookmark"

    start = text.find(start_marker)
    if start < 0:
        raise SystemExit("HIBA: BaseTheme: nem találom a Clock blokk kezdetét.")

    end = text.find(end_marker, start)
    if end < 0:
        raise SystemExit("HIBA: BaseTheme: nem találom a Bookmark blokk kezdetét.")

    old_block = text[start:end]
    required = [
        "if (sb.showsClock() && halClock.isAvailable())",
        "STATUS_BAR_CLOCK_LEFT",
        "STATUS_BAR_CLOCK_RIGHT",
        "renderer.drawText(SMALL_FONT_ID, clockX, textY, timeBuf);",
    ]
    missing = [s for s in required if s not in old_block]
    if missing:
        raise SystemExit(
            "HIBA: BaseTheme Clock blokk eltér a várt RC2-s szerkezettől. Hiányzik: "
            + ", ".join(missing)
        )

    new_block = """  // Draw Clock (X3 only — DS3231 RTC)
  if (sb.showsClock() && halClock.isAvailable()) {
    char timeBuf[9];
    if (halClock.formatTime(timeBuf, sizeof(timeBuf), sb.clockUtcOffsetQ, sb.clock12h)) {
      const int clockTextWidth = renderer.getTextWidth(SMALL_FONT_ID, timeBuf);

      if (sb.clockMode == CrossPointSettings::STATUS_BAR_CLOCK_TOP) {
        // Top-centred clock, independent of the bottom status-bar layout.
        const int clockX = (renderer.getScreenWidth() - clockTextWidth) / 2;
        const int clockLineHeight = renderer.getLineHeight(SMALL_FONT_ID);
        const int topBandHeight = SETTINGS.screenMargin;
        const int clockY =
            orientedMarginTop + std::max(0, (topBandHeight - clockLineHeight) / 2);
        renderer.drawText(SMALL_FONT_ID, clockX, clockY, timeBuf);
      } else {
        int clockX = 0;

        if (sb.clockMode == CrossPointSettings::STATUS_BAR_CLOCK_LEFT) {
          clockX = leftClusterX + leftClusterWidth + (leftClusterWidth > 0 ? 10 : 0);
          leftClusterWidth += clockTextWidth + 10;
        } else if (sb.clockMode == CrossPointSettings::STATUS_BAR_CLOCK_RIGHT) {
          clockX = rightClusterX - rightClusterWidth - (rightClusterWidth > 0 ? 10 : 0) - clockTextWidth;
          rightClusterWidth += clockTextWidth + 10;
        }

        renderer.drawText(SMALL_FONT_ID, clockX, textY, timeBuf);
      }
    }
  }"""

    p.write_text(text[:start] + new_block + text[end:])
    print("OK: BaseTheme: top-center óra")

print()
print("A top-center óra patch elkészült.")
PY

echo
echo "Biztonsági mentés:"
echo "  $BACKUP"
echo
echo "Ellenőrzés:"
echo "  git -C \"$ROOT\" diff --check"
echo "  git -C \"$ROOT\" diff -- \\"
echo "    src/CrossPointSettings.h \\"
echo "    src/SettingsList.h \\"
echo "    src/activities/settings/StatusBarSettingsActivity.cpp \\"
echo "    src/components/themes/BaseTheme.cpp"

# Import Check Menu – Integration Guide

## Overview

This is a redesigned **Import Check** menu UI for hasher (v1.4.20+) with:
- **ASCII art icons** (NAS, Folder, Quarantine) that work on both macOS and BusyBox
- **Emoji support detection** (⚠️ on macOS/UTF-8 terminals, [!] on BusyBox)
- **Clear operation descriptions** explaining what each step does
- **Visual workflow diagram** showing data flows between NAS, Import, and Quarantine

---

## Files Included

### `import-check-menu.sh`
The main menu module. Contains:
- Icon detection & setup functions
- Menu display with workflow header
- Detailed operation descriptions (drilldown help text)
- Color-coded output for readability

---

## Integration Steps

### 1. **Add to Your Project**

Copy `import-check-menu.sh` into your hasher repository:

```bash
cp import-check-menu.sh /path/to/hasher/lib/import-check-menu.sh
```

### 2. **Source in launcher.sh**

In your main `launcher.sh` (or wherever Import Check is invoked):

```bash
#!/bin/bash

# At the top, with other sourcing:
source ./lib/import-check-menu.sh

# Later, where Import Check menu is displayed:
show_import_menu
```

### 3. **Connect Menu to Operations**

The menu displays options 1–6. Wire them to your existing functions:

```bash
# After show_import_menu displays and user selects:
case "$selection" in
    1)
        import_check_setup_source
        ;;
    2)
        import_check_scan_folder
        ;;
    3)
        import_check_show_summary
        ;;
    4)
        import_check_remove_nas_duplicates
        ;;
    5)
        import_check_dedupe_internal
        ;;
    6)
        import_check_move_new_files
        ;;
    b)
        # Back to main menu
        ;;
esac
```

### 4. **Optional: Add Drilldown Help**

If user selects an option and wants more info before confirming:

```bash
if [[ "$help_requested" == true ]]; then
    show_operation_details "$selection"
fi
```

---

## Platform-Specific Notes

### macOS
- **Emoji detection**: Automatically enabled
- **Quarantine icon**: Shows ⚠️ warning emoji
- Terminal requirement: Any modern terminal (Terminal.app, iTerm2, etc.)

### Synology DSM (BusyBox)
- **Emoji detection**: Checks for UTF-8 locale support
- **Quarantine icon**: Falls back to [!] (safe ASCII)
- No emoji dependencies—pure ASCII characters used throughout

### Force ASCII-Only Mode
If you want to disable emoji everywhere:

```bash
# Run with NO_EMOJI=1 to force ASCII
NO_EMOJI=1 /volume1/Tools/hasher/lib/import-check-menu.sh
```

Or set in your script:
```bash
export NO_EMOJI=1
source ./lib/import-check-menu.sh
```

---

## Icon Reference

### NAS Icon (Retro Drive)
```
┌─────┐
├ ▌▌▌ │
└─────┘
```
Represents: Read-only storage reference (Synology NAS)

### Folder Icon (Import)
```
┌──┐
│▬▬│
└──┴──┘
```
Represents: Source files to be ingested (external drive, USB, backup)

### Quarantine Icon (Isolation)
```
╔═════╗
║  ⚠  ║   (macOS with emoji)
╚═════╝

╔═════╗
║ [!] ║   (BusyBox, ASCII-only)
╚═════╝
```
Represents: Isolated copies (never deleted, available for review)

---

## Menu Structure

```
════════════════ IMPORT CHECK WORKFLOW ════════════════

    [NAS]           [FOLDER]         [QUARANTINE]
  (Read-Only)     (Source Files)      (Isolated)

Import folder: /volume1/Tools/import

 1) Set import source
    └─ Choose where new files come from

 2) Scan & hash import folder
    └─ Index all files (compute hashes)

┌──────────────────────────────────────┐
│ 3) Show import summary               │
│    Compares: NAS ↔ Import folder    │
└──────────────────────────────────────┘

 4) Remove copies already on NAS
    ├─ Import → Quarantine (NAS unchanged)

 5) Deduplicate within import folder
    ├─ Import (redundant) → Quarantine

 6) Move new files to sort folder
    ├─ Import → /unique-files/

 b) Back
```

---

## Typical Workflow

**Scenario: Ingesting Ruth's Photos Library (~72k files)**

```
Step 1: Set import source
   └─ Point to: /mnt/external/Ruth-Backup/

Step 2: Scan & hash import folder
   └─ Compute hashes for all 72,685 files (~5–10 min)

Step 3: Show import summary
   └─ See: X files match NAS, Y are duplicates, Z are new

Step 4: Remove copies already on NAS
   └─ Quarantine matches → NAS stays clean
   └─ Remaining: ~500 internal dupes + ~200 new files

Step 5: Deduplicate within import folder
   └─ Clean up the ~500 internal duplicates
   └─ Remaining: ~200 genuinely new files

Step 6: Move new files to sort folder
   └─ Move to /unique-files/ for hand-review
   └─ Place on NAS after inspection
```

---

## Color Output

The menu uses ANSI color codes for clarity:

- **Cyan + Bold**: Section headers (workflow title)
- **Bold**: Important labels (folder path, selection prompt)
- **Yellow**: Input prompts ("Select an option:")
- **Green** (available for status messages, e.g., "✓ Complete")

Color codes are automatically stripped if output is piped/redirected (standard bash practice).

---

## Testing

Run the menu directly to test:

```bash
# View the menu
./import-check-menu.sh

# Select option 3 to see operation details
echo "3" | ./import-check-menu.sh

# Test with ASCII-only mode
NO_EMOJI=1 ./import-check-menu.sh
```

---

## Future Enhancements

Possible additions (out of scope for this build):

- Add `?` option to show operation details without running them
- Animated progress bars for long operations (step 2, 4, 5)
- Nested submenus (e.g., "4a) Show discard plan" before "4b) Execute")
- Save/load import state (resume interrupted imports)
- Dry-run mode (show what would happen, don't modify anything)

---

## Questions?

If you need to adjust:
- Icon designs → edit the `read -r -d ''` blocks in `setup_icons()`
- Color scheme → modify `COLOR_*` variables at the top
- Operation descriptions → edit `show_operation_details()` case statements
- Menu text → edit `show_import_menu_options()` or `show_import_workflow_header()`

All changes are modular and don't affect the operational logic—just the UI layer.

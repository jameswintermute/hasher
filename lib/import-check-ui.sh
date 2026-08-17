#!/bin/bash

################################################################################
# Import Check Menu - ASCII Art UI with Emoji Support Detection
# For: hasher NAS file deduplication tool
# Platform support: BusyBox (DSM) + macOS
################################################################################

# Color codes for terminal output
readonly COLOR_RESET='\033[0m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_CYAN='\033[36m'
readonly COLOR_GREEN='\033[32m'
readonly COLOR_YELLOW='\033[33m'

################################################################################
# ICON DETECTION & SETUP
################################################################################

detect_emoji_support() {
    # Check if terminal supports emoji
    case "$(uname -s)" in
        Darwin)
            # macOS - check if iTerm2 or Terminal
            EMOJI_SUPPORT=true
            ;;
        Linux)
            # NAS/BusyBox - check for emoji capability
            if command -v locale &>/dev/null; then
                if locale charmap 2>/dev/null | grep -qi UTF-8; then
                    EMOJI_SUPPORT=true
                else
                    EMOJI_SUPPORT=false
                fi
            else
                EMOJI_SUPPORT=false
            fi
            ;;
        *)
            EMOJI_SUPPORT=false
            ;;
    esac
    
    # Allow override
    if [[ "${NO_EMOJI:-0}" == "1" ]]; then
        EMOJI_SUPPORT=false
    fi
}

setup_icons() {
    # Retro NAS Drive Icon (same for all - pure ASCII art)
    read -r -d '' NAS_ICON << 'EOF'
    ┌─────┐
    ├ ▌▌▌ │
    └─────┘
EOF

    # Folder Icon (Import) - same for all
    read -r -d '' FOLDER_ICON << 'EOF'
    ┌──┐
    │▬▬│
    └──┴──┘
EOF

    # Quarantine Bin - varies by emoji support
    if [[ "$EMOJI_SUPPORT" == true ]]; then
        read -r -d '' QUARANTINE_ICON << 'EOF'
    ╔═════╗
    ║  ⚠  ║
    ╚═════╝
EOF
    else
        read -r -d '' QUARANTINE_ICON << 'EOF'
    ╔═════╗
    ║ [!] ║
    ╚═════╝
EOF
    fi
}

################################################################################
# MENU DISPLAY
################################################################################

show_import_workflow_header() {
    echo ""
    echo -e "${COLOR_CYAN}${COLOR_BOLD}════════════════ IMPORT CHECK WORKFLOW ════════════════${COLOR_RESET}"
    echo ""
    
    # Display the three icons inline
    paste <(echo "$NAS_ICON" | sed 's/^/    /') \
          <(echo "$FOLDER_ICON" | sed 's/^/        /') \
          <(echo "$QUARANTINE_ICON" | sed 's/^/          /')
    
    echo ""
    echo "    NAS STORAGE        IMPORT FOLDER       QUARANTINE"
    echo "   (Read-Only)         (Source Files)      (Isolated)"
    echo ""
}

show_import_menu_options() {
    cat << 'EOF'
   1) Set import source
      └─ Configure where files come from (SD cards, backups, USB, etc.)

   2) Scan & hash import folder
      └─ Index all files in import folder (compute hashes for comparison)

   ┌─────────────────────────────────────────────────────────────┐
   │ 3) Show import summary                                      │
   │    Compares: NAS ↔ Import folder                           │
   │    Shows: Total files, duplicates found, new files         │
   └─────────────────────────────────────────────────────────────┘

   4) Remove copies already on NAS
      ├─ Import folder → Scan for matches with NAS
      ├─ Quarantine copies (verified, safe)
      └─ NAS untouched

   5) Deduplicate within import folder
      ├─ Remove duplicate copies INSIDE import only
      ├─ Keep the file with the shortest path
      └─ Quarantine redundant copies

   6) Move new files to sort folder
      ├─ Files that are unique (new content)
      ├─ Not on NAS, not duplicates
      └─ Import → /unique-files/ (for hand-review)

   b) Back
EOF
}

show_import_menu() {
    detect_emoji_support
    setup_icons
    
    clear
    show_import_workflow_header
    
    echo -e "${COLOR_BOLD}Import folder:${COLOR_RESET} /volume1/Tools/import"
    echo ""
    show_import_menu_options
    echo ""
    echo -e "${COLOR_YELLOW}Select an option:${COLOR_RESET}"
}

################################################################################
# DETAILED OPERATION DESCRIPTIONS
################################################################################

show_operation_details() {
    local op=$1
    
    case "$op" in
        1)
            cat << 'EOF'

[1] SET IMPORT SOURCE
────────────────────────────────────────────────────────────────
Where are your new files coming from?

Examples:
  • /mnt/usb/photos         (USB drive)
  • /mnt/sd/backup          (SD card)
  • ~/Downloads/archive     (External backup folder)
  • /Volumes/CloudDrive     (Cloud export on Mac)

IMPORTANT: Choose an external source—not a folder already on the NAS.

Your import folder must be isolated from NAS root to guarantee
that only copies sitting in import are ever modified.

EOF
            ;;
        2)
            cat << 'EOF'

[2] SCAN & HASH IMPORT FOLDER
────────────────────────────────────────────────────────────────
Builds a hash index of every file in your import folder.

This step:
  ✓ Computes SHA256 hash for each file
  ✓ Records file size, path, and metadata
  ✓ Detects internal duplicates within import folder
  ✓ Prepares data for comparison with NAS

Time depends on folder size and disk speed.
(Large imports may take several minutes)

EOF
            ;;
        3)
            cat << 'EOF'

[3] SHOW IMPORT SUMMARY
────────────────────────────────────────────────────────────────
Comparison: NAS storage ↔ Import folder

Shows:
  • NAS: Total files, total size
  • Import: Total files, total size
  • Matching files (already on NAS)
  • Duplicates (multiple copies in import)
  • New files (unique to import)

Use this to decide next steps—do you want to:
  → Remove NAS copies first? (option 4)
  → Dedupe the import folder itself first? (option 5)
  → Move new files? (option 6)

EOF
            ;;
        4)
            cat << 'EOF'

[4] REMOVE COPIES ALREADY ON NAS
────────────────────────────────────────────────────────────────
Identifies files in import that match verified copies on NAS.

Operation:
  1. Scans import folder for matches with NAS manifest
  2. Verifies hashes (ensures identical files)
  3. Proposes copies in import for quarantine
  4. Asks for confirmation before touching anything
  5. Moves matched copies → /quarantine folder (safe hold)

NAS FILES: Never touched or modified ✓

After this step:
  • Import folder has fewer files (duplicates removed)
  • Remaining files are either new or internal duplicates
  • Ready for step 5 (dedupe internally)

EOF
            ;;
        5)
            cat << 'EOF'

[5] DEDUPLICATE WITHIN IMPORT FOLDER
────────────────────────────────────────────────────────────────
Removes duplicate copies that exist ONLY within import folder.

Operation:
  1. Identifies files with identical hashes in import
  2. Keeps the one with shortest path (best-organized)
  3. Quarantines redundant copies
  4. Asks for confirmation before removal

Example:
  import/Photos/IMG_001.jpg     ✓ Keep (shorter path)
  import/Backups/Photos/IMG_001.jpg  → Quarantine

After this step:
  • Import folder has no internal duplicates
  • Remaining files are all unique
  • Ready for step 6 (move new files)

EOF
            ;;
        6)
            cat << 'EOF'

[6] MOVE NEW FILES TO SORT FOLDER
────────────────────────────────────────────────────────────────
Moves files that are genuinely new (not on NAS, not duplicates).

Operation:
  1. Takes remaining files in import (after steps 4-5)
  2. Verifies they're unique (no matches on NAS)
  3. Moves them → /volume1/Tools/import/unique-files/
  4. Creates organized sort folder for hand-review

After this step:
  • Original import folder is mostly empty
  • New content is isolated in unique-files/
  • You can review before final placement on NAS

EOF
            ;;
    esac
}

################################################################################
# MAIN FLOW (FOR TESTING)
################################################################################

main() {
    show_import_menu
    
    read -p "Enter selection [1-6, b]: " selection
    
    case "$selection" in
        1|2|3|4|5|6)
            echo ""
            show_operation_details "$selection"
            ;;
        b)
            echo "Going back..."
            ;;
        *)
            echo "Invalid selection"
            ;;
    esac
}

# Run if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

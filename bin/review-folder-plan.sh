#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.
#
# review-folder-plan.sh — interactive reviewer for duplicate-folder dedup plans
#
# Reads a groups TSV (produced by find-duplicate-folders.sh) and walks the user
# through each duplicate group, letting them accept/skip/swap the keeper
# choice. Writes a reviewed plan to logs/, timestamped, in the same simple
# format apply-folder-plan.sh expects (one deldir per line).
#
# Usage:
#   bin/review-folder-plan.sh [--groups TSV] [--plan PLAN]
#     --groups TSV   Group context (default: latest duplicate-folders-groups-*.tsv)
#     --plan   PLAN  Original plan (default: latest duplicate-folders-plan-*.txt)
#                    Not strictly needed, but referenced in the output header for
#                    audit traceability.

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd -P)"
LOGS_DIR="$ROOT_DIR/logs"
mkdir -p "$LOGS_DIR"

# ── colours ──────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
  C_INFO="$(printf '\033[1;34m')"
  C_OK="$(printf '\033[1;32m')"
  C_WARN="$(printf '\033[1;33m')"
  C_ERR="$(printf '\033[1;31m')"
  C_KEEP="$(printf '\033[1;36m')"   # cyan for KEEP
  C_DEL="$(printf '\033[1;35m')"    # magenta for DEL
  C_DIM="$(printf '\033[2m')"
  C_BOLD="$(printf '\033[1m')"
  C_RST="$(printf '\033[0m')"
else
  C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""
  C_KEEP=""; C_DEL=""; C_DIM=""; C_BOLD=""; C_RST=""
fi

info(){ printf "%s[INFO]%s %s\n" "$C_INFO" "$C_RST" "$*"; }
ok(){   printf "%s[OK]%s %s\n"   "$C_OK"   "$C_RST" "$*"; }
warn(){ printf "%s[WARN]%s %s\n" "$C_WARN" "$C_RST" "$*"; }
err(){  printf "%s[ERR]%s %s\n"  "$C_ERR"  "$C_RST" "$*"; }

# ── args ─────────────────────────────────────────────────────────────────────
GROUPS_TSV=""
PLAN_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --groups) GROUPS_TSV="${2:-}"; shift 2;;
    --plan)   PLAN_FILE="${2:-}"; shift 2;;
    -h|--help)
      sed -n '8,21p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) err "Unknown arg: $1"; exit 2;;
  esac
done

# Default to latest groups TSV if not specified
if [ -z "$GROUPS_TSV" ]; then
  GROUPS_TSV="$(ls -1t "$LOGS_DIR"/duplicate-folders-groups-*.tsv 2>/dev/null | head -n1 || true)"
fi
if [ -z "$GROUPS_TSV" ] || [ ! -s "$GROUPS_TSV" ]; then
  err "No groups TSV found. Run 'Find duplicate folders' (launcher option 3) first."
  err "Expected file: logs/duplicate-folders-groups-YYYY-MM-DD.tsv"
  exit 2
fi

if [ -z "$PLAN_FILE" ]; then
  PLAN_FILE="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"
fi

# ── helpers ──────────────────────────────────────────────────────────────────

# Human-readable byte size. Input: integer bytes.
human_bytes() {
  local b="${1:-0}"
  if   [ "$b" -ge 1099511627776 ]; then awk -v b="$b" 'BEGIN{printf "%.1f TB", b/1099511627776}'
  elif [ "$b" -ge 1073741824 ];     then awk -v b="$b" 'BEGIN{printf "%.1f GB", b/1073741824}'
  elif [ "$b" -ge 1048576 ];        then awk -v b="$b" 'BEGIN{printf "%.1f MB", b/1048576}'
  elif [ "$b" -ge 1024 ];           then awk -v b="$b" 'BEGIN{printf "%.1f KB", b/1024}'
  else                                   printf "%s B" "$b"
  fi
}

# Count files in a directory (best-effort; the dirs come from the original
# scan and should still exist, but we don't crash if they don't).
count_files_in_dir() {
  local d="$1"
  if [ -d "$d" ]; then
    find "$d" -type f 2>/dev/null | wc -l | tr -d ' '
  else
    printf "0"
  fi
}

# Sample basenames of files in a directory (up to N).
sample_files_in_dir() {
  local d="$1" n="${2:-3}"
  if [ -d "$d" ]; then
    find "$d" -maxdepth 1 -type f 2>/dev/null | head -n "$n" | while IFS= read -r f; do
      printf "%s\n" "$(basename "$f")"
    done
  fi
}

# v1.2.2: classify a group's DEL folders by their CURRENT presence on disk.
# This is how the reviewer knows a group was already actioned — it asks the
# disk (unforgeable), never a log (forgeable). Returns one of:
#   present  — at least one DEL folder still exists at its original path
#   gone     — every DEL folder is absent from its original path
# A "gone" group has nothing left to quarantine (whether Hasher moved it in a
# previous session, or it was removed by other means), so it is auto-skipped.
group_del_status() {
  local idx="$1"
  local dels="${G_DELS[$idx]}"
  local any_present=0
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    if [ -e "$d" ]; then
      any_present=1
      break
    fi
  done <<< "$dels"
  if [ "$any_present" -eq 1 ]; then
    printf "present"
  else
    printf "gone"
  fi
}

# Build the in-memory group list from the TSV. Multiple rows can share a
# keep_dir (one group with N>=1 delete entries each). We collapse them into
# group records: keepdir, list of deldirs, total reclaim bytes.
#
# We use parallel arrays indexed by group number. Bash 3.2 doesn't have
# associative arrays portably, so we use a delimiter-joined string for
# the deldir list per group.
#
# Globals populated:
#   G_KEEP[]   — keeper dir for group i
#   G_DELS[]   — newline-joined list of del dirs for group i
#   G_BYTES[]  — total reclaim bytes for group i
#   G_COUNT    — number of groups

declare -a G_KEEP G_DELS G_BYTES
G_COUNT=0

load_groups() {
  local prev_keep=""
  local cur_keep="" cur_dels="" cur_bytes=0
  local sz keepdir deldir
  while IFS=$'\t' read -r sz keepdir deldir; do
    [ -z "$keepdir" ] && continue
    if [ "$keepdir" != "$prev_keep" ]; then
      # flush previous
      if [ -n "$prev_keep" ]; then
        G_KEEP[G_COUNT]="$prev_keep"
        G_DELS[G_COUNT]="$cur_dels"
        G_BYTES[G_COUNT]="$cur_bytes"
        G_COUNT=$((G_COUNT + 1))
      fi
      cur_keep="$keepdir"
      cur_dels="$deldir"
      cur_bytes="$sz"
      prev_keep="$keepdir"
    else
      cur_dels="${cur_dels}"$'\n'"$deldir"
      cur_bytes=$((cur_bytes + sz))
    fi
  done < "$GROUPS_TSV"
  # final flush
  if [ -n "$prev_keep" ]; then
    G_KEEP[G_COUNT]="$prev_keep"
    G_DELS[G_COUNT]="$cur_dels"
    G_BYTES[G_COUNT]="$cur_bytes"
    G_COUNT=$((G_COUNT + 1))
  fi
}

# ── decision tracking ───────────────────────────────────────────────────────
#
# For each group we record exactly one of:
#   accept  — keeper stays, all dels are quarantined as-is
#   skip    — do nothing with this group; remove all of its entries from the plan
#   swap    — pick a different deldir as the keeper; original keeper joins the dels
#
# Tracked via parallel arrays D_ACTION[] and D_SWAP_TO[] (the chosen new keeper
# when D_ACTION is "swap"; empty otherwise).

declare -a D_ACTION D_SWAP_TO
LAST_ACTION="accept"  # used by [a] apply-last-to-all
SKIPPED_GONE=0        # v1.2.2: count of groups auto-skipped (DEL already gone)

# ── per-group rendering ─────────────────────────────────────────────────────

show_group() {
  local idx="$1"
  local keep="${G_KEEP[$idx]}"
  local dels="${G_DELS[$idx]}"
  local bytes="${G_BYTES[$idx]}"
  local ndel
  ndel="$(printf "%s\n" "$dels" | wc -l | tr -d ' ')"
  local total_folders=$((ndel + 1))

  echo
  printf "%sGroup %d of %d%s — %d folders, %s reclaimable\n" \
    "$C_BOLD" "$((idx + 1))" "$G_COUNT" "$C_RST" \
    "$total_folders" "$(human_bytes "$bytes")"
  echo

  # Keeper details
  local keep_fc
  keep_fc="$(count_files_in_dir "$keep")"
  printf "  %sKEEP:%s %s\n" "$C_KEEP" "$C_RST" "$keep"
  printf "        %s%d files%s\n" "$C_DIM" "$keep_fc" "$C_RST"
  local samples
  samples="$(sample_files_in_dir "$keep" 3)"
  if [ -n "$samples" ]; then
    printf "        %sSample:%s " "$C_DIM" "$C_RST"
    printf "%s" "$samples" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g'
    if [ "$keep_fc" -gt 3 ]; then
      printf " ... +%d more" "$((keep_fc - 3))"
    fi
    echo
  fi
  echo

  # Each delete entry
  local del_n=0
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    del_n=$((del_n + 1))
    local del_fc
    del_fc="$(count_files_in_dir "$d")"
    printf "  %sDEL %d:%s %s\n" "$C_DEL" "$del_n" "$C_RST" "$d"
    printf "         %s%d files%s\n" "$C_DIM" "$del_fc" "$C_RST"
    samples="$(sample_files_in_dir "$d" 3)"
    if [ -n "$samples" ]; then
      printf "         %sSample:%s " "$C_DIM" "$C_RST"
      printf "%s" "$samples" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g'
      if [ "$del_fc" -gt 3 ]; then
        printf " ... +%d more" "$((del_fc - 3))"
      fi
      echo
    fi
  done <<< "$dels"
  echo
}

# Full file-by-file dump for a group (paged through less if available)
show_full_diff() {
  local idx="$1"
  local keep="${G_KEEP[$idx]}"
  local dels="${G_DELS[$idx]}"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/folder-diff.XXXXXX")"
  {
    printf "Full file listing for group %d of %d\n" "$((idx + 1))" "$G_COUNT"
    printf "================================================================\n\n"
    printf "KEEP: %s\n" "$keep"
    if [ -d "$keep" ]; then
      find "$keep" -type f 2>/dev/null | sort | sed 's|^|  |'
    else
      printf "  (directory not found)\n"
    fi
    echo
    local del_n=0
    while IFS= read -r d; do
      [ -z "$d" ] && continue
      del_n=$((del_n + 1))
      printf "DEL %d: %s\n" "$del_n" "$d"
      if [ -d "$d" ]; then
        find "$d" -type f 2>/dev/null | sort | sed 's|^|  |'
      else
        printf "  (directory not found)\n"
      fi
      echo
    done <<< "$dels"
  } > "$tmp"

  if command -v less >/dev/null 2>&1; then
    less "$tmp"
  elif command -v more >/dev/null 2>&1; then
    more "$tmp"
  else
    cat "$tmp"
  fi
  rm -f -- "$tmp"
}

# Prompt for swap choice within a group (pick one of the DEL dirs to become
# the new keeper). Returns chosen 1-indexed slot via echo, or empty on cancel.
prompt_swap_choice() {
  local idx="$1"
  local dels="${G_DELS[$idx]}"
  local n
  n="$(printf "%s\n" "$dels" | wc -l | tr -d ' ')"
  if [ "$n" -lt 1 ]; then printf ""; return; fi
  # FIX (v1.2.1): this function is called inside $(...) command substitution,
  # so its STDOUT is captured as the return value. All human-facing UI (the
  # menu, the prompt) must therefore go to STDERR (>&2) — otherwise the menu
  # text gets captured into the caller's variable alongside the chosen number,
  # and the prompt never appears live (which manifested as needing to press
  # Enter twice). Only the chosen number is written to stdout.
  echo "  Which DEL should become the new keeper?" >&2
  local i=0
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    i=$((i + 1))
    printf "    %d) %s\n" "$i" "$d" >&2
  done <<< "$dels"
  printf "    c) Cancel — keep original keeper\n" >&2
  printf "  Choice: " >&2
  read -r reply || reply="c"
  case "$reply" in
    c|C|"") printf "" ;;
    *)
      if [ "$reply" -ge 1 ] 2>/dev/null && [ "$reply" -le "$n" ] 2>/dev/null; then
        printf "%s" "$reply"
      else
        printf ""
      fi
      ;;
  esac
}

# ── apply-last-to-all ────────────────────────────────────────────────────────
# When the user presses [a], we apply LAST_ACTION (and LAST_SWAP_TO for swap)
# to all remaining groups. For swap, "apply last to all" is dangerous because
# the swap-to index may not even exist in subsequent groups. To keep this
# safe and predictable, we restrict apply-last-to-all to the simple actions:
# accept and skip. Swap requires per-group decision-making.

apply_remaining_with_last() {
  local from_idx="$1"
  local action="$LAST_ACTION"
  if [ "$action" = "swap" ]; then
    warn "Cannot bulk-apply 'swap' across groups — each group needs its own swap target."
    warn "Falling back to 'accept' for the remaining groups."
    action="accept"
  fi
  printf "%sApply '%s' to all %d remaining groups?%s [y/N]: " \
    "$C_BOLD" "$action" "$((G_COUNT - from_idx))" "$C_RST"
  read -r confirm || confirm="n"
  case "$confirm" in
    y|Y|yes|YES)
      local i
      for (( i = from_idx; i < G_COUNT; i++ )); do
        # v1.2.2: never bulk-action a group whose DEL folders are already gone
        if [ "$(group_del_status "$i")" = "gone" ]; then
          D_ACTION[i]="already_done"
          D_SWAP_TO[i]=""
          SKIPPED_GONE=$((SKIPPED_GONE + 1))
          continue
        fi
        D_ACTION[i]="$action"
        D_SWAP_TO[i]=""
        printf "  %s[Group %d]%s DECISION: %s\n" "$C_DIM" "$((i + 1))" "$C_RST" "$action"
      done
      printf "%s\n" "Done. Proceeding to summary."
      return 0
      ;;
    *) return 1 ;;
  esac
}

# ── main review loop ─────────────────────────────────────────────────────────

review_loop() {
  local i=0

  # v1.2.2: pre-scan the disk to report how many groups are already applied
  # before we start, so the user understands why the walk may begin at a
  # group number other than 1 (or skip large stretches). This is a read-only
  # disk check; it makes no decisions and reads no logs.
  local pre_gone=0 pre_present=0 _s
  for (( _s = 0; _s < G_COUNT; _s++ )); do
    if [ "$(group_del_status "$_s")" = "gone" ]; then
      pre_gone=$((pre_gone + 1))
    else
      pre_present=$((pre_present + 1))
    fi
  done
  if [ "$pre_gone" -gt 0 ]; then
    info "$pre_gone of $G_COUNT group(s) already applied (DEL folders gone) — these will be skipped."
    info "$pre_present group(s) remain to review."
    echo
  fi

  while [ "$i" -lt "$G_COUNT" ]; do
    # v1.2.2: skip groups whose DEL folders are already gone from disk.
    # This is the disk-state check that stops the reviewer looping back
    # through groups actioned in a previous session. Decision is driven by
    # physical reality, not by reading any log.
    if [ "$(group_del_status "$i")" = "gone" ]; then
      D_ACTION[i]="already_done"
      D_SWAP_TO[i]=""
      SKIPPED_GONE=$((SKIPPED_GONE + 1))
      i=$((i + 1))
      continue
    fi

    show_group "$i"

    local default_letter="y"
    local default_label="accept (quarantine all DEL folders)"

    cat <<EOF
  [y] Accept — quarantine all DEL folders, keep current KEEP (default)
  [n] Skip — leave this group entirely alone
  [s] Swap — choose a different folder as the keeper
  [d] Show full file-by-file listing for this group
  [a] Apply LAST decision ('$LAST_ACTION') to all $((G_COUNT - i)) remaining groups
  [q] Quit review — save decisions made so far, abandon the rest
EOF
    printf "  Choice [%s]: " "$default_letter"
    read -r ch || ch=""
    [ -z "$ch" ] && ch="$default_letter"

    case "$ch" in
      y|Y)
        D_ACTION[i]="accept"
        D_SWAP_TO[i]=""
        LAST_ACTION="accept"
        printf "  %s[Group %d]%s DECISION: accept (quarantine %d folders, %s)\n" \
          "$C_DIM" "$((i + 1))" "$C_RST" \
          "$(printf "%s\n" "${G_DELS[$i]}" | wc -l | tr -d ' ')" \
          "$(human_bytes "${G_BYTES[$i]}")"
        i=$((i + 1))
        ;;
      n|N)
        D_ACTION[i]="skip"
        D_SWAP_TO[i]=""
        LAST_ACTION="skip"
        printf "  %s[Group %d]%s DECISION: skip (no action)\n" "$C_DIM" "$((i + 1))" "$C_RST"
        i=$((i + 1))
        ;;
      s|S)
        local chosen
        chosen="$(prompt_swap_choice "$i")"
        if [ -z "$chosen" ]; then
          echo "  Swap cancelled."
          # don't advance; redisplay
          continue
        fi
        D_ACTION[i]="swap"
        D_SWAP_TO[i]="$chosen"
        LAST_ACTION="swap"
        printf "  %s[Group %d]%s DECISION: swap (DEL %s becomes new keeper)\n" \
          "$C_DIM" "$((i + 1))" "$C_RST" "$chosen"
        i=$((i + 1))
        ;;
      d|D)
        show_full_diff "$i"
        # don't advance; redisplay group menu after the pager closes
        continue
        ;;
      a|A)
        if apply_remaining_with_last "$i"; then
          i="$G_COUNT"  # break out
        fi
        ;;
      q|Q)
        warn "Review aborted by user at group $((i + 1)) of $G_COUNT."
        warn "Decisions for groups $((i + 1))..$G_COUNT will not be in the reviewed plan."
        return 1
        ;;
      *)
        echo "  Unknown choice: $ch"
        continue
        ;;
    esac
  done
  return 0
}

# ── write reviewed plan ──────────────────────────────────────────────────────

write_reviewed_plan() {
  local stamp
  stamp="$(date +%Y-%m-%d-%H%M%S)"
  local out="$LOGS_DIR/duplicate-folders-plan-reviewed-$stamp.txt"
  # FIX (v1.3.6 — cross-check concern 4): also write a reviewed GROUPS sidecar
  # that records the FINAL keeper for every DEL folder after accept/swap, so
  # apply-time verification checks each delete against the REVIEWED keeper, not
  # the original groups TSV. Without this, a swapped keeper (original keeper now
  # being deleted) had no mapping and was moved without verification.
  # Format: size<TAB>keepdir<TAB>deldir (same shape as the original groups TSV).
  local rgroups="$LOGS_DIR/duplicate-folders-groups-reviewed-$stamp.tsv"
  : > "$rgroups"

  {
    printf "# Reviewed folder dedup plan\n"
    printf "# Generated: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Source groups TSV: %s\n" "$GROUPS_TSV"
    [ -n "$PLAN_FILE" ] && printf "# Original raw plan:  %s\n" "$PLAN_FILE"
    printf "#\n"
    printf "# Format: one directory path per line. apply-folder-plan.sh will\n"
    printf "# quarantine each listed directory. All decisions in this file\n"
    printf "# have been explicitly reviewed by a human.\n"
    printf "# Reviewed groups (keeper mapping): %s\n" "$rgroups"
    printf "#\n"
  } > "$out"

  local i
  local n_accept=0 n_skip=0 n_swap=0
  local bytes_accept=0 bytes_swap=0
  local folders_accept=0 folders_swap=0

  for (( i = 0; i < G_COUNT; i++ )); do
    local action="${D_ACTION[$i]:-}"
    [ -z "$action" ] && continue   # quit-early groups; not in plan

    local dels="${G_DELS[$i]}"
    local keep="${G_KEEP[$i]}"
    local ndel
    ndel="$(printf "%s\n" "$dels" | wc -l | tr -d ' ')"

    case "$action" in
      accept)
        n_accept=$((n_accept + 1))
        folders_accept=$((folders_accept + ndel))
        bytes_accept=$((bytes_accept + ${G_BYTES[$i]}))
        while IFS= read -r d; do
          [ -z "$d" ] && continue
          printf "%s\n" "$d" >> "$out"
          # reviewed-groups mapping: del -> original keeper
          printf "%s\t%s\t%s\n" "${G_BYTES[$i]}" "$keep" "$d" >> "$rgroups"
        done <<< "$dels"
        ;;
      skip)
        n_skip=$((n_skip + 1))
        # nothing written
        ;;
      already_done)
        # v1.2.2: DEL folder(s) already gone from disk — nothing to write,
        # counted separately in the summary via SKIPPED_GONE.
        :
        ;;
      swap)
        n_swap=$((n_swap + 1))
        folders_swap=$((folders_swap + ndel))
        bytes_swap=$((bytes_swap + ${G_BYTES[$i]}))
        local swap_to="${D_SWAP_TO[$i]}"
        # Build the new list: every del EXCEPT the chosen one, PLUS the
        # original keeper. The chosen del becomes the implicit new keeper.
        local del_n=0
        local new_keeper=""
        while IFS= read -r d; do
          [ -z "$d" ] && continue
          del_n=$((del_n + 1))
          if [ "$del_n" = "$swap_to" ]; then
            new_keeper="$d"
          fi
        done <<< "$dels"
        # Now write the dels (everything except the new keeper) + original keeper,
        # each mapped to the NEW keeper for apply-time verification.
        del_n=0
        while IFS= read -r d; do
          [ -z "$d" ] && continue
          del_n=$((del_n + 1))
          if [ "$del_n" = "$swap_to" ]; then
            continue   # this is the new keeper; not deleted
          fi
          printf "%s\n" "$d" >> "$out"
          printf "%s\t%s\t%s\n" "${G_BYTES[$i]}" "$new_keeper" "$d" >> "$rgroups"
        done <<< "$dels"
        # original keeper goes into the DEL list, mapped to the new keeper
        printf "%s\n" "$keep" >> "$out"
        printf "%s\t%s\t%s\n" "${G_BYTES[$i]}" "$new_keeper" "$keep" >> "$rgroups"
        ;;
    esac
  done

  # ── summary ────────────────────────────────────────────────────────────────
  echo
  printf "%s─────────────────────────────────────────────────────────────%s\n" "$C_BOLD" "$C_RST"
  printf "%sReview complete%s — %d of %d groups decided\n" "$C_BOLD" "$C_RST" \
    "$((n_accept + n_skip + n_swap))" "$G_COUNT"
  echo
  printf "  Quarantine (accept) : %d groups  (%s, %d folders)\n" \
    "$n_accept" "$(human_bytes "$bytes_accept")" "$folders_accept"
  printf "  Skip                : %d groups  (no action)\n" "$n_skip"
  printf "  Swap keeper         : %d groups  (%s, %d folders)\n" \
    "$n_swap" "$(human_bytes "$bytes_swap")" "$folders_swap"

  # v1.2.2: groups auto-skipped because their DEL folders were already gone
  if [ "$SKIPPED_GONE" -gt 0 ]; then
    printf "  Already applied     : %d groups  (DEL folder no longer present — skipped)\n" "$SKIPPED_GONE"
  fi

  local n_quit=$((G_COUNT - n_accept - n_skip - n_swap - SKIPPED_GONE))
  if [ "$n_quit" -gt 0 ]; then
    printf "  Not reviewed        : %d groups  (quit early)\n" "$n_quit"
  fi
  echo
  ok "Reviewed plan written to:"
  printf "    %s\n" "$out"
  echo

  local total_to_remove=$((folders_accept + folders_swap))
  if [ "$total_to_remove" -eq 0 ]; then
    warn "Plan is empty — nothing will be quarantined when applied."
    warn "Did you mean to accept some groups?"
  else
    info "Apply with launcher option 6, or directly:"
    printf "  %sbin/apply-folder-plan.sh --plan %s%s\n" "$C_DIM" "$out" "$C_RST"
  fi

  # Hand-off prompt
  echo
  printf "Apply this reviewed plan now? [y/N]: "
  read -r apply_now || apply_now="n"
  case "$apply_now" in
    y|Y|yes|YES)
      if [ -x "$ROOT_DIR/bin/apply-folder-plan.sh" ]; then
        echo
        "$ROOT_DIR/bin/apply-folder-plan.sh" --plan "$out"
      else
        err "apply-folder-plan.sh not found or not executable. Apply manually."
      fi
      ;;
    *)
      info "Exiting. Plan saved; apply when ready."
      ;;
  esac
}

# ── go ───────────────────────────────────────────────────────────────────────

info "Loading groups from: $GROUPS_TSV"
load_groups
if [ "$G_COUNT" -eq 0 ]; then
  warn "No groups found in TSV — nothing to review."
  exit 0
fi
info "Loaded $G_COUNT duplicate group(s)."
echo
echo "You will review each group and decide whether to:"
echo "  - accept the proposed keeper and quarantine the duplicates, or"
echo "  - skip the group (leave both/all copies as-is), or"
echo "  - swap the keeper (pick a different copy to keep), or"
echo "  - quit early (save partial decisions)."
echo
printf "Begin review? [Y/n]: "
read -r start || start="y"
case "$start" in
  n|N|no|NO) info "Aborted before review."; exit 0;;
esac

review_loop || true   # don't propagate exit code; we still want to write what we have
write_reviewed_plan
exit 0

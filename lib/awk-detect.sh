# lib/awk-detect.sh — v1.3.19
#
# Detects whether the local awk correctly handles NUL record separators
# (RS='\0' / ORS='\0'). Exports HASHER_AWK_NUL_SAFE=1 when it does, 0 otherwise.
#
# Background: gawk and mawk handle NUL RS/ORS correctly. BusyBox awk (Synology
# DSM, Alpine) processes only the first NUL record and does not preserve the
# NUL output separator — so the v1.3.16–v1.3.18 exclusion filter, delimiter
# skip filter, and housekeeping NUL filters all silently fail on BusyBox.
# Reviewer confirmed this with a four-file hash run producing a header-only CSV.
#
# Public interface:
#   hasher_detect_awk_nul_safety            → sets HASHER_AWK_NUL_SAFE
#   hasher_nul_filter_delim <in> <skiplog>  → splits NUL stream into two:
#       stdout: NUL-delimited paths that DO NOT contain TAB/LF/CR
#       skiplog: newline-delimited paths that were skipped (with <TAB>/<LF>/<CR>
#                markers substituted so the log itself is readable)
#   hasher_nul_filter_globs <in> <pat>...   → NUL-delimited stream on stdout
#       containing only records whose path does NOT match any of the case-
#       insensitive glob patterns supplied (see semantics below).
#
# Glob semantics (unchanged from v1.3.18):
#   * matches any run of characters (including empty)
#   * ? matches exactly one character
#   * a pattern with '/' matches the full path; else matches basename only
#   * a pattern with NO glob metacharacters matches as a case-insensitive
#     literal substring against the FULL PATH (preserves the pre-v1.3.18
#     behaviour of "#recycle" / "@eaDir" catching path components anywhere)
#   * matching is case-insensitive
#
# The awk implementations mirror what v1.3.18 shipped; the bash fallbacks are
# byte-for-byte compatible in output. Callers do not need to know which path
# ran.

# ---------------------------------------------------------------- detection

hasher_detect_awk_nul_safety() {
  # Cache — one detection per shell.
  if [ -n "${HASHER_AWK_NUL_SAFE:-}" ]; then return 0; fi

  # Behavioural test: 3 NUL-delimited records → correct awk sees 3, emits 3
  # NUL-terminated records back. BusyBox awk sees 1 and emits 2 bytes.
  local out
  out=$(printf 'a\0b\0c\0' | awk -v RS='\0' -v ORS='\0' '{print $0}' 2>/dev/null | wc -c)
  # Expected: 6 bytes (3 records × 2 bytes each: single char + NUL terminator).
  if [ "${out:-0}" = "6" ]; then
    HASHER_AWK_NUL_SAFE=1
  else
    HASHER_AWK_NUL_SAFE=0
  fi
  export HASHER_AWK_NUL_SAFE
}

# ------------------------------------------------------------ delimiter skip
# Splits an incoming NUL-delimited stream:
#   - records containing TAB/LF/CR are appended (newline-delimited, with
#     control chars replaced by <TAB>/<LF>/<CR>) to $2 (skiplog).
#   - clean records are emitted NUL-delimited on stdout.

hasher_nul_filter_delim() {
  local in="$1" skiplog="$2"
  hasher_detect_awk_nul_safety
  : > "$skiplog"
  if [ "${HASHER_AWK_NUL_SAFE:-0}" = "1" ]; then
    awk -v RS='\0' -v ORS='\0' -v skip="$skiplog" '
      /[\t\n\r]/ {
        s = $0; gsub(/\t/, "<TAB>", s); gsub(/\n/, "<LF>", s); gsub(/\r/, "<CR>", s)
        printf "%s\n", s >> skip
        next
      }
      { print $0 }
    ' "$in"
  else
    # Bash fallback: read -d '' handles a NUL-delimited stream; bash 3.2+ okay.
    # Case matching against ANY of $'\t\n\r' catches TAB/LF/CR without shelling
    # out per record.
    local _p
    while IFS= read -r -d '' _p; do
      case "$_p" in
        *$'\t'*|*$'\n'*|*$'\r'*)
          # Replace control chars for the skip log
          local _s="$_p"
          _s="${_s//$'\t'/<TAB>}"
          _s="${_s//$'\r'/<CR>}"
          _s="${_s//$'\n'/<LF>}"
          printf '%s\n' "$_s" >> "$skiplog"
          ;;
        *)
          printf '%s\0' "$_p"
          ;;
      esac
    done < "$in"
  fi
}

# ------------------------------------------------------------- glob excludes
# Reads NUL-delimited paths from $1, emits (NUL-delimited) those that DO NOT
# match any of the case-insensitive glob patterns in $2..$N.

hasher_nul_filter_globs() {
  local in="$1"; shift
  hasher_detect_awk_nul_safety
  if [ "$#" -eq 0 ]; then
    cat -- "$in"; return
  fi
  if [ "${HASHER_AWK_NUL_SAFE:-0}" = "1" ]; then
    awk -v RS='\0' -v ORS='\0' -v N="$#" '
      function _glob_to_regex(g,   r, c, i, out) {
        out = ""
        for (i = 1; i <= length(g); i++) {
          c = substr(g, i, 1)
          if      (c == "*") out = out ".*"
          else if (c == "?") out = out "."
          else if (index(".+^$()[]{}|\\", c) > 0) out = out "\\" c
          else out = out c
        }
        return out
      }
      function _basename(p,   n, a) { n = split(p, a, "/"); return a[n] }
      function _matches(path, pattern,   is_path_glob, subject, regex) {
        if (pattern !~ /[*?]/) return index(tolower(path), tolower(pattern)) > 0
        is_path_glob = (index(pattern, "/") > 0)
        subject = is_path_glob ? path : _basename(path)
        regex   = "^" _glob_to_regex(tolower(pattern)) "$"
        return (tolower(subject) ~ regex)
      }
      BEGIN {
        for (i = 1; i <= N; i++) { pat[i] = ARGV[i]; ARGV[i] = "" }
      }
      {
        keep = 1
        for (i = 1; i <= N; i++) if (pat[i] != "" && _matches($0, pat[i])) { keep = 0; break }
        if (keep) print $0
      }
    ' "$@" "$in"
  else
    # Bash fallback: replicate exactly the same semantics using shell string
    # ops and case globs. bash supports [[ $str == $pattern ]] with case
    # insensitivity via shopt -s nocasematch (scoped, restored below).
    local _saved_nocase=0
    if shopt -q nocasematch 2>/dev/null; then _saved_nocase=1; else shopt -s nocasematch; fi
    local _patterns=("$@") _p _pat _has_glob _is_pathscoped _subject _base
    while IFS= read -r -d '' _p; do
      local _keep=1
      for _pat in "${_patterns[@]}"; do
        [ -z "$_pat" ] && continue
        _has_glob=0
        case "$_pat" in *[\*\?]*) _has_glob=1 ;; esac
        if [ "$_has_glob" = "0" ]; then
          # No glob metacharacters → case-insensitive substring against full path
          local _lc_p _lc_pat
          _lc_p=$(printf '%s' "$_p"   | tr '[:upper:]' '[:lower:]')
          _lc_pat=$(printf '%s' "$_pat" | tr '[:upper:]' '[:lower:]')
          case "$_lc_p" in *"$_lc_pat"*) _keep=0; break ;; esac
        else
          _is_pathscoped=0
          case "$_pat" in */*) _is_pathscoped=1 ;; esac
          if [ "$_is_pathscoped" = "1" ]; then
            _subject="$_p"
          else
            _base="${_p##*/}"; _subject="$_base"
          fi
          # bash [[ == pattern ]] uses shell glob syntax which matches our
          # documented semantics (*, ?), and nocasematch is set above.
          if [[ "$_subject" == $_pat ]]; then _keep=0; break; fi
        fi
      done
      [ "$_keep" = "1" ] && printf '%s\0' "$_p"
    done < "$in"
    [ "$_saved_nocase" = "0" ] && shopt -u nocasematch
  fi
}

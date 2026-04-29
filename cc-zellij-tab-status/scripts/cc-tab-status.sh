#!/bin/bash
# Hook Claude Code : suffixe le nom de chaque tab Zellij avec l'état des claude
# qui y tournent. Format par défaut : "myproject ⏐ ● ⚠ ●"
# (● working, ✓ done, ⚠ permission/notif).
#
# Modes :
#   - sans argument : mode hook (lit JSON sur stdin, met à jour le state du pane
#                     courant puis lance un rebuild en arrière-plan).
#   - rebuild       : recompose les noms de tabs depuis les state files.
#
# Configuration via env vars (defaults entre parenthèses) :
#   CC_TAB_STATUS_DIR    (/tmp/cc-tabs)   répertoire racine des state files
#   CC_TAB_STATUS_SEP    (" ⏐ ")          séparateur entre nom de tab et symboles
#   CC_TAB_STATUS_JOIN   (" ")            séparateur entre symboles
#   CC_TAB_STATUS_SYM_W  ("●")            symbole working
#   CC_TAB_STATUS_SYM_D  ("✓")            symbole done
#   CC_TAB_STATUS_SYM_P  ("⚠")            symbole permission/attention
#   CC_TAB_STATUS_LOG    (/tmp/cc-tab-status.log)  fichier de debug

set -u

STATE_DIR="${CC_TAB_STATUS_DIR:-/tmp/cc-tabs}"
SEP="${CC_TAB_STATUS_SEP:- ⏐ }"
JOIN="${CC_TAB_STATUS_JOIN:- }"
SYM_W="${CC_TAB_STATUS_SYM_W:-●}"
SYM_D="${CC_TAB_STATUS_SYM_D:-✓}"
SYM_P="${CC_TAB_STATUS_SYM_P:-⚠}"
LOG="${CC_TAB_STATUS_LOG:-/tmp/cc-tab-status.log}"

ZSESS="${ZELLIJ_SESSION_NAME:-}"
[ -z "$ZSESS" ] && exit 0

SESSION_DIR="$STATE_DIR/$ZSESS"

# ZELLIJ_PANE_ID est exposé sous la forme "0", "1", etc. ; list-panes utilise "terminal_0".
PANE_KEY=""
[ -n "${ZELLIJ_PANE_ID:-}" ] && PANE_KEY="terminal_${ZELLIJ_PANE_ID}"

rebuild() {
    mkdir -p "$SESSION_DIR"

    exec 9>"$SESSION_DIR/.lock"
    flock -w 2 9 || return 0

    declare -A tab_curr     # tab_id -> nom courant
    declare -A tab_orig     # tab_id -> nom sans suffixe
    declare -A pane_to_tab  # pane_id -> tab_id (panes terminaux uniquement)
    declare -A tab_syms     # tab_id -> "●●⚠"

    local panes
    panes=$(zellij action list-panes --all 2>/dev/null)
    local rc=$?
    [ $rc -ne 0 ] && return 0
    [ -z "$panes" ] && return 0
    printf '%s' "$panes" | head -1 | grep -q "TAB_ID" || return 0

    # On ne filtre PAS sur COMMAND="claude" : zellij garde le command capturé au
    # démarrage du pane, donc un pane qui a relancé claude après un quit (ou via
    # claude --resume) reste marqué avec son ancien command. La présence d'un
    # state file dans SESSION_DIR fait foi : il est créé par les hooks Claude.
    local tab_id tab_name pane_id ptype
    while IFS=$'\t' read -r tab_id tab_name pane_id ptype; do
        [ -z "$tab_id" ] && continue
        tab_curr[$tab_id]="$tab_name"
        tab_orig[$tab_id]="${tab_name%%${SEP}*}"
        [ "$ptype" = "terminal" ] && pane_to_tab[$pane_id]="$tab_id"
    done < <(echo "$panes" | awk -F'  ' 'NR>1 {print $1"\t"$3"\t"$4"\t"$5}')

    # Parcours des state files : agrège par tab, GC les panes disparus.
    local f base sym tid
    for f in "$SESSION_DIR"/*; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        [[ "$base" == .* ]] && continue
        tid="${pane_to_tab[$base]:-}"
        if [ -z "$tid" ]; then
            rm -f "$f"
            continue
        fi
        sym="$SYM_W"
        case "$(cat "$f" 2>/dev/null)" in
            D) sym="$SYM_D" ;;
            P) sym="$SYM_P" ;;
        esac
        if [ -n "${tab_syms[$tid]:-}" ]; then
            tab_syms[$tid]="${tab_syms[$tid]}${JOIN}${sym}"
        else
            tab_syms[$tid]="$sym"
        fi
    done

    local new_name
    for tab_id in "${!tab_curr[@]}"; do
        new_name="${tab_orig[$tab_id]}"
        if [ -n "${tab_syms[$tab_id]:-}" ]; then
            new_name="${new_name}${SEP}${tab_syms[$tab_id]}"
        fi
        if [ "${tab_curr[$tab_id]}" != "$new_name" ]; then
            zellij action rename-tab-by-id "$tab_id" "$new_name" 2>/dev/null || true
        fi
    done
}

if [ "${1:-}" = "rebuild" ]; then
    rebuild
    exit 0
fi

[ -z "$PANE_KEY" ] && exit 0

INPUT=$(cat)
HOOK_EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null)
echo "$(date -Iseconds) pane=$PANE_KEY event=${HOOK_EVENT:-EMPTY}" >>"$LOG"
[ -z "$HOOK_EVENT" ] && exit 0

mkdir -p "$SESSION_DIR"

case "$HOOK_EVENT" in
    SessionEnd)
        rm -f "$SESSION_DIR/$PANE_KEY"
        ;;
    Stop)
        printf 'D' > "$SESSION_DIR/$PANE_KEY"
        ;;
    PermissionRequest)
        printf 'P' > "$SESSION_DIR/$PANE_KEY"
        ;;
    Notification)
        # Claude émet souvent une Notification système après Stop (« waiting
        # for input ») : ne pas écraser un état D, qui resterait coincé en P.
        if [ ! -f "$SESSION_DIR/$PANE_KEY" ] || [ "$(cat "$SESSION_DIR/$PANE_KEY" 2>/dev/null)" != "D" ]; then
            printf 'P' > "$SESSION_DIR/$PANE_KEY"
        fi
        ;;
    *)
        printf 'W' > "$SESSION_DIR/$PANE_KEY"
        ;;
esac

# Rebuild en background pour ne pas ralentir Claude
( rebuild >>"$LOG" 2>&1 ) &
disown 2>/dev/null || true
exit 0

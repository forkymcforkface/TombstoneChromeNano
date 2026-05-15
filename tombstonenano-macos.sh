#!/usr/bin/env bash

VERSION='1.0.0'
VERSION_CHECK_URL='https://raw.githubusercontent.com/forkymcforkface/tombstonechromenano/main/tombstonenano-macos.sh'

R=$'\033[0m'; W=$'\033[97m'; CY=$'\033[36m'; DCY=$'\033[2;36m'
GR=$'\033[32m'; YL=$'\033[33m'; RD=$'\033[31m'; GY=$'\033[90m'

if [ "$(id -u)" -ne 0 ]; then
    echo "${CY}Re-launching with sudo...${R}"
    src="$0"
    if [ ! -r "$src" ] || ! grep -q 'TombstoneChromeNano' "$src" 2>/dev/null; then
        src="/tmp/tombstonenano-macos.sh"
        cat /dev/stdin > "$src" 2>/dev/null || curl -fsSL "$VERSION_CHECK_URL" -o "$src" 2>/dev/null
    fi
    exec sudo -E bash "$src" "$@"
fi

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
else
    TARGET_USER=$(stat -f "%Su" /dev/console 2>/dev/null)
fi
[ -z "$TARGET_USER" ] && TARGET_USER="$USER"

TARGET_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[ -z "$TARGET_HOME" ] && TARGET_HOME="/Users/$TARGET_USER"

MODEL_ROOT="$TARGET_HOME/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel"
POLICY_DOMAIN='/Library/Managed Preferences/com.google.Chrome'

write_policy()  { defaults write "$POLICY_DOMAIN" "$1" -int "$2"; }
remove_policy() { defaults delete "$POLICY_DOMAIN" "$1" 2>/dev/null || true; }
get_policy()    { defaults read "$POLICY_DOMAIN" "$1" 2>/dev/null; }

EXTRA_AI_POLICIES=(
    'GenAiDefaultSettings'
    'HelpMeWriteSettings'
    'TabOrganizerSettings'
    'CreateThemesSettings'
    'HistorySearchSettings'
    'DevToolsGenAiSettings'
)

invoke_install() {
    echo
    echo "${W}=== Blocking Gemini Nano AI ===${R}"
    echo

    mkdir -p "$(dirname "$POLICY_DOMAIN")"
    write_policy 'GenAILocalFoundationalModelSettings' 1
    echo "${GR}[OK] Policy set: ${POLICY_DOMAIN}.plist GenAILocalFoundationalModelSettings = 1${R}"

    local deleted=0 freed=0
    if [ -d "$MODEL_ROOT" ]; then
        while IFS= read -r w; do
            [ -z "$w" ] && continue
            local size
            size=$(stat -f "%z" "$w" 2>/dev/null || echo 0)
            if rm -f "$w"; then
                deleted=$((deleted + 1))
                freed=$((freed + size))
                local gb
                gb=$(awk "BEGIN {printf \"%.2f\", $size/1073741824}")
                echo "${GR}[OK] Deleted: $w ($gb GB)${R}"
            fi
        done < <(find "$MODEL_ROOT" -name 'weights.bin' -type f 2>/dev/null)
    fi
    if [ "$deleted" -eq 0 ]; then
        echo "${CY}[INFO] No weights.bin found (already removed or never downloaded).${R}"
    else
        local total
        total=$(awk "BEGIN {printf \"%.2f\", $freed/1073741824}")
        echo "${GR}[OK] Freed $total GB.${R}"
    fi

    if [ -f "$MODEL_ROOT" ] && [ ! -d "$MODEL_ROOT" ]; then
        echo "${CY}[INFO] Permanent lock already in place at $MODEL_ROOT.${R}"
    else
        [ -d "$MODEL_ROOT" ] && rm -rf "$MODEL_ROOT"
        mkdir -p "$(dirname "$MODEL_ROOT")"

        printf '%-1024s' 'TOMBSTONE: blocks Chrome Gemini Nano on-device model. To remove, re-run this script and choose Uninstall.' > "$MODEL_ROOT"
        chown "$TARGET_USER" "$MODEL_ROOT"
        chmod 444 "$MODEL_ROOT"
        chflags uchg "$MODEL_ROOT" 2>/dev/null || true
        chflags schg "$MODEL_ROOT" 2>/dev/null || true

        echo "${GR}[OK] Permanent lock installed at $MODEL_ROOT${R}"
        echo "${GY}     (1 KB read-only file with chflags uchg+schg)${R}"
    fi

    echo
    echo "${YL}Done. Restart Chrome so the policy applies to running processes.${R}"
}

invoke_uninstall() {
    echo
    echo "${W}=== Unblocking Gemini Nano AI ===${R}"
    echo

    if [ -f "$MODEL_ROOT" ] && [ ! -d "$MODEL_ROOT" ]; then
        chflags noschg "$MODEL_ROOT" 2>/dev/null || true
        chflags nouchg "$MODEL_ROOT" 2>/dev/null || true
        chmod 644 "$MODEL_ROOT" 2>/dev/null || true
        if rm -f "$MODEL_ROOT"; then
            echo "${GR}[OK] Permanent lock removed: $MODEL_ROOT${R}"
        else
            echo "${YL}[WARN] Could not remove $MODEL_ROOT${R}"
        fi
    elif [ -d "$MODEL_ROOT" ]; then
        echo "${CY}[INFO] $MODEL_ROOT is a normal folder (no permanent lock to remove).${R}"
    else
        echo "${CY}[INFO] No permanent lock found.${R}"
    fi

    if get_policy 'GenAILocalFoundationalModelSettings' >/dev/null 2>&1; then
        remove_policy 'GenAILocalFoundationalModelSettings'
        echo "${GR}[OK] Policy value removed: GenAILocalFoundationalModelSettings${R}"
    else
        echo "${CY}[INFO] Policy value not present.${R}"
    fi

    echo
    echo "${YL}Done. Restart Chrome -- it will re-download the model the next time it needs it.${R}"
}

invoke_disable_all_ai() {
    echo
    echo "${W}=== Disabling other Chrome AI features ===${R}"
    echo
    for key in "${EXTRA_AI_POLICIES[@]}"; do
        write_policy "$key" 2
        echo "${GR}[OK] Policy set: $key = 2${R}"
    done
    echo
    echo "${YL}Done. Restart Chrome so the policies take effect.${R}"
}

invoke_enable_all_ai() {
    echo
    echo "${W}=== Re-enabling other Chrome AI features ===${R}"
    echo
    for key in "${EXTRA_AI_POLICIES[@]}"; do
        if get_policy "$key" >/dev/null 2>&1; then
            remove_policy "$key"
            echo "${GR}[OK] Removed: $key${R}"
        else
            echo "${CY}[INFO] Not set: $key${R}"
        fi
    done
    echo
    echo "${YL}Done. Restart Chrome.${R}"
}

get_current_status() {
    POLICY_ON='allowed';  POLICY_COLOR=$GY
    TOMB_ON='off';        TOMB_COLOR=$GY
    ALLAI_ON='allowed';   ALLAI_COLOR=$GY
    [ "$(get_policy 'GenAILocalFoundationalModelSettings' 2>/dev/null)" = "1" ] && { POLICY_ON='BLOCKED';  POLICY_COLOR=$GR; }
    { [ -f "$MODEL_ROOT" ] && [ ! -d "$MODEL_ROOT" ]; } && { TOMB_ON='ON';       TOMB_COLOR=$GR; }
    [ "$(get_policy 'GenAiDefaultSettings' 2>/dev/null)" = "2" ]            && { ALLAI_ON='DISABLED'; ALLAI_COLOR=$GR; }
}

UPDATE_CHECKED=0
UPDATE_AVAILABLE=''
get_update_available() {
    [ "$UPDATE_CHECKED" = "1" ] && { echo "$UPDATE_AVAILABLE"; return; }
    UPDATE_CHECKED=1
    local content remote newer
    content=$(curl -fsSL --max-time 3 "$VERSION_CHECK_URL" 2>/dev/null) || { echo ""; return; }
    remote=$(echo "$content" | grep -E "^VERSION=" | head -1 | sed -E "s/VERSION='([^']+)'.*/\1/")
    if [ -n "$remote" ] && [ "$remote" != "$VERSION" ]; then
        newer=$(printf '%s\n%s\n' "$VERSION" "$remote" | sort -V | tail -1)
        [ "$newer" = "$remote" ] && UPDATE_AVAILABLE="$remote"
    fi
    echo "$UPDATE_AVAILABLE"
}

invoke_menu_action() {
    "$1" || echo "${RD}ERROR: action returned non-zero${R}"
    echo
    read -r -p 'Press Enter to return to menu' _
}

show_menu() {
    while :; do
        get_current_status
        clear
        echo
        echo "${W}================================================${R}"
        echo "${W}   TombstoneChromeNano v$VERSION (macOS)${R}"
        echo "${W}================================================${R}"
        printf "%b   by Kev (forkymcforkface)%b  %bhttps://github.com/forkymcforkface%b\n" "$CY" "$R" "$DCY" "$R"
        local newer
        newer=$(get_update_available)
        [ -n "$newer" ] && echo "${YL}   * Update available: v$newer  (re-run the install one-liner to upgrade)${R}"
        echo
        echo "${GY}  TombstoneChromeNano deletes Chrome's 4 GB Gemini Nano AI model,${R}"
        echo "${GY}  disables the Chrome AI setting, and drops a 1 KB \"permanent${R}"
        echo "${GY}  lock\" file in the model's place. The lock prevents Chrome from${R}"
        echo "${GY}  downloading and overwriting it -- even if the AI setting is${R}"
        echo "${GY}  ever turned back on later.${R}"
        echo
        echo "${CY}  User             : $TARGET_USER${R}"
        printf "  Gemini Nano AI   : %b%s%b\n" "$POLICY_COLOR" "$POLICY_ON" "$R"
        printf "  Permanent lock   : %b%s%b\n" "$TOMB_COLOR"   "$TOMB_ON"   "$R"
        printf "  Other AI features: %b%s%b\n" "$ALLAI_COLOR"  "$ALLAI_ON"  "$R"
        echo
        echo "${W}  [1] Block Gemini Nano AI         (frees ~4 GB, installs permanent lock)${R}"
        echo "${W}  [2] Unblock Gemini Nano AI       (let Chrome use it again)${R}"
        echo "${W}  [3] Disable other Chrome AI features (Help me write, etc. - no lock)${R}"
        echo "${W}  [4] Re-enable other Chrome AI features${R}"
        echo "${W}  [Q] Quit${R}"
        echo
        read -r -p 'Choose an option: ' choice
        local up
        up=$(echo "$choice" | tr '[:lower:]' '[:upper:]')
        case "$up" in
            1)   invoke_menu_action invoke_install ;;
            2)   invoke_menu_action invoke_uninstall ;;
            3)   invoke_menu_action invoke_disable_all_ai ;;
            4)   invoke_menu_action invoke_enable_all_ai ;;
            Q|'') return ;;
            *)   echo "${RD}Invalid choice: '$choice'${R}"; sleep 0.8 ;;
        esac
    done
}

show_menu

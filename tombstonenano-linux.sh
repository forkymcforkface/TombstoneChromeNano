#!/usr/bin/env bash
# TombstoneChromeNano (Linux) -- block Chrome's Gemini Nano on-device AI model
# Copyright (c) 2026 Kev (forkymcforkface) -- https://github.com/forkymcforkface
# SPDX-License-Identifier: MIT  (see LICENSE)

VERSION='1.0.0'
VERSION_CHECK_URL='https://raw.githubusercontent.com/forkymcforkface/tombstonechromenano/main/tombstonenano-linux.sh'

# --- Colors (ANSI) ---
R=$'\033[0m'; W=$'\033[97m'; CY=$'\033[36m'; DCY=$'\033[2;36m'
GR=$'\033[32m'; YL=$'\033[33m'; RD=$'\033[31m'; GY=$'\033[90m'

# --- Self-elevate via sudo if not root ---
if [ "$(id -u)" -ne 0 ]; then
    echo "${CY}Re-launching with sudo...${R}"
    src="$0"
    if [ ! -r "$src" ] || ! grep -q 'TombstoneChromeNano' "$src" 2>/dev/null; then
        src="/tmp/tombstonenano-linux.sh"
        cat /dev/stdin > "$src" 2>/dev/null || curl -fsSL "$VERSION_CHECK_URL" -o "$src" 2>/dev/null
    fi
    exec sudo -E bash "$src" "$@"
fi

# --- Detect ChromeOS (Chromebook Plus is the only variant that ships Nano) ---
PLATFORM='Linux'
IS_CHROMEOS=0
if [ -f /etc/lsb-release ] && grep -q '^CHROMEOS_RELEASE_BOARD=' /etc/lsb-release 2>/dev/null; then
    IS_CHROMEOS=1
    PLATFORM='ChromeOS'
fi

# --- Resolve target user + paths ---
if [ "$IS_CHROMEOS" = "1" ]; then
    # ChromeOS browser data lives under /home/chronos/user (the mounted encrypted home).
    # Run this from crosh (Ctrl+Alt+T -> shell) in developer mode.
    TARGET_USER='chronos'
    TARGET_HOME='/home/chronos/user'
    MODEL_ROOT="$TARGET_HOME/OptGuideOnDeviceModel"
else
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        TARGET_USER="$SUDO_USER"
    else
        TARGET_USER=$(who 2>/dev/null | awk '$2 ~ /tty[0-9]|:[0-9]/ {print $1; exit}')
    fi
    [ -z "$TARGET_USER" ] && TARGET_USER="$USER"
    TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)
    [ -z "$TARGET_HOME" ] && TARGET_HOME="/home/$TARGET_USER"
    MODEL_ROOT="$TARGET_HOME/.config/google-chrome/OptGuideOnDeviceModel"
fi

POLICY_DIR='/etc/opt/chrome/policies/managed'
POLICY_FILE_MAIN="$POLICY_DIR/tombstonechromenano-foundational.json"
POLICY_FILE_AI="$POLICY_DIR/tombstonechromenano-allai.json"

# chattr may be unavailable (busybox) or unsupported (tmpfs, some btrfs configs)
HAS_CHATTR=0
command -v chattr >/dev/null 2>&1 && HAS_CHATTR=1

# ---------------------------------------------------------------------------
# INSTALL
# ---------------------------------------------------------------------------
invoke_install() {
    echo
    echo "${W}=== Blocking Gemini Nano AI ===${R}"
    echo

    # 1. JSON policy (rootfs may be read-only on stock ChromeOS)
    if mkdir -p "$POLICY_DIR" 2>/dev/null && cat > "$POLICY_FILE_MAIN" 2>/dev/null <<'EOF'
{
  "GenAILocalFoundationalModelSettings": 1
}
EOF
    then
        echo "${GR}[OK] Policy file written: $POLICY_FILE_MAIN${R}"
    else
        echo "${YL}[WARN] Could not write $POLICY_FILE_MAIN (rootfs read-only?). Lock file alone will still block re-download.${R}"
    fi

    # 2. Delete any weights.bin
    local deleted=0 freed=0
    if [ -d "$MODEL_ROOT" ]; then
        while IFS= read -r w; do
            [ -z "$w" ] && continue
            local size
            size=$(stat -c "%s" "$w" 2>/dev/null || echo 0)
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

    # 3. Permanent lock
    if [ -f "$MODEL_ROOT" ] && [ ! -d "$MODEL_ROOT" ]; then
        echo "${CY}[INFO] Permanent lock already in place at $MODEL_ROOT.${R}"
    else
        # Clear any stale immutable flag before deleting
        [ "$HAS_CHATTR" = "1" ] && chattr -i "$MODEL_ROOT" 2>/dev/null || true
        [ -d "$MODEL_ROOT" ] && rm -rf "$MODEL_ROOT"
        mkdir -p "$(dirname "$MODEL_ROOT")"

        # 1 KB payload: note text, right-padded with spaces to exactly 1024 bytes
        printf '%-1024s' 'TOMBSTONE: blocks Chrome Gemini Nano on-device model. To remove, re-run this script and choose Uninstall.' > "$MODEL_ROOT"
        chown "$TARGET_USER:$TARGET_USER" "$MODEL_ROOT" 2>/dev/null || chown "$TARGET_USER" "$MODEL_ROOT"
        chmod 444 "$MODEL_ROOT"

        local locked=0
        if [ "$HAS_CHATTR" = "1" ] && chattr +i "$MODEL_ROOT" 2>/dev/null; then
            locked=1
        fi

        echo "${GR}[OK] Permanent lock installed at $MODEL_ROOT${R}"
        if [ "$locked" = "1" ]; then
            echo "${GY}     (1 KB read-only file with chattr +i)${R}"
        else
            echo "${YL}     chattr +i unavailable or unsupported on this filesystem --${R}"
            echo "${YL}     lock degraded to read-only (chmod 444). Still blocks naive overwrite.${R}"
        fi
    fi

    echo
    echo "${YL}Done. Restart Chrome so the policy applies to running processes.${R}"
}

# ---------------------------------------------------------------------------
# UNINSTALL
# ---------------------------------------------------------------------------
invoke_uninstall() {
    echo
    echo "${W}=== Unblocking Gemini Nano AI ===${R}"
    echo

    # 1. Remove permanent lock if present
    if [ -f "$MODEL_ROOT" ] && [ ! -d "$MODEL_ROOT" ]; then
        [ "$HAS_CHATTR" = "1" ] && chattr -i "$MODEL_ROOT" 2>/dev/null || true
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

    # 2. Remove policy file
    if [ -f "$POLICY_FILE_MAIN" ]; then
        rm -f "$POLICY_FILE_MAIN"
        echo "${GR}[OK] Policy file removed: $POLICY_FILE_MAIN${R}"
    else
        echo "${CY}[INFO] Policy file not present.${R}"
    fi

    echo
    echo "${YL}Done. Restart Chrome -- it will re-download the model the next time it needs it.${R}"
}

# ---------------------------------------------------------------------------
# DISABLE / RE-ENABLE all other AI features
# ---------------------------------------------------------------------------
invoke_disable_all_ai() {
    echo
    echo "${W}=== Disabling other Chrome AI features ===${R}"
    echo
    mkdir -p "$POLICY_DIR"
    cat > "$POLICY_FILE_AI" <<'EOF'
{
  "GenAiDefaultSettings": 2,
  "HelpMeWriteSettings": 2,
  "TabOrganizerSettings": 2,
  "CreateThemesSettings": 2,
  "HistorySearchSettings": 2,
  "DevToolsGenAiSettings": 2
}
EOF
    echo "${GR}[OK] Policy file written: $POLICY_FILE_AI${R}"
    echo
    echo "${YL}Done. Restart Chrome so the policies take effect.${R}"
}

invoke_enable_all_ai() {
    echo
    echo "${W}=== Re-enabling other Chrome AI features ===${R}"
    echo
    if [ -f "$POLICY_FILE_AI" ]; then
        rm -f "$POLICY_FILE_AI"
        echo "${GR}[OK] Policy file removed: $POLICY_FILE_AI${R}"
    else
        echo "${CY}[INFO] Policy file not present.${R}"
    fi
    echo
    echo "${YL}Done. Restart Chrome.${R}"
}

# ---------------------------------------------------------------------------
# STATUS
# ---------------------------------------------------------------------------
get_current_status() {
    POLICY_ON='allowed'; POLICY_COLOR=$GY
    TOMB_ON='off';       TOMB_COLOR=$GY
    ALLAI_ON='allowed';  ALLAI_COLOR=$GY
    if [ -f "$POLICY_FILE_MAIN" ] && grep -q '"GenAILocalFoundationalModelSettings"[[:space:]]*:[[:space:]]*1' "$POLICY_FILE_MAIN" 2>/dev/null; then
        POLICY_ON='BLOCKED'; POLICY_COLOR=$GR
    fi
    if [ -f "$MODEL_ROOT" ] && [ ! -d "$MODEL_ROOT" ]; then
        TOMB_ON='ON'; TOMB_COLOR=$GR
    fi
    if [ -f "$POLICY_FILE_AI" ] && grep -q '"GenAiDefaultSettings"[[:space:]]*:[[:space:]]*2' "$POLICY_FILE_AI" 2>/dev/null; then
        ALLAI_ON='DISABLED'; ALLAI_COLOR=$GR
    fi
}

# ---------------------------------------------------------------------------
# UPDATE CHECK (cached once per session, 3s timeout)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# MENU
# ---------------------------------------------------------------------------
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
        echo "${W}   TombstoneChromeNano v$VERSION ($PLATFORM)${R}"
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

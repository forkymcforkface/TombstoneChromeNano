# TombstoneChromeNano

TombstoneChromeNano allows you to
- Easily delete Chrome's 4 GB Gemini Nano AI model, and disable the Chrome AI setting.
- Create a 1 KB "permanent lock" file in the model's place, preventing Chrome from downloading and overwriting it even if the AI setting is ever turned back on later.
- Disable/Enable all other AI features within Chrome.

---

## Quick install

### Windows

**Open PowerShell.** Press `Win + R` to open the Run dialog, type `powershell`, and hit **Enter**. (Or press the **Windows key**, search "PowerShell," click the top result.) You don't need to "Run as Administrator" — the script will ask for admin itself.

**Paste this and press Enter:**

```powershell
irm https://raw.githubusercontent.com/forkymcforkface/tombstonechromenano/main/tombstonenano-windows.ps1 | iex
```

A **User Account Control** prompt will appear — click **Yes**. A new elevated PowerShell window opens with the menu. Pick **[1]** to free ~4 GB.

> **If you get a red "running scripts is disabled" error**, your execution policy blocks unsigned scripts. Press `Win + R`, type `cmd`, hit **Enter**, then paste this instead:
> ```
> powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/forkymcforkface/tombstonechromenano/main/tombstonenano-windows.ps1 | iex"
> ```

### macOS

**Open Terminal.** Press `Cmd + Space` to open Spotlight, type `Terminal`, and hit **Return**. (Or open Finder → Applications → Utilities → Terminal.)

**Paste this and press Return:**

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/forkymcforkface/tombstonechromenano/main/tombstonenano-macos.sh)
```

When prompted, type your Mac login password and press **Return** (the characters won't show as you type — that's normal). The menu appears. Pick **[1]** to free ~4 GB.

### Linux · Terminal

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/forkymcforkface/tombstonechromenano/main/tombstonenano-linux.sh)
```

### ChromeOS · Crosh shell (developer mode required)

Same script as Linux. Open **Crosh** (`Ctrl+Alt+T`) → type `shell` → run:

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/forkymcforkface/tombstonechromenano/main/tombstonenano-linux.sh)
```

It auto-detects ChromeOS and switches paths. On stock ChromeOS the policy file may not write (read-only rootfs) — the permanent lock still works on its own.

---

## Menu

| Option | What it does |
|---|---|
| **[1] Block Gemini Nano AI** | Sets the Chrome policy, deletes the 4 GB `weights.bin`, and replaces the model folder with a 1 KB locked file. |
| **[2] Unblock Gemini Nano AI** | Removes the lock and the policy. Chrome will re-download the model on next launch. |
| **[3] Disable other Chrome AI features** | Disables Help me write, Tab Organizer, Theme generation, History search, DevTools GenAI. No lock file. |
| **[4] Re-enable other Chrome AI features** | Reverses [3]. |

[1]/[2] and [3]/[4] are independent — run any combination.

---

## Why permlock

Three layers, each can fail on its own:

- **Just delete `weights.bin`** — Chrome silently re-downloads it on the next launch.
- **Just set the policy** — any admin (or a future Chrome update) can flip it back.
- **TombstoneChromeNano does both**, *and* replaces the model folder with a 1 KB file Chrome can't overwrite, delete, or turn back into a folder.

That last layer is the durable one. Even if the registry is wiped or the policy is reverted, the lock file is still sitting there and Chrome can't make a new directory called `OptGuideOnDeviceModel` because the path is already in use.

| Platform | Lock mechanism |
|---|---|
| Windows | Read-only attribute + `DENY (Write, Delete)` ACL on the user's SID |
| macOS | `chflags uchg` + `chflags schg` (user + system immutable) |
| Linux / ChromeOS | `chattr +i` (ext-family filesystem required) |

---

## FAQ

**Will this break Chrome?**
No. The on-device AI features just stop working. Browsing, extensions, sync, bookmarks, profiles — all unaffected.

**Will Chrome say "Managed by your organization" after this?**
Yes — that note appears any time an enterprise policy is set on your machine, even one you set yourself. It's harmless and goes away when you run **[2]**.

**Can I undo it?**
Yes. Re-run the script and pick **[2]** (and **[4]** if you used **[3]**). Or follow [Manual uninstall](#manual-uninstall) below.

**Does this affect Edge, Brave, Opera, Vivaldi?**
No, only Google Chrome.

**Does this disable cloud AI features too?**
Option **[1]** only kills the on-device model. Cloud-backed "Help me write," AI Mode, and similar still work. Use **[3]** for the broader sweep.

**Is it safe? Could it touch any other files?**
The script only looks inside the `OptGuideOnDeviceModel/` folder for files named exactly `weights.bin`. Other files on your disk — including any unrelated `weights.bin` are not in scope.

**I have multiple Chrome profiles. Do I need to run it for each one?**
No. `OptGuideOnDeviceModel` lives at the User Data level and is shared by every Chrome profile. One run covers them all.

**What about multiple Windows / macOS users on the same machine?**
The Chrome policy applies machine-wide automatically. The file deletion and lock target the interactive console user (the person physically logged in) — not whoever entered admin credentials. For other users, run the script while logged in as them.

**Does Chrome verify the model's signature? Could it reject the lock?**
Chrome verifies the *download* via CRX-3 signatures when the component updater fetches the model. Once on disk, it doesn't appear to re-check, which is why the lock works. If that ever changes, raise an issue.

---

## Where things live

| Platform | Chrome policy | Model folder |
|---|---|---|
| Windows | `HKLM\SOFTWARE\Policies\Google\Chrome` | `%LOCALAPPDATA%\Google\Chrome\User Data\OptGuideOnDeviceModel` |
| macOS | `/Library/Managed Preferences/com.google.Chrome.plist` | `~/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel` |
| Linux | `/etc/opt/chrome/policies/managed/tombstonechromenano-*.json` | `~/.config/google-chrome/OptGuideOnDeviceModel` |
| ChromeOS | same as Linux (if rootfs writable) | `/home/chronos/user/OptGuideOnDeviceModel` |

---

## Requirements

- **Windows** 10 / 11 — PowerShell 5.1+, admin (auto-elevates via UAC).
- **macOS** 10.15+ — bash, root (auto-elevates via `sudo`).
- **Linux** — Chrome via deb/rpm, bash, root. Ext filesystem recommended.
- **ChromeOS** — Chromebook Plus, developer mode enabled, Crosh shell.

---

## Known limitations

- **Linux snap / flatpak Chromium** — different sandboxed paths, not handled.
- **Non-ext filesystems** — `chattr +i` may fail; the lock degrades to `chmod 444`-only.
- **MDM / managed devices** — your admin's cloud policy can override the local one. The lock still applies.

---

## Manual uninstall

Run the script and pick **[2]**. If you can't run the script:

### Windows
```powershell
$p = "$env:LOCALAPPDATA\Google\Chrome\User Data\OptGuideOnDeviceModel"
takeown /F $p; icacls $p /reset; Remove-Item $p
reg delete "HKLM\SOFTWARE\Policies\Google\Chrome" /v GenAILocalFoundationalModelSettings /f
```

### macOS
```bash
p="$HOME/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel"
sudo chflags noschg "$p"; sudo chflags nouchg "$p"; sudo rm "$p"
sudo defaults delete '/Library/Managed Preferences/com.google.Chrome' GenAILocalFoundationalModelSettings
```

### Linux / ChromeOS
```bash
# Linux:    p="$HOME/.config/google-chrome/OptGuideOnDeviceModel"
# ChromeOS: p="/home/chronos/user/OptGuideOnDeviceModel"
sudo chattr -i "$p"; sudo rm "$p"
sudo rm /etc/opt/chrome/policies/managed/tombstonechromenano-foundational.json
```

---

## License

MIT — see [LICENSE](./LICENSE).

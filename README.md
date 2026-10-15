# devnet-agent-releases

The downloads for **devnet-agent**, the small program that puts a machine on Orca-DevNet's Board. This
repository holds **only** release binaries (with `SHA256SUMS`) and the two install scripts. It has no source code and
no secrets; the source is private.

You do not need to be here unless an Orca-DevNet admin sent you a **join code**. If they did, run **one line** on the
machine you are adding.

## Windows (PowerShell)

```
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Orca-DevNet/devnet-agent-releases/main/install.ps1))) -Code <your join code>"
```

## Linux or macOS (a terminal)

```
curl -fsSL https://raw.githubusercontent.com/Orca-DevNet/devnet-agent-releases/main/install.sh | sh -s -- <your join code>
```

## What the line does

1. Checks **git** is installed and offers to install it (the agent needs git and nothing else; it does not need `gh`).
2. Downloads the agent for your OS and CPU from the latest release here, **checks that `SHA256SUMS.sig` is a
   signature of `SHA256SUMS` by one of the DevNet admins' keys listed in the script** (it uses `ssh-keygen`, the
   OpenSSH client that comes with Windows 10/11, macOS and most Linux), and **checks the agent's SHA256 against
   `SHA256SUMS`**. If the signature is missing or not by a listed key, or the hashes do not match, it stops and
   installs nothing.
3. Runs `devnet-agent join`, which trades your join code for **this machine's own key** and writes its config.
4. Installs a logon task (Windows), a systemd user service (Linux) or a launch agent (macOS) that starts the agent
   when you log in. The agent only **reports in** (the Board shows the machine online and what it has: git, a
   GPU, AI command-line tools if you have them). **It takes jobs within your plans' budgets (60% of a 5-hour window, 70% of a week) until you pause it.**

5. Installs the **tray icon** (`devnet-tray`) the same way, with the same checksum check, and starts it at login:
   a Startup shortcut (Windows), a launch agent (macOS) or an autostart entry (Linux). It is a dot that is green
   when all is well; it turns into a red X (something failed), a ! (something needs you) or a green tick (a vote on
   the Board is waiting), and its menu has pause, resume, usage and game mode. If a release has no tray for your
   system, or its checksum does not match, the icon is skipped and the agent is still installed. To skip it on
   purpose: add `-NoTray` (Windows) or `--no-tray` (Linux, macOS). On Linux a desktop with no tray (plain GNOME)
   needs the AppIndicator extension; `devnet-agent status` shows the same facts anywhere.

Everything goes in one folder of yours (`%USERPROFILE%\devnet-agent` or `~/devnet-agent`). No administrator rights,
nothing added to your PATH, and your own Tailscale (if you have one) is not touched: the agent carries a small
private node of its own, only for talking to the Board.

Read the scripts before you run them: [`install.ps1`](install.ps1), [`install.sh`](install.sh). They are short.

## Your join code

It is a credential. It works **once** and **expires**; send it to nobody. If it fails ("not valid"), it was used or has
expired: ask the admin for a new one.

## Files in a release

| file | what |
|---|---|
| `devnet-agent-windows-amd64.exe` | Windows, 64-bit |
| `devnet-agent-linux-amd64`, `devnet-agent-linux-arm64` | Linux |
| `devnet-agent-darwin-arm64`, `devnet-agent-darwin-amd64` | macOS (Apple silicon, Intel) |
| `devnet-tray-windows-amd64.exe`, `devnet-tray-linux-<cpu>`, `devnet-tray-darwin-<cpu>` | the tray icon, where built |
| `SHA256SUMS` | the SHA256 of each file above, to check a download |
| `SHA256SUMS.sig` | an admin's SSH signature of `SHA256SUMS` (namespace `devnet-release`); the keys that count are listed in the install scripts |

To check one by hand: `sha256sum -c SHA256SUMS --ignore-missing` (Linux), `shasum -a 256 -c SHA256SUMS --ignore-missing`
(macOS), or `(Get-FileHash <file> -Algorithm SHA256).Hash` and compare (Windows). The binaries are not code-signed
yet, so Windows may ask you to confirm the first run if you download one by hand (the install line does not).

## Removing it

`devnet-agent --config <the config> service uninstall`, then delete the folder. Ask an admin to remove the machine from
the Board (Admin, Machines) if it is not coming back.

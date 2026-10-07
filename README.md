# devnet-agent-releases

The downloads for **devnet-agent**, the small program that puts a machine on Orca-DevNet's Whiteboard. This
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
2. Downloads the agent for your OS and CPU from the latest release here, and **checks its SHA256 against
   `SHA256SUMS`**. If they do not match it stops and installs nothing.
3. Runs `devnet-agent join`, which trades your join code for **this machine's own key** and writes its config.
4. Installs a logon task (Windows), a systemd user service (Linux) or a launch agent (macOS) that starts the agent
   when you log in. The agent only **reports in** (the Whiteboard shows the machine online and what it has: git, a
   GPU, AI command-line tools if you have them). **It does no jobs until you turn them on.**

Everything goes in one folder of yours (`%USERPROFILE%\devnet-agent` or `~/devnet-agent`). No administrator rights,
nothing added to your PATH, and your own Tailscale (if you have one) is not touched: the agent carries a small
private node of its own, only for talking to the Whiteboard.

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
| `SHA256SUMS` | the SHA256 of each file above, to check a download |

To check one by hand: `sha256sum -c SHA256SUMS --ignore-missing` (Linux), `shasum -a 256 -c SHA256SUMS --ignore-missing`
(macOS), or `(Get-FileHash <file> -Algorithm SHA256).Hash` and compare (Windows). The binaries are not code-signed
yet, so Windows may ask you to confirm the first run if you download one by hand (the install line does not).

## Removing it

`devnet-agent --config <the config> service uninstall`, then delete the folder. Ask an admin to remove the machine from
the Whiteboard (Admin, Machines) if it is not coming back.

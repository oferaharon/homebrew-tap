# homebrew-tap

A Homebrew tap holding one formula: **`foreman-panel`**, the local web panel for every
Claude Code session on a Mac. The project itself lives at
[oferaharon/foreman](https://github.com/oferaharon/foreman).

```
brew install oferaharon/tap/foreman-panel
foreman-panel install-hook
brew services start foreman-panel
```

then open <http://127.0.0.1:48770>.

---

## It does not install yet, and that is on purpose

`Formula/foreman-panel.rb` carries a **placeholder `url` and `sha256`**:

```ruby
url "https://github.com/oferaharon/foreman/archive/refs/tags/vX.Y.Z.tar.gz"
version "0.0.0-unreleased"
sha256 "0000000000000000000000000000000000000000000000000000000000000000"
```

No published tag of the panel contains the `foreman-panel` command yet — the `bin` field
that creates it landed after the last tag was cut. A formula pointing at that tag would
install a package with no command, and `bin.install_symlink` would link nothing. So the
two fields say `vX.Y.Z` rather than a real tag, and the checksum is not a checksum at all:
an install attempt fails on a URL that reads as a placeholder, which is the clearest
possible statement of the situation.

They are filled in by [the release ritual](#bumping-the-formula-after-a-release), once,
after the first release containing the command is cut. Everything else in the formula is
finished and has been proven by a local build — see
[Proving a change](#proving-a-change-without-touching-a-running-panel).

---

## What the formula does

`npm install` into `libexec` with Homebrew's standard node arguments, then symlink the
package's own `bin/` entry into the prefix. The background job is a `service do` block,
so `brew services` generates and manages the launchd plist.

Three lines in it are load-bearing. Each one has a comment in the file saying why, and
none of them is a preference:

**`keep_alive successful_exit: false`.** The panel probes `127.0.0.1:<port>` before it
listens and exits **0** when something already answers there — because two Node servers
*can* both bind one port on macOS, silently, and then split traffic by interface. Only
`SuccessfulExit: false` makes launchd read that exit as "I deliberately declined to
start". Written `keep_alive true`, a brew service started beside an already-running panel
becomes a restart loop at the throttle interval, with nothing on screen saying so.

**`environment_variables` supplies `PATH` and `FOREMAN_LOG_DIR`, and nothing else.** Never
a host: the panel binds loopback by default and is widened only by the machine's own
record (`bindHost` in its state directory's `config.json`), so a formula that put a host
here would ship one stranger's decision to everyone who installed it. A `service do` block
is evaluated when the plist is generated, outside all of the panel's own resolution rules,
and must not become a second copy of them in another language in another repository.

**`log_path` names `foreman.log`, not `foreman-panel.log`.** `FOREMAN_LOG_DIR` moves the
*directory*; the two basenames stay derived from the panel's launchd-label constant, which
under Homebrew is untouched and therefore its default. So the process computes
`<dir>/foreman.log` and `<dir>/foreman-error.log`. Named after the formula instead,
launchd would append to one pair while the panel's boot-time rotation trimmed a different,
empty pair — the files that are really written would grow without bound, which is exactly
the bug that rotation exists to prevent. This was found by installing the service and
reading its log: the boot block printed one path into a file at the other.

---

## Bumping the formula after a release

**The formula bump comes after the release is published, never before it.** The checksum
is taken over the tarball GitHub generates *for the tag*, whose bytes are stable once the
tag exists. A formula bumped first points at a 404, which Homebrew reports as a download
failure with no hint that the release simply is not out yet.

```sh
URL=https://github.com/oferaharon/foreman/archive/refs/tags/vX.Y.Z.tar.gz
curl -fsSL "$URL" | shasum -a 256
```

Then in `Formula/foreman-panel.rb`:

1. `url` → that URL, with the real tag.
2. `sha256` → the value printed above. Never a value that was not computed from the
   published tarball.
3. **Delete the `version` line.** It exists only because `vX.Y.Z` is not a parseable
   version; a real tag gives Homebrew the version for free, and leaving an explicit one
   behind would pin the formula to a number the URL contradicts.
4. Delete the placeholder comment block above `url`, and this section's warning from the
   README.

Commit to the tap's default branch with the message `foreman-panel X.Y.Z`, then verify:

```sh
brew update && brew upgrade foreman-panel && brew services restart foreman-panel
```

`brew fetch --build-from-source oferaharon/tap/foreman-panel` prints the same checksum and
is the cross-check.

The project's own release ritual — one small "release vX.Y.Z" PR bumping `package.json`,
merged, then tagged — is in that repository's contributor docs. The tag must always match
`package.json`, which is what makes the formula's `test do` block (`foreman-panel version`
matching the formula's version) meaningful rather than circular.

---

## Proving a change without touching a running panel

Anyone working on this formula is likely to be running the panel already, out of a
checkout, on port 48770. A test install must not touch it. Homebrew's own per-service
environment override is the isolation; there is no scratch service *name*, so it has to
come from the environment file.

**Homebrew 6.0.20+ rejects a formula that is not in a tap** — `brew install
--build-from-source ./Formula/foreman-panel.rb` fails with *"Homebrew requires formulae to
be in a tap"*. So the proof runs through a scratch tap, which also keeps the real
`oferaharon/tap` name free while you experiment.

### 1. A scratch tap, and a tarball of the branch you are testing

```sh
TAP="$(brew --repository)/Library/Taps/foreman-scratch/homebrew-local"
mkdir -p "$TAP/Formula" && git -C "$TAP" init -q

# In a checkout of the panel, on the commit you want to prove:
git archive --format=tar.gz --prefix=foreman-panel-0.1.0/ -o /tmp/foreman-panel-0.1.0.tar.gz HEAD
shasum -a 256 /tmp/foreman-panel-0.1.0.tar.gz
```

Copy `Formula/foreman-panel.rb` into `$TAP/Formula/`, and change **only** `url` (to
`file:///tmp/foreman-panel-0.1.0.tar.gz`) and `sha256` (to the value just printed), and
delete the placeholder `version` line — the version then comes from the tarball's own
filename. `diff` the two files afterwards and confirm nothing else moved; every other line
you are about to prove is the line that will ship.

### 2. The isolation, before anything starts

```sh
mkdir -p "${HOMEBREW_USER_CONFIG_HOME:-$HOME/.homebrew}/services"
cat > "${HOMEBREW_USER_CONFIG_HOME:-$HOME/.homebrew}/services/foreman-panel.env" <<'EOF'
FOREMAN_PORT=48771
FOREMAN_STATE_DIR=/tmp/foreman-scratch
EOF
chmod 600 "${HOMEBREW_USER_CONFIG_HOME:-$HOME/.homebrew}/services/foreman-panel.env"
```

Three things about that file, all of which fail quietly if you get them wrong:

- **Mode 600 is not tidiness.** Homebrew skips the file entirely if it is group- or
  world-writable, and says so only as a warning that scrolls past — which looks exactly
  like the overrides not applying.
- **It needs Homebrew 6.0.15 or newer.** Per-service environment overrides landed in that
  release; on anything older there is no supported way to move the port at all.
- **Do not put `FOREMAN_LOG_DIR` in it.** The `.env` overrides the *environment*, not the
  plist's `StandardOutPath`, so setting it there splits the two apart: launchd writes one
  pair of files and the panel's rotation trims another. The formula already sets it, to
  the directory it also tells launchd to write into. (For a scratch run this split is
  harmless — both halves land somewhere disposable — but it hides the one agreement worth
  checking, so leave it out and check it instead.)

Before starting anything, confirm the override was read and that the log directory is the
formula's own:

```sh
brew info foreman-scratch/local/foreman-panel | grep -A1 'you can just run'
```

That line is generated from the same resolution the plist is, and it should name
`FOREMAN_LOG_DIR="<brew prefix>/var/log"` alongside your two overrides.

### 3. Install, start, and check

```sh
brew install --build-from-source foreman-scratch/local/foreman-panel
brew services start foreman-panel
```

What to check, and what each check is for:

| check | what it proves |
| --- | --- |
| `plutil -p ~/Library/LaunchAgents/homebrew.mxcl.foreman-panel.plist` | `KeepAlive => {SuccessfulExit => false}` is present. Read it; do not assume it. |
| same output: `StandardOutPath` / `StandardErrorPath` | they end in `foreman.log` / `foreman-error.log` — the names the panel itself computes. |
| `FOREMAN_LOG_DIR=<brew prefix>/var/log foreman-panel logs` | prints those same two paths. The plist and the process agree. |
| `lsof -iTCP:48771 -sTCP:LISTEN` | one row, bound to `127.0.0.1` — the default is loopback and the formula did not widen it. |
| `lsof -iTCP:48770 -sTCP:LISTEN` | still **exactly one** row, the panel you were already running. |
| `curl -s 127.0.0.1:48771/api/config` | answers, and names the scratch state directory. |
| `/tmp/foreman-scratch/config.json` | was seeded at boot. |
| `shasum -a 256 ~/Library/Logs/foreman*.log` before and after | byte-identical. The real panel's logs were never opened. |
| `brew test foreman-scratch/local/foreman-panel` | the formula's own test block passes. |
| `brew audit --new --strict foreman-scratch/local/foreman-panel` | clean. |

`foreman-panel logs` run from a plain shell prints the *default* paths, not the service's —
the service's environment reaches the service, not your terminal. That is why the check
above sets `FOREMAN_LOG_DIR` explicitly, and why `brew services info foreman-panel --json`
is the other way to ask.

### 4. The stand-down, which is what `keep_alive` is there for

Worth doing once, because it is the single most important line in the file. Stop the
service, remove `FOREMAN_PORT` from the `.env` so the scratch service targets the port your
real panel is already on, and start it:

```sh
brew services stop foreman-panel
# edit the .env: leave FOREMAN_STATE_DIR, drop FOREMAN_PORT
brew services start foreman-panel
sleep 4
lsof -iTCP:48770 -sTCP:LISTEN          # still exactly one row
launchctl list | grep foreman-panel     # no PID, last exit status 0
cat "$(brew --prefix)/var/log/foreman-error.log"
```

The panel finds the port answering, prints why it is standing down, and exits 0; launchd
records the 0 and **does not restart it**. With `keep_alive true` the same run would loop
every ten seconds forever.

### 5. Teardown, which is not optional

```sh
brew services stop foreman-panel
brew uninstall foreman-panel
rm -f "${HOMEBREW_USER_CONFIG_HOME:-$HOME/.homebrew}/services/foreman-panel.env"
rm -rf /tmp/foreman-scratch /tmp/foreman-panel-0.1.0.tar.gz
rm -f "$(brew --prefix)"/var/log/foreman.log "$(brew --prefix)"/var/log/foreman-error.log
rm -rf "$(brew --repository)/Library/Taps/foreman-scratch"
```

An `.env` file left behind silently rewrites a *real* later `brew services start`, which
is the one piece of this that would go wrong quietly and much later. `brew services stop`
removes the generated plist; confirm it is gone.

### What this procedure cannot prove

It runs on a machine that already has a checkout of the panel, Node and tmux. It cannot
show that `brew install oferaharon/tap/foreman-panel` works from the published tap with no
checkout anywhere, that a first `foreman-panel install-hook` writes a usable Claude Code
settings file where none existed, or that the service comes back after a real reboot (a
LaunchAgent runs at *login*, not at boot). A second user account on the same Mac covers the
first two cheaply; the third wants a real log-out and back in.

---

## Automating the formula bump: considered, declined

The obvious idea is a GitHub Action here that watches the panel repository's releases and
opens a PR bumping `url` and `sha256`. It is written down as declined so the next person
does not rediscover it and assume nobody thought of it.

It needs a token with write access to this repository — a repository secret to send a
dispatch, or a fine-grained PAT to open the PR. That would be the first stored credential
in a system whose whole design is that it holds none: the panel makes no network call and
holds no forge credential, by standing ruling. Releases are cut when there is something
worth announcing, not weekly, and the manual bump is two commands at that cadence.

`brew bump-formula-pr` is the third option and is not the route either: it is built for
homebrew-core's workflow and wants a GitHub token of its own, which is more machinery than
the two commands it would replace.

If the release cadence ever changes, the shape is a fine-grained PAT scoped to this
repository alone — and it wants its own issue and its own decision, not a quiet commit.

---

## Measured, on Homebrew 6.0.20–6.0.21

Recorded because each one either contradicts something reasonable or has no documentation
worth the name.

- **A formula must be in a tap.** `brew install --build-from-source ./Formula/x.rb` is
  refused outright; a local file path is not a valid formula reference any more.
- **Per-service `.env` overrides landed in Homebrew 6.0.15.** Below that there is no
  supported way to move a service's port.
- **`$HOMEBREW_USER_CONFIG_HOME` is `$XDG_CONFIG_HOME/homebrew`, else
  `$HOMEBREW_XDG_CONFIG_HOME/homebrew`, else `~/.homebrew`** — so the `.env` path is not
  always under `~/.homebrew`.
- **`brew audit --new` performs an online reachability check on `url` even without
  `--online`**, which is why the placeholder formula's only complaint is a 404.
- **`brew audit --strict` sorts `depends_on :macos` ahead of the named dependencies** and
  fails the audit otherwise.
- **`brew services start` regenerates the plist from the formula**, so `restart` is both
  "restart" and "reinstall" — unlike `launchctl kickstart -k`, which does not re-read a
  plist at all. Seen directly: a `log_path` edited in the formula changed the generated
  `StandardOutPath` on the next start.
- **`brew install` may upgrade an outdated dependency as a side effect.** A test install
  here pulled tmux forward a version. Nothing broke, but it is a real change to the machine
  and worth knowing before you run one on a Mac in use.

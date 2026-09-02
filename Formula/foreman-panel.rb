# Foreman — one local web panel for every Claude Code session on this Mac.
#
# ## The name
#
# `foreman-panel`, not `foreman`. homebrew-core already ships a `foreman` (the Procfile
# process manager) and it installs `bin/foreman`. A keg lives at `<prefix>/Cellar/<name>`,
# so two formulae called `foreman` cannot both be installed; an unqualified
# `brew install foreman` resolves to core's; and `brew services start foreman` takes a
# *short* name, so it would be ambiguous forever on any Mac that had tapped both. The
# project keeps its name everywhere a human reads it and gives up eight characters in the
# one place a computer has to disambiguate.
#
# ## The lines that are load-bearing, and why
#
# Two of the three are below; the third (`log_path`) carries its own note at its own site,
# because what makes it load-bearing is the line beside it.
#
# **`keep_alive successful_exit: false`.** This is not a preference — it is the other half
# of the panel's boot contract. `server/index.js` probes `127.0.0.1:<port>` before it
# listens and exits **0** when something already answers there, so that a second panel
# never binds the same port (two Node servers *can* both bind it, silently, and then split
# traffic by interface). Only `SuccessfulExit: false` makes launchd read that exit as
# "I deliberately declined to start" and stand down. Written `keep_alive true`, a brew
# service started beside a running checkout panel becomes a silent restart loop at the
# throttle interval.
#
# **`environment_variables` supplies `PATH` and `FOREMAN_LOG_DIR`, and nothing else.**
# Never `FOREMAN_HOST`: the panel binds loopback by default and is widened only by the
# machine's own record (`bindHost` in `<state dir>/config.json`), so a formula that put a
# host here would ship one stranger's decision to every Mac that installed it. `PATH`
# because launchd's is four directories and the panel shells `npm` when it prepares a
# worktree — `std_service_path_env` is Homebrew's own answer to that. `FOREMAN_LOG_DIR`
# because this plist is generated from *this* file, in *this* repository, and nothing in
# the panel's own repository can read or pin it: left to derive the path itself, a brew
# panel would trim two files in ~/Library/Logs that it never writes to while the files
# launchd really appends to grow without bound. The plist tells the process instead.
#
# Everything else the panel resolves at boot from its own settings file. A `service do`
# block is evaluated when the plist is generated, outside all of that, and must not become
# a second copy of those rules in another language in another repository.
#
# ## `run` names the shim, never `server/index.js`
#
# The panel's in-repo installer sweeps `~/Library/LaunchAgents` — the same directory
# `brew services` writes into — for orphaned jobs of its own, and its first filter is a
# `ProgramArguments` entry ending in `/server/index.js`. `[opt_bin/"foreman-panel",
# "serve"]` has no such argument and falls out immediately. Rewrite this line to invoke
# `server/index.js` directly and a checkout installer is one edit away from booting out a
# brew service.
class ForemanPanel < Formula
  desc "Local web panel for every Claude Code session on this Mac"
  homepage "https://github.com/oferaharon/foreman"

  # `url` and `sha256` are bumped **after** a release is published, never before it: the
  # checksum is taken over the tarball GitHub generates *for the tag*, whose bytes are
  # stable only once the tag exists. Compute it, never copy it from anywhere:
  #   curl -fsSL <url> | shasum -a 256
  # A formula bumped ahead of its tag points at a 404 that Homebrew reports as a download
  # failure, with no hint that the release simply is not out yet. The full ritual is under
  # "Bumping the formula after a release" in this tap's README.
  url "https://github.com/oferaharon/foreman/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "3b8cec5a8815a43e024cd5bf338e22339bcb1cb54b6d89b0d7e8342b8cd60a48"

  license "MIT"

  # `node` and `tmux` are what the panel cannot run without: it reads the tmux pane roster
  # to find sessions and types into panes through it. `git` is deliberately absent —
  # macOS ships a usable one at /usr/bin/git, which is what the panel already relies on,
  # and a hard dependency would change which git a user's `git push` resolves to.
  # `gh` is absent for the same reason in reverse: it matters only to a team on a
  # GitHub-hosted repository, so it is named in the caveats rather than installed on every
  # Mac that only ever wanted to read its Claude Code sessions.
  #
  # The order is `brew audit --strict`'s, not a preference: it sorts `:macos` ahead of the
  # named dependencies and fails the audit otherwise.
  depends_on :macos
  depends_on "node"
  depends_on "tmux"

  def install
    system "npm", "install", *std_npm_args
    bin.install_symlink Dir["#{libexec}/bin/*"]
  end

  service do
    log_dir = var/"log"
    run [opt_bin/"foreman-panel", "serve"]
    keep_alive successful_exit: false
    run_at_load true
    throttle_interval 10
    environment_variables PATH: std_service_path_env, FOREMAN_LOG_DIR: log_dir
    # `foreman.log`, not `foreman-panel.log`, and this is measured rather than chosen.
    # `FOREMAN_LOG_DIR` moves the *directory*; the two basenames stay derived from the
    # panel's launchd-label constant, which under Homebrew is untouched and therefore its
    # default — so the process computes `<dir>/foreman.log` and `<dir>/foreman-error.log`.
    # Named `foreman-panel.log` here, launchd would append to one pair while the panel's
    # boot-time rotation trimmed a different, empty pair: the files that are really
    # written grow without bound, which is precisely the bug that rotation exists to
    # prevent. Verified on an installed service — the boot block printed one path into a
    # file at the other. Change either side and change both.
    log_path log_dir/"foreman.log"
    error_log_path log_dir/"foreman-error.log"
    working_dir HOMEBREW_PREFIX
  end

  def caveats
    <<~EOS
      Register the status hook once:    foreman-panel install-hook
      Start it:                         brew services start foreman-panel
      Then open                         http://127.0.0.1:48770

      After `brew upgrade`, restart it: brew services restart foreman-panel
      An upgrade puts the new version on disk and leaves the old process running.

      Claude Code itself is not a Homebrew package and is not installed by this formula.
      The panel observes Claude Code sessions and does nothing useful without it.
      `gh` is needed only if you use the team features against a GitHub-hosted repository.

      The panel binds loopback and is reachable only from this Mac. To widen it, set
      `bindHost` in ~/.foreman/config.json and restart — read SECURITY.md in the project
      first, because there is no authentication in front of the panel by design.

      To run on another port or with another state directory, put KEY=value lines in
      $HOMEBREW_USER_CONFIG_HOME/services/foreman-panel.env (that is ~/.homebrew/services/
      unless you set XDG_CONFIG_HOME), mode 600 — Homebrew skips a group- or
      world-writable file with only a warning — and restart. Needs Homebrew 6.0.15+.
      Do not set FOREMAN_LOG_DIR there: it moves the panel's log rotation without moving
      launchd's output, and the logs then grow without bound.
      If you change the port, set FOREMAN_PORT in your shell when you run
      `foreman-panel install-hook`: the hook bakes the port into the command it writes and
      never rewrites an entry that is already there.

      Logs:                             #{var}/log/foreman.log
                                        #{var}/log/foreman-error.log
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/foreman-panel version")
  end
end

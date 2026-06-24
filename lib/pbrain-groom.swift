// pbrain-groom — nightly groom runner + FDA-holding vault writer.
//
// WHY THIS EXISTS
// ---------------
// The 06:40 grooming LaunchAgent (com.pbrain.pm-groom) runs headless. A process
// launched by launchd gets NO Full Disk Access, and the Obsidian vault lives in
// Apple's privacy-protected iCloud container
// (~/Library/Mobile Documents/iCloud~md~obsidian/…). So when the bash groom tries
// to write the grooming-data artifact (vault/agent-work/daily-grooming/<date>.md)
// it fails with EPERM. The write is best-effort (|| true) in bash, so the run
// succeeds — but the vault file the user reviews on waking is never refreshed by
// the nightly job; only an interactive morning run (which inherits Terminal's FDA)
// backfills it.
//
// macOS FDA cannot be scoped to a shell script: TCC keys consent on the Mach-O
// binary launchd invokes, and a script main-executable hits TCC problems. Under
// launchd there is also no FDA-granted parent to inherit from. The reliable
// narrow-scope fix is a single compiled, ad-hoc-signed binary that DOES the
// protected write itself — the same pattern as pbrain-tracker.app /
// pbrain-reminders.app / pbrain-notify.app. The user grants FDA once to THIS
// binary; no broad /bin/bash grant.
//
// WHAT IT DOES
// ------------
// This is a thin runner + copier. It must NOT reimplement any groom logic — all of
// that stays in bash. On each fire it:
//   1. runs the existing bash groom
//        /bin/bash <script> groom run --apply --projects <csv>
//      with PBRAIN_PMG_HEADLESS=1 + a Homebrew-inclusive PATH, inheriting stdio.
//      bash renders the grooming-data markdown to the non-iCloud STAGING path
//      (~/.config/pbrain/pm-groom/<date>.data.md), which needs no FDA, and also
//      best-effort-attempts the direct vault write (a no-op here under launchd).
//   2. copies the staging file -> the iCloud vault path IN-PROCESS (Data.write),
//      which TCC attributes to this signed binary (the FDA holder).
// It exits with the bash exit code so launchd's last-exit reflects the real run.
// The copy is best-effort: a copy failure (e.g. FDA not yet granted) is logged but
// never changes the exit code — the staging file is always present as the fallback.
//
// USAGE
//   pbrain-groom --script <project-manager.sh> --projects <csv>
//                --staging-dir <abs dir> --vault-dir <abs dir>
//
// The dated filename (<YYYY-MM-DD>.data.md for staging, <YYYY-MM-DD>.md for the
// vault) is derived here from today's local date — matching bash's `date +%F` and
// pmg_data_file/pmg_staging_file — so the copy targets the same file bash wrote.
//
// Build: `swiftc -suppress-warnings pbrain-groom.swift`
// (compiled by pmg_groom_app_build in lib/pm-groom.sh, --sign for a stable identity)

import Foundation

func argValue(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}

func log(_ s: String) {
    FileHandle.standardError.write(("pbrain-groom: " + s + "\n").data(using: .utf8)!)
}

let script     = argValue("--script")
let projects   = argValue("--projects")
let stagingDir = argValue("--staging-dir")
let vaultDir   = argValue("--vault-dir")

// Today's local date as YYYY-MM-DD (matches `date +%F`).
let df = DateFormatter()
df.dateFormat = "yyyy-MM-dd"
df.locale = Locale(identifier: "en_US_POSIX")
df.timeZone = TimeZone.current
let today = df.string(from: Date())

func joined(_ dir: String?, _ name: String) -> String? {
    guard let d = dir, !d.isEmpty else { return nil }
    return URL(fileURLWithPath: d).appendingPathComponent(name).path
}
let staging = joined(stagingDir, "\(today).data.md")
let vault   = joined(vaultDir,   "\(today).md")

guard let script = script, !script.isEmpty else {
    log("missing --script"); exit(2)
}

// --- 1. run the bash groom, inheriting stdout/stderr -----------------------
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/bin/bash")
var args = [script, "groom", "run", "--apply"]
if let p = projects, !p.isEmpty { args += ["--projects", p] }
proc.arguments = args

var env = ProcessInfo.processInfo.environment
env["PBRAIN_PMG_HEADLESS"] = "1"
// Ensure Homebrew tools (envsubst, python3) resolve even though launchd hands us a
// minimal PATH. Prepend rather than replace so anything inherited still works.
let extraPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if let cur = env["PATH"], !cur.isEmpty {
    env["PATH"] = extraPath + ":" + cur
} else {
    env["PATH"] = extraPath
}
proc.environment = env

var bashRC: Int32 = 0
do {
    try proc.run()
    proc.waitUntilExit()
    bashRC = proc.terminationStatus
} catch {
    log("failed to run bash groom: \(error)")
    exit(127)
}

// --- 1b. AUTONOMOUS judgment triage (opt-in) -------------------------------
// When PBRAIN_GROOM_AUTONOMOUS=1, run a HEADLESS Claude session that does the
// judgment triage the mechanical bash pass can't: enrich thin needs_review issues
// (descriptions/estimates) and refine auto:* labels by real complexity. TRIAGE-ONLY
// — the allowlist excludes git/gh/Edit and /plan-my-work, so it structurally cannot
// execute issues. dontAsk mode = any clarifying question / unapproved tool is denied,
// not blocked, so the agent uses its own judgment and never hangs. Best-effort: a
// failure (claude missing, not logged in, timeout) is logged and we still do
// the vault copy of the mechanical result — never worse than today.
if ProcessInfo.processInfo.environment["PBRAIN_GROOM_AUTONOMOUS"] == "1" {
    func envOr(_ key: String, _ fallback: String) -> String {
        let v = ProcessInfo.processInfo.environment[key]
        return (v != nil && !v!.isEmpty) ? v! : fallback
    }
    let maxTurns = envOr("PBRAIN_GROOM_MAX_TURNS", "30")
    let timeoutS = envOr("PBRAIN_GROOM_CLAUDE_TIMEOUT", "600")
    // Triage-only allowlist: Plane reads/writes via python3 + the project-manager
    // wrapper, plus read tools. NO Bash(git*), NO gh, NO Edit, NO /plan-my-work.
    let allowed = "Bash(python3 *),Bash(bash *project-manager.sh *),Read,Glob,Skill"
    // Run claude under `timeout` so a hung session can't run forever. The session
    // executes the same /project-manager groom skill; in headless dontAsk mode it
    // can't reach /plan-my-work, so it stops after enrich + ASSESS & LABEL.
    // No USD budget cap (per user) — the run is bounded by --max-turns + timeout.
    let claude = Process()
    claude.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    claude.arguments = [
        "timeout", timeoutS, "claude", "-p", "/project-manager groom",
        "--permission-mode", "dontAsk",
        "--allowedTools", allowed,
        "--max-turns", maxTurns,
    ]
    // Run in the pbrain repo so the skill + plane.py resolve. Inherit our env (which
    // launchd populated with HOME/USER/PATH) so the subscription keychain login is
    // found; keep PBRAIN_PMG_HEADLESS so any nested groom stays non-interactive.
    claude.environment = env
    claude.currentDirectoryURL = URL(fileURLWithPath: (script as NSString).deletingLastPathComponent)
        .deletingLastPathComponent()  // commands/ -> repo root
    log("autonomous triage: launching headless claude (max-turns=\(maxTurns), timeout=\(timeoutS)s, no budget cap)")
    do {
        try claude.run()
        claude.waitUntilExit()
        let rc = claude.terminationStatus
        if rc == 124 {
            log("autonomous triage: claude TIMED OUT after \(timeoutS)s — using mechanical result")
        } else if rc != 0 {
            log("autonomous triage: claude exited \(rc) — using mechanical result")
        } else {
            log("autonomous triage: claude completed")
        }
    } catch {
        log("autonomous triage: could not launch claude (\(error)) — is it on PATH? using mechanical result")
    }
    // The claude session updated Plane (enriched + labeled), but the staging
    // grooming-data file was written by the EARLIER bash pass. Re-run the bash groom
    // (scan only, no apply needed for re-render — but --apply is idempotent) so the
    // staging file reflects the post-triage Plane state before we copy it to the vault.
    let rerender = Process()
    rerender.executableURL = URL(fileURLWithPath: "/bin/bash")
    var rargs = [script, "groom", "run", "--apply"]
    if let p = projects, !p.isEmpty { rargs += ["--projects", p] }
    rerender.arguments = rargs
    rerender.environment = env
    do {
        try rerender.run()
        rerender.waitUntilExit()
    } catch {
        log("autonomous triage: re-render after claude failed (\(error)) — vault may lag Plane")
    }
}

// --- 2. copy staging -> vault in-process (this is the FDA-holding write) -----
// Best-effort: never let a copy failure change the exit code. The staging file is
// the durable source of truth; the vault copy is the convenience the FDA grant buys.
if let staging = staging, let vault = vault, !staging.isEmpty, !vault.isEmpty {
    let fm = FileManager.default
    if fm.fileExists(atPath: staging) {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: staging))
            let vaultURL = URL(fileURLWithPath: vault)
            try? fm.createDirectory(at: vaultURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try data.write(to: vaultURL, options: .atomic)
            log("vault refreshed: \(vault)")
        } catch {
            // Most likely EPERM = Full Disk Access not yet granted to this binary.
            log("vault write skipped (\(error.localizedDescription)); " +
                "grant Full Disk Access to pbrain-groom.app. staging kept at \(staging)")
        }
    } else {
        log("no staging file at \(staging) — nothing to copy to the vault")
    }
}

exit(bashRC)

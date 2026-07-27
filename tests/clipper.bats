#!/usr/bin/env bats
# Tests for /clipper (commands/clipper.sh) — saves an online video as a clean
# transcript. We exercise the pure, network-free pieces: the parse-vtt VTT
# cleaner (inline-tag stripping + rolling-window de-duplication) and the
# argument-routing guards (usage, unknown platform, missing URL). The download /
# cookie / transcription paths need yt-dlp + a live network, so they aren't
# covered here.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0 PBRAIN_UPDATE_CHECK=0 PBRAIN_SELF_IMPROVE=off
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  CLIP() { bash "$REPO_ROOT/commands/clipper.sh" "$@"; }
}
teardown() { rm -rf "$TMP"; }

# A manual-style VTT (clean cues, real punctuation).
write_manual_vtt() {
  cat > "$TMP/manual.vtt" <<'VTT'
WEBVTT
Kind: captions
Language: en

00:00:01.000 --> 00:00:03.000
Hello there, this is a test.

00:00:03.000 --> 00:00:05.000
It spans two lines here.
VTT
}

# An auto-caption VTT with inline <timestamp>/<c> tags and the rolling-window
# duplication yt-dlp emits for YouTube ASR tracks.
write_auto_vtt() {
  cat > "$TMP/auto.vtt" <<'VTT'
WEBVTT
Kind: captions
Language: en

00:00:00.100 --> 00:00:02.000 align:start position:0%

the<00:00:00.300><c> quick</c><00:00:00.600><c> brown</c><00:00:00.900><c> fox</c>

00:00:02.000 --> 00:00:02.010 align:start position:0%
the quick brown fox


00:00:02.010 --> 00:00:04.000 align:start position:0%
the quick brown fox
jumps<00:00:02.300><c> over</c><00:00:02.600><c> the</c><00:00:02.900><c> lazy</c><00:00:03.200><c> dog</c>
VTT
}

@test "parse-vtt cleans a manual track and joins cues into flowing text" {
  write_manual_vtt
  run CLIP parse-vtt "$TMP/manual.vtt"
  [ "$status" -eq 0 ]
  [ "$output" = "Hello there, this is a test. It spans two lines here." ]
}

@test "parse-vtt strips inline tags and collapses rolling-window duplicates" {
  write_auto_vtt
  run CLIP parse-vtt "$TMP/auto.vtt"
  [ "$status" -eq 0 ]
  [ "$output" = "the quick brown fox jumps over the lazy dog" ]
}

@test "parse-vtt on a missing file is silent and non-fatal" {
  run CLIP parse-vtt "$TMP/nope.vtt"
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "no args prints usage" {
  run CLIP
  [ "$status" -eq 0 ] && [[ "$output" == *"CLIPPER_USAGE"* ]]
}

@test "unknown platform is reported, not crashed" {
  run CLIP tiktok "https://example.com/x"
  [ "$status" -eq 0 ] && [[ "$output" == *"CLIPPER_UNKNOWN_PLATFORM"* ]]
}

@test "platform with no URL asks for one" {
  run CLIP x save this video
  [ "$status" -eq 0 ] && [[ "$output" == *"CLIPPER_NO_URL"* ]]
}

@test "twitter and youtube aliases are accepted (still need a URL)" {
  run CLIP twitter
  [ "$status" -eq 0 ] && [[ "$output" == *"CLIPPER_NO_URL"* ]]
}

@test "transcriber status reports the parakeet v3 model dir" {
  # No build here — just the status read. Point the model dir at a known absent
  # path so the assertion is deterministic regardless of the host's cache.
  export PBRAIN_CLIPPER_FLUIDAUDIO_MODEL_DIR="$TMP/no-model"
  run CLIP transcriber status
  [ "$status" -eq 0 ] && [[ "$output" == *"CLIPPER_TRANSCRIBER_STATUS"* ]] \
    && [[ "$output" == *"parakeet-tdt-0.6b-v3"* ]] && [[ "$output" == *"model_present: no"* ]]
}

@test "transcriber install short-circuits when a binary is already present" {
  # A fake executable on the override env var → no build attempted.
  printf '#!/bin/sh\n' > "$TMP/fake-fa"; chmod +x "$TMP/fake-fa"
  export PBRAIN_CLIPPER_FLUIDAUDIO_BIN="$TMP/fake-fa"
  run CLIP transcriber install
  [ "$status" -eq 0 ] && [[ "$output" == *"CLIPPER_TRANSCRIBER_INSTALL"* ]] \
    && [[ "$output" == *"already available"* ]]
}

@test "usage lists the transcriber subcommand" {
  run CLIP
  [ "$status" -eq 0 ] && [[ "$output" == *"transcriber install"* ]]
}

# --- X article branch -------------------------------------------------------
# `clipper x <url>` routes on URL shape: /i/articles/... and /<handle>/article/...
# take the headless-browser article path; everything else stays on the video
# path. The scrape itself needs a live session, so these cover the routing and
# the pure cookie-translation helper only.

# Article URLs need `uv`; with it absent the article branch must say so (and
# must NOT fall through to the video path's yt-dlp error).
@test "article URL routes to the article path and reports a missing uv" {
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" run bash "$REPO_ROOT/commands/clipper.sh" \
    x "https://x.com/i/articles/1234567890"
  [ "$status" -eq 0 ] && [[ "$output" == *"CLIPPER_NO_UV"* ]]
}

@test "handle-style article URL also routes to the article path" {
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" run bash "$REPO_ROOT/commands/clipper.sh" \
    x "https://x.com/someone/article/999"
  [ "$status" -eq 0 ] && [[ "$output" == *"CLIPPER_NO_UV"* ]]
}

# A /status/ link is a video until proven otherwise — it must NOT be treated as
# an article, or every X video would take the browser path.
@test "a status URL stays on the video path" {
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" run bash "$REPO_ROOT/commands/clipper.sh" \
    x "https://x.com/someone/status/999"
  [ "$status" -eq 0 ] && [[ "$output" != *"CLIPPER_NO_UV"* ]]
}

# YouTube must never reach the X-article branch, whatever the path looks like.
@test "a youtube URL containing /article/ is not treated as an X article" {
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" run bash "$REPO_ROOT/commands/clipper.sh" \
    yt "https://www.youtube.com/article/123"
  [ "$status" -eq 0 ] && [[ "$output" != *"CLIPPER_NO_UV"* ]]
}

# Cookie translation is the piece most likely to break silently (a bad jar means
# an unauthenticated scrape that looks like "not an article"), so assert it
# directly: only real X domains, and no out-of-range expiry.
@test "cookie translation keeps only X cookies and drops look-alike domains" {
  cat > "$TMP/jar.txt" <<'JAR'
# Netscape HTTP Cookie File
.x.com	TRUE	/	TRUE	13430917328523184	auth_token	secret
.twitter.com	TRUE	/	TRUE	1848260722	guest_id	g1
.netflix.com	TRUE	/	TRUE	1848260722	NetflixId	nope
.notx.com	TRUE	/	TRUE	1848260722	other	nope
x.com	FALSE	/	FALSE	0	lang	en
JAR
  run python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
c = m._cookies_for_playwright(sys.argv[2])
by = {x["name"]: x for x in c}
print("NAMES=" + ",".join(sorted(by)))
# Chrome-epoch microseconds are out of range → must degrade to a session cookie.
print("AUTH_HAS_EXPIRES=" + str("expires" in by.get("auth_token", {})).lower())
# A zero-expiry session cookie must omit the field entirely.
print("LANG_HAS_EXPIRES=" + str("expires" in by.get("lang", {})).lower())
# A normal unix expiry is preserved as-is.
print("GUEST_EXPIRES=" + str(by.get("guest_id", {}).get("expires")))
' "$REPO_ROOT/lib/clipper-x-article.py" "$TMP/jar.txt"
  [ "$status" -eq 0 ]
  # netflix.com / notx.com must not survive a naive suffix match.
  [[ "$output" == *"NAMES=auth_token,guest_id,lang"* ]]
  [[ "$output" == *"AUTH_HAS_EXPIRES=false"* ]]
  [[ "$output" == *"LANG_HAS_EXPIRES=false"* ]]
  [[ "$output" == *"GUEST_EXPIRES=1848260722.0"* ]]
}

#!/usr/bin/env python3
# X longform-article scraper for /clipper x <article-url>.
#
# X articles are client-rendered React: a plain cookie-authenticated HTTP fetch
# returns the "JavaScript is not available" shell with zero article paragraphs,
# so a real browser is required to read the body. This module drives headless
# Chromium via Playwright, authenticating with the SAME Netscape cookies.txt jar
# clipper already exports for yt-dlp (`--cookies-from-browser`), so there is no
# second login flow to maintain — the video path and the article path share one
# session source.
#
# It is NOT part of the stdlib-only shell contract: it is a separate,
# on-demand script run through `uv run --with ...` (see clipper.sh's
# _clipper_x_article_scrape), which builds an ephemeral, isolated environment.
# Nothing is added to the pbrain repo's own dependency surface, mirroring how
# clipper already builds fluidaudiocli on demand for audio transcription.
#
# Usage:  clipper-x-article.py <article-url> <cookies.txt|-> <out.json>
#
# Writes a JSON object to <out.json>:
#   {"ok": true,  "title", "author", "byline", "published", "markdown", "words"}
#   {"ok": false, "reason": "<login|not_article|load_failed|no_content>",
#    "detail": "<human-readable>"}
# Exit code is 0 whenever that JSON was written (including ok:false) so the
# caller can branch on `reason` rather than parse stderr.

import http.cookiejar
import json
import re
import sys

PAGE_LOAD_TIMEOUT_MS = 30_000
SETTLE_MS = 2_500

# X longform articles render through a Draft.js editor in read-only mode, with
# stable data-testid hooks. Prefer those outright: the generic
# "score every article/main container" heuristic reliably picks the wrong node
# on an /article/ page, because a reply tweet is a real <article> element while
# the article body is a testid-tagged <div>. Scoring is kept only as a fallback
# for layouts that predate (or outlive) these hooks.
_EXTRACT_JS = r"""
() => {
  const pickPreferred = () => {
    for (const sel of [
      "[data-testid='longformRichTextComponent']",
      "[data-testid='twitterArticleRichTextView']",
      "[data-testid='twitterArticleReadView']",
    ]) {
      const node = document.querySelector(sel);
      if (node && (node.innerText || "").trim().length > 200) return node;
    }
    return null;
  };

  const scoreBest = () => {
    const candidates = Array.from(
      document.querySelectorAll(
        [
          "article",
          "[data-testid='primaryColumn'] article",
          "[data-testid='primaryColumn'] section",
          "main article",
          "main",
        ].join(",")
      )
    )
      .filter((node) => node instanceof HTMLElement)
      .map((node) => {
        const paragraphCount =
          node.querySelectorAll("p").length +
          node.querySelectorAll("[data-block='true']").length;
        const imageCount = node.querySelectorAll("img").length;
        const textLength = (node.innerText || "").trim().length;
        const rect = node.getBoundingClientRect();
        const area = Math.max(rect.width * rect.height, 0);
        const score =
          paragraphCount * 50 + imageCount * 20 + textLength + Math.min(area / 100, 1000);
        return { node, score };
      })
      .sort((left, right) => right.score - left.score);
    return candidates[0]?.node || null;
  };

  const root = pickPreferred() || scoreBest();
  if (!root) {
    return null;
  }

  const clone = root.cloneNode(true);

  // Keep real article media; drop avatars, emoji and UI icons.
  const isArticleContentImage = (img) => {
    const src = img.currentSrc || img.getAttribute("src") || "";
    const alt = img.getAttribute("alt") || "";
    const rect = img.getBoundingClientRect();
    const withinTweetPhoto = !!img.closest("[data-testid='tweetPhoto']");
    const withinTweetText = !!img.closest("[data-testid='tweetText']");
    const isEmoji =
      src.includes("/emoji/") ||
      src.includes("abs-0.twimg.com") ||
      withinTweetText ||
      rect.width <= 24 ||
      rect.height <= 24;
    const isAvatar =
      src.includes("/profile_images/") ||
      src.includes("_normal.") ||
      (img.naturalWidth <= 64 && img.naturalHeight <= 64) ||
      (rect.width <= 64 && rect.height <= 64);
    const isArticleCover = alt === "Article cover image";
    const isMediaCdnImage =
      src.includes("pbs.twimg.com/media/") && img.naturalWidth >= 200;
    if (isEmoji || isAvatar) {
      return false;
    }
    return withinTweetPhoto || isArticleCover || isMediaCdnImage;
  };

  // Image srcs stay absolute CDN URLs (never inlined) so the clip stays small.
  const originalImages = Array.from(root.querySelectorAll("img"));
  const clonedImages = Array.from(clone.querySelectorAll("img"));
  for (let index = 0; index < clonedImages.length; index += 1) {
    const original = originalImages[index];
    const cloned = clonedImages[index];
    if (!original || !cloned) continue;
    if (!isArticleContentImage(original)) {
      cloned.remove();
      continue;
    }
    const resolved = original.currentSrc || original.getAttribute("src") || "";
    if (resolved) cloned.setAttribute("src", resolved);
  }

  clone
    .querySelectorAll("script, style, button, nav, aside, svg, video, iframe")
    .forEach((node) => node.remove());
  clone
    .querySelectorAll("[data-testid='UserAvatar-Container'], [role='group']")
    .forEach((node) => node.remove());

  // Draft.js emits each paragraph as a <div data-block="true">, which the
  // HTML→Markdown pass would otherwise run together into one wall of text.
  // Retag them as real <p> so paragraph breaks survive the conversion, unless
  // the block already carries its own semantic element (heading, list, quote).
  clone.querySelectorAll("[data-block='true']").forEach((block) => {
    if (block.querySelector("h1, h2, h3, h4, h5, h6, li, blockquote, pre")) return;
    const p = document.createElement("p");
    p.innerHTML = block.innerHTML;
    block.replaceWith(p);
  });

  const title =
    document.querySelector("h1")?.textContent?.trim() ||
    root.querySelector("h1, h2")?.textContent?.trim() ||
    (document.title || "").replace(/ \/ X$/, "").trim() ||
    "X Article";

  // Byline. The DOM is unreliable here: an article that quote-tweets someone
  // renders THEIR User-Name block first, so a naive "first profile link" picks
  // the quoted account, not the author. The /<handle>/article/... URL is
  // authoritative when present; fall back to the DOM only for /i/articles/...
  let author = "";
  const handleFromUrl = location.pathname.match(/^\/([^/]+)\/article\//);
  if (handleFromUrl && handleFromUrl[1] !== "i") {
    author = handleFromUrl[1];
  } else {
    const authorLink = document.querySelector(
      "[data-testid='User-Name'] a[href^='/'], article a[href^='/'][role='link']"
    );
    author = authorLink ? (authorLink.getAttribute("href") || "").replace(/^\//, "") : "";
  }
  const published = document.querySelector("time")?.getAttribute("datetime") || "";

  return {
    title,
    author,
    published,
    articleHtml: clone.outerHTML,
    textLength: (root.innerText || "").trim().length,
    // Draft.js blocks are this layout's paragraphs; count both.
    paragraphs:
      root.querySelectorAll("p").length +
      root.querySelectorAll("[data-block='true']").length,
  };
}
"""

# Force lazy media in, then let the article settle. Long articles lazy-load on
# scroll, so we walk to the bottom before extracting or we truncate the body.
_HYDRATE_JS = r"""
async () => {
  const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const scrollRoot = document.scrollingElement || document.documentElement;
  for (let step = 0; step < 30; step += 1) {
    const previousHeight = scrollRoot.scrollHeight;
    window.scrollTo(0, previousHeight);
    await delay(350);
    for (const img of document.images) {
      if (img.loading !== "eager") img.loading = "eager";
    }
    if (scrollRoot.scrollHeight === previousHeight) break;
  }
  window.scrollTo(0, 0);
  await delay(300);
}
"""


def _fail(out_path: str, reason: str, detail: str) -> int:
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"ok": False, "reason": reason, "detail": detail}, f)
    return 0


_X_DOMAINS = ("x.com", "twitter.com")

# Upper bound for a credible unix expiry (~year 2286). Anything above this is a
# different epoch/unit (e.g. Chrome's microseconds-since-1601), not a real date.
_MAX_UNIX_EXPIRES = 1e10


def _is_x_domain(domain: str) -> bool:
    """True only for x.com / twitter.com and their subdomains.

    Matched on a label boundary, NOT a bare suffix: a naive endswith("x.com")
    also matches netflix.com, and would ship unrelated site cookies to X.
    """
    d = (domain or "").lstrip(".").lower()
    return any(d == base or d.endswith("." + base) for base in _X_DOMAINS)


def _cookies_for_playwright(cookies_path: str) -> list[dict]:
    """Convert a Netscape cookies.txt jar into Playwright cookie dicts.

    Only X cookies are forwarded — the jar clipper exports via yt-dlp holds
    every cookie in the browser, and handing all of them to the context is both
    unnecessary and a far wider credential surface than this needs.
    """
    if not cookies_path or cookies_path == "-":
        return []
    jar = http.cookiejar.MozillaCookieJar(cookies_path)
    try:
        jar.load(ignore_discard=True, ignore_expires=True)
    except Exception:
        return []
    out = []
    for c in jar:
        if not _is_x_domain(c.domain or ""):
            continue
        cookie = {
            "name": c.name,
            "value": c.value or "",
            "domain": c.domain,
            "path": c.path or "/",
            "secure": bool(c.secure),
            "httpOnly": False,
        }
        # Playwright rejects anything but -1 or a plausible unix timestamp.
        # Session cookies (expires None/0) omit the field entirely. Some
        # browsers (Brave/Chrome) export WebKit epoch microseconds-since-1601
        # instead of unix seconds, which overflows the validator — those are
        # sent as session cookies, since the exact expiry is irrelevant for a
        # single scrape as long as the cookie is sent at all.
        if c.expires:
            try:
                exp = float(c.expires)
            except (TypeError, ValueError):
                exp = 0.0
            if 0 < exp <= _MAX_UNIX_EXPIRES:
                cookie["expires"] = exp
        out.append(cookie)
    return out


def _to_markdown(article_html: str) -> str:
    """Convert the cleaned article HTML into Markdown.

    Uses markdownify when present (supplied by the `uv run --with` env), and
    falls back to a minimal stdlib converter otherwise so this module still
    degrades to readable text rather than failing outright.
    """
    try:
        from markdownify import markdownify as html_to_markdown

        body = html_to_markdown(article_html, heading_style="ATX", strip=["script", "style"])
    except Exception:
        from html.parser import HTMLParser

        class _Text(HTMLParser):
            def __init__(self) -> None:
                super().__init__()
                self.parts: list[str] = []

            def handle_starttag(self, tag, attrs):
                if tag in ("p", "br", "div", "h1", "h2", "h3", "li"):
                    self.parts.append("\n\n")
                if tag == "img":
                    src = dict(attrs).get("src", "")
                    if src:
                        self.parts.append(f"\n\n![]({src})\n\n")

            def handle_data(self, data):
                self.parts.append(data)

        p = _Text()
        p.feed(article_html)
        body = "".join(p.parts)

    body = re.sub(r"\n{3,}", "\n\n", body)
    body = re.sub(r"[ \t]+\n", "\n", body)
    return body.strip()


def main() -> int:
    if len(sys.argv) < 4:
        print("usage: clipper-x-article.py <url> <cookies.txt|-> <out.json>", file=sys.stderr)
        return 2
    url, cookies_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

    try:
        from playwright.sync_api import sync_playwright
    except Exception as exc:  # pragma: no cover - env problem, reported to caller
        return _fail(out_path, "load_failed", f"playwright unavailable: {exc}")

    with sync_playwright() as p:
        try:
            browser = p.chromium.launch(
                headless=True, args=["--disable-blink-features=AutomationControlled"]
            )
        except Exception as exc:
            return _fail(out_path, "load_failed", f"could not launch chromium: {exc}")

        context = browser.new_context(
            viewport={"width": 1280, "height": 2000},
            user_agent=(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            ),
        )
        cookies = _cookies_for_playwright(cookies_path)
        if cookies:
            # Never swallow this: without cookies the page silently renders as a
            # logged-out stub, which surfaces as a confusing "not_article".
            try:
                context.add_cookies(cookies)
            except Exception as exc:
                return _fail(
                    out_path, "load_failed", f"could not apply X session cookies: {exc}"
                )

        page = context.new_page()
        try:
            page.goto(url, timeout=PAGE_LOAD_TIMEOUT_MS, wait_until="domcontentloaded")
            page.wait_for_timeout(SETTLE_MS)

            if "/login" in page.url or "/i/flow/login" in page.url:
                return _fail(
                    out_path,
                    "login",
                    "X redirected to the login page — the browser session is missing or expired.",
                )

            for selector in ("article", "main article", "[data-testid='primaryColumn']", "main"):
                try:
                    page.wait_for_selector(selector, timeout=5_000)
                    break
                except Exception:
                    continue

            try:
                page.evaluate(_HYDRATE_JS)
            except Exception:
                pass
            try:
                page.wait_for_load_state("networkidle", timeout=10_000)
            except Exception:
                pass

            # X serves a soft 404 (HTTP 200 + "this page doesn't exist") for a
            # bad or deleted article id. Report that plainly instead of letting
            # it fall through as the much vaguer "not_article".
            body_text = page.evaluate("() => (document.body.innerText || '').trim()")
            if "doesn’t exist" in body_text or "doesn't exist" in body_text:
                return _fail(
                    out_path,
                    "not_found",
                    "X says this page doesn't exist — the article URL is wrong, "
                    "or the article was deleted.",
                )

            payload = page.evaluate(_EXTRACT_JS)
            if not payload:
                return _fail(out_path, "no_content", "Could not locate any article container.")

            # Longform signal check: an ordinary tweet page scores far below this.
            if int(payload.get("textLength") or 0) < 600 or int(payload.get("paragraphs") or 0) < 2:
                return _fail(
                    out_path,
                    "not_article",
                    "This URL rendered as a short post, not a longform article "
                    f"({payload.get('textLength', 0)} chars, {payload.get('paragraphs', 0)} paragraphs).",
                )

            markdown = _to_markdown(payload.get("articleHtml") or "")
            if not markdown.strip():
                return _fail(out_path, "no_content", "Article container held no readable text.")

            with open(out_path, "w", encoding="utf-8") as f:
                json.dump(
                    {
                        "ok": True,
                        "title": (payload.get("title") or "").strip() or "X Article",
                        "author": (payload.get("author") or "").strip(),
                        "published": (payload.get("published") or "").strip(),
                        "markdown": markdown,
                        "words": len(markdown.split()),
                    },
                    f,
                )
            return 0
        except Exception as exc:
            return _fail(out_path, "load_failed", f"{type(exc).__name__}: {exc}")
        finally:
            try:
                context.close()
                browser.close()
            except Exception:
                pass


if __name__ == "__main__":
    sys.exit(main())

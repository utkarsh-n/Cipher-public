"""Shared plumbing for the culture crawl: polite, cached, resumable HTTP."""
import hashlib
import json
import os
import subprocess
import time
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data" / "culture"
CACHE = DATA / "cache"
CACHE.mkdir(parents=True, exist_ok=True)

# Set CIPHER_CONTACT to a public contact address before crawling these services.
USER_AGENT = "CipherLyricsApp/0.2 (personal, non-commercial lyric-writing tool)"
CONTACT = os.environ.get("CIPHER_CONTACT", "")
WIKIMEDIA_AGENT = f"CipherLyricsApp/0.2 ({CONTACT}) curl" if CONTACT else USER_AGENT
WIKIMEDIA_HOSTS = ("wikipedia.org", "wikisource.org", "wikidata.org", "wiktionary.org")
# MusicBrainz asks every client to name a public contact as well.
CONTACT_HOSTS = WIKIMEDIA_HOSTS + ("musicbrainz.org", "metabrainz.org")
SPARQL = "https://query.wikidata.org/sparql"


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, flush=True)


def cache_path(url, params=None):
    full = url + ("?" + urllib.parse.urlencode(params) if params else "")
    return full, CACHE / (hashlib.sha1(full.encode()).hexdigest() + ".bin")


def fetch(url, params=None, pause=0.3, tries=6, timeout=90, patient=False):
    """GET with on-disk caching. Returns bytes, or None when the server keeps refusing.

    Goes through curl rather than urllib: this Python has no CA bundle, the system curl does.
    A refusal for going too fast (429) is waited out and does not use up a try. `patient`
    retries timeouts as well; leave it off for SPARQL, where a timeout means the query is too big.
    """
    full, path = cache_path(url, params)
    if path.exists():
        return path.read_bytes()
    partial = path.with_suffix(".part")
    host = urllib.parse.urlparse(url).hostname or ""
    agent = WIKIMEDIA_AGENT if host.endswith(CONTACT_HOSTS) else USER_AGENT
    attempt = waits = 0
    while attempt < tries and waits < 40:
        result = subprocess.run(
            ["curl", "-sS", "-L", "--compressed", "--max-time", str(timeout), "-A", agent, "-o", str(partial),
             "-w", "%{http_code} %header{retry-after}", full],
            capture_output=True, text=True)
        status, _, retry_after = result.stdout.strip().partition(" ")
        if result.returncode != 0:  # network hiccup or timeout
            if result.returncode == 28 and not patient:
                return None
            log("  retry after curl error", result.returncode)
            attempt += 1
            time.sleep(4 * attempt)
            continue
        if status == "200":
            partial.replace(path)
            time.sleep(pause)
            return path.read_bytes()
        if status == "429":
            waits += 1
            wait = min(int(retry_after), 120) if retry_after.strip().isdigit() else 10 * waits
            log(f"  server asked to wait {wait}s")
            time.sleep(wait + 1)
            continue
        attempt += 1
        if status in ("500", "502", "503", "504") and (patient or status == "503"):
            time.sleep(5 * attempt)
            continue
        if status not in ("500", "502", "504"):
            log("  http", status, full[:120])
        return None
    return None


def sparql(query):
    """Rows as dicts of plain strings, or None if the query timed out."""
    body = fetch(SPARQL, {"query": query, "format": "json"}, pause=1.0)
    if body is None:
        return None
    try:
        bindings = json.loads(body)["results"]["bindings"]
    except Exception:
        return None
    return [{key: value["value"] for key, value in row.items()} for row in bindings]


def qid(uri):
    return uri.rsplit("/", 1)[-1]


def wiki_api(site, params, pause=0.4):
    """A MediaWiki API call, e.g. site='en.wikipedia.org'.

    Paced to about 150 a minute, under the 200 an identified crawler is allowed, and never
    two crawls at once: the allowance is shared across every Wikimedia site.
    """
    url = f"https://{site}/w/api.php"
    query = {**params, "format": "json", "formatversion": "2", "maxlag": "5"}
    for attempt in range(8):
        body = fetch(url, query, pause=pause, tries=8, patient=True)
        if body is None:
            return {}
        try:
            data = json.loads(body)
        except Exception:
            data = None
        error = (data or {}).get("error", {}).get("code") if isinstance(data, dict) else "unreadable"
        if error in ("maxlag", "ratelimited", "readonly", "internal_api_error_DBQueryTimeoutError", "unreadable"):
            # The servers are busy; this answer must not stay in the cache.
            cache_path(url, query)[1].unlink(missing_ok=True)
            log("  api busy:", error)
            time.sleep(6 * (attempt + 1))
            continue
        return data
    return {}

#!/usr/bin/env python3
"""Local stand-in for an OpenAI-compatible chat-completions server, for testing Lineform's
"Other" AI provider without a real key. Python 3 standard library only; binds 127.0.0.1 only.

  python3 scripts/ai-stub-server.py --port 8765
  Connect Your AI > Other > http://127.0.0.1:8765/v1, no key.

The last user message is JSON, as Lineform's AIActionPrompt builds it:
  edit actions  {"action": "trim|cutInHalf|rewrite|proofread|anotherWord", "segments": [...]}
                -> {"segments": [...]}       (one revised string per segment, same order)
  Mark actions  {"action": "weakestSentences|longSentences", "sentences": [...]}
                -> {"sentences": [n, ...]}   (1-based sentence numbers, as AIResponseParser reads)
Replies are deterministic, and like the prompts ask, rewrite / trim (more than three words) /
anotherWord never return a segment unchanged. Flags: --mangle (inject Markdown/line breaks into every segment),
--delay SECONDS, --status CODE, --junk (non-JSON reply), --self-check (assert the reply contract
above and exit). Logs action and item count per request, never text.
"""
import argparse
import json
import math
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

FILLERS = re.compile(r"\b(?:very|really|just|quite)\b\s*", re.IGNORECASE)


SYNONYMS = {
    "big": "large", "good": "fine", "small": "little", "fast": "quick", "quick": "fast",
    "happy": "glad", "sad": "unhappy", "said": "noted", "begin": "start", "start": "begin",
    "end": "finish", "use": "employ", "help": "aid", "show": "reveal", "large": "big",
    "fine": "good", "little": "small", "old": "aged", "new": "fresh", "walk": "stroll",
}
WORD = re.compile(r"[A-Za-z]+")
PURE_WORD = re.compile(r"^[A-Za-z]+$")


def match_case(source, word):
    if source.isupper() and len(source) > 1:
        return word.upper()
    if source[:1].isupper():
        return word[:1].upper() + word[1:]
    return word


def another_word(seg):
    """One different word for the first word in the segment (its punctuation kept)."""
    m = WORD.search(seg)
    if not m:
        return seg
    word = m.group(0)
    alt = SYNONYMS.get(word.lower(), "other" if word.lower() != "other" else "another")
    return seg[: m.start()] + match_case(word, alt) + seg[m.end():]


def trim(seg):
    """Fillers out; with nothing to remove, a segment of more than three words still loses one
    plain word (never the first, and never one carrying punctuation, which the app guards)."""
    out = re.sub(r"\s{2,}", " ", FILLERS.sub("", seg)).strip()
    if out != seg.strip():
        return out
    words = seg.split()
    if len(words) > 3:
        for i in range(1, len(words)):
            if PURE_WORD.match(words[i]):
                return " ".join(words[:i] + words[i + 1:])
    return out


def cut_in_half(seg):
    words = seg.split()
    return " ".join(words[: math.ceil(len(words) / 2)])


def rewrite(seg):
    """Always a different wording: every known word swapped for its synonym, and the two
    halves of a sentence around its first comma reordered; with neither, "plainly" goes in after
    the first word. Punctuation is never added or removed."""
    out = WORD.sub(lambda m: match_case(m.group(0), SYNONYMS.get(m.group(0).lower(), m.group(0))), seg)
    head, sep, tail = out.partition(", ")
    if sep and tail and WORD.search(head) and WORD.search(tail):
        end = re.search(r"[.!?]*$", tail).group(0)
        tail = tail[: len(tail) - len(end)] if end else tail
        if PURE_WORD.match(tail.replace(" ", "")) and PURE_WORD.match(head.replace(" ", "")):
            out = match_case(head, tail[:1].lower() + tail[1:]) + sep + head[:1].lower() + head[1:] + end
    if out == seg:
        m = WORD.search(seg)
        if m:
            out = seg[: m.end()] + " plainly" + seg[m.end():]
    return out


def proofread(seg):
    return re.sub(r"\bteh\b", "the", seg).replace(" ,", ",")


def mangle(seg):
    return seg + " **bold** # head `code` | pipe \\* star\nnext [x](y)"


def result_for(payload):
    action = payload.get("action", "")
    segments = payload.get("segments", [])
    if action in ("weakestSentences", "longSentences"):
        sentences = payload.get("sentences", [])
        if not sentences:
            return {"sentences": []}
        if action == "weakestSentences":
            return {"sentences": [1]}
        best, best_count = 1, -1
        for i, sentence in enumerate(sentences, start=1):
            count = len(sentence.split())
            if count > best_count:
                best, best_count = i, count
        return {"sentences": [best]}
    fn = {"trim": trim, "cutInHalf": cut_in_half, "rewrite": rewrite, "proofread": proofread,
          "anotherWord": another_word}.get(action)
    out = [fn(s) if fn else s for s in segments]
    return {"segments": out}


class Handler(BaseHTTPRequestHandler):
    args = None

    def log_message(self, fmt, *a):  # silence default logging; we print our own line
        pass

    def do_POST(self):
        if self.path.split("?")[0] not in ("/v1/chat/completions", "/chat/completions"):
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        if self.args.delay:
            time.sleep(self.args.delay)
        if self.args.status != 200:
            self.reply(self.args.status, {"error": {"message": "stub status"}})
            return
        try:
            body = json.loads(raw)
            user = [m for m in body["messages"] if m.get("role") == "user"][-1]["content"]
            payload = json.loads(user)
        except Exception:
            print("request: unparseable", flush=True)
            self.reply(400, {"error": {"message": "bad request"}})
            return
        items = payload.get("sentences", payload.get("segments", []))
        print("request: %s, %d items" % (payload.get("action"), len(items)), flush=True)
        if self.args.junk:
            content = "Sure! Here you go."
        else:
            result = result_for(payload)
            if self.args.mangle and "segments" in result:
                result["segments"] = [mangle(s) for s in result["segments"]]
            content = json.dumps(result)
        self.reply(200, {"choices": [{"index": 0, "message": {"role": "assistant", "content": content},
                                       "finish_reason": "stop"}]})

    def reply(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def self_check():
    """The reply contract Lineform parses (AIResponseParser.segments / .sentenceIndices)."""
    mark = {"action": "longSentences", "sentences": ["Short one.", "A much longer sentence here.", "Mid one now."]}
    assert result_for(mark) == {"sentences": [2]}, result_for(mark)
    weakest = {"action": "weakestSentences", "sentences": ["One.", "Two."]}
    assert result_for(weakest) == {"sentences": [1]}, result_for(weakest)
    assert result_for({"action": "weakestSentences", "sentences": []}) == {"sentences": []}
    for action in ("weakestSentences", "longSentences"):
        reply = result_for({"action": action, "sentences": ["A b.", "C d e."]})
        assert set(reply) == {"sentences"}, reply
        assert all(isinstance(n, int) and 1 <= n <= 2 for n in reply["sentences"]), reply
    edit = {"action": "trim", "segments": ["A very big day.", "It was really good."]}
    assert result_for(edit) == {"segments": ["A big day.", "It was good."]}, result_for(edit)
    assert result_for({"action": "proofread", "segments": ["teh dog ,"]}) == {"segments": ["the dog,"]}
    # Rewrite always changes the text: known words swap, a comma clause reorders, and with
    # neither a word goes in. Punctuation never changes (the app's structure guard).
    assert result_for({"action": "rewrite", "segments": ["A big day."]}) == {"segments": ["A large day."]}
    for seg in ("The cat sat on the mat.", "Yesterday it rained, we stayed in.", "Hi", "Big"):
        out = result_for({"action": "rewrite", "segments": [seg]})["segments"][0]
        assert out != seg, (seg, out)
        assert re.sub(r"[A-Za-z ]", "", out) == re.sub(r"[A-Za-z ]", "", seg), (seg, out)
    # Trim always removes a word when there are more than three.
    for seg in ("The cat sat on the mat.", "One two three four"):
        out = result_for({"action": "trim", "segments": [seg]})["segments"][0]
        assert len(out.split()) < len(seg.split()), (seg, out)
    assert result_for({"action": "trim", "segments": ["One two three"]}) == {"segments": ["One two three"]}
    # Another Word: a different word, case and punctuation kept.
    assert result_for({"action": "anotherWord", "segments": ["big"]}) == {"segments": ["large"]}
    assert result_for({"action": "anotherWord", "segments": ["Happy,"]}) == {"segments": ["Glad,"]}
    for seg in ("zebra", "other", "Other"):
        out = result_for({"action": "anotherWord", "segments": [seg]})["segments"][0]
        assert out.lower() != seg.lower() and len(out.split()) == 1, (seg, out)
    for action in ("trim", "cutInHalf", "rewrite", "proofread", "anotherWord"):
        reply = result_for({"action": action, "segments": ["one two", "three"]})
        assert set(reply) == {"segments"} and len(reply["segments"]) == 2, reply
    print("self-check: ok", flush=True)
    return 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--mangle", action="store_true")
    p.add_argument("--delay", type=float, default=0)
    p.add_argument("--status", type=int, default=200)
    p.add_argument("--junk", action="store_true")
    p.add_argument("--self-check", action="store_true")
    Handler.args = p.parse_args()
    if Handler.args.self_check:
        return self_check()
    server = HTTPServer(("127.0.0.1", Handler.args.port), Handler)
    print("Listening on http://127.0.0.1:%d" % Handler.args.port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())

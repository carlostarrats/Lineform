#!/usr/bin/env python3
"""Local stand-in for an OpenAI-compatible chat-completions server, for testing Lineform's
"Other" AI provider without a real key. Python 3 standard library only; binds 127.0.0.1 only.

  python3 scripts/ai-stub-server.py --port 8765
  Connect Your AI > Other > http://127.0.0.1:8765/v1, no key.

The last user message is JSON, as Lineform's AIActionPrompt builds it:
  edit actions  {"action": "trim|cutInHalf|rewrite|proofread", "segments": [...]}
                -> {"segments": [...]}       (one revised string per segment, same order)
  Mark actions  {"action": "weakestSentences|longSentences", "sentences": [...]}
                -> {"sentences": [n, ...]}   (1-based sentence numbers, as AIResponseParser reads)
Replies are deterministic. Flags: --mangle (inject Markdown/line breaks into every segment),
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


def trim(seg):
    return re.sub(r"\s{2,}", " ", FILLERS.sub("", seg)).strip()


def cut_in_half(seg):
    words = seg.split()
    return " ".join(words[: math.ceil(len(words) / 2)])


def rewrite(seg):
    return re.sub(r"\bbig\b", "large", re.sub(r"\bgood\b", "fine", seg))


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
    fn = {"trim": trim, "cutInHalf": cut_in_half, "rewrite": rewrite, "proofread": proofread}.get(action)
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
    for action in ("trim", "cutInHalf", "rewrite", "proofread"):
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

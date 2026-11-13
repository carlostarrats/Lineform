#!/usr/bin/env python3
"""Local stand-in for an OpenAI-compatible chat-completions server, for testing Lineform's
"Other" AI provider without a real key. Python 3 standard library only; binds 127.0.0.1 only.

  python3 scripts/ai-stub-server.py --port 8765
  Connect Your AI > Other > http://127.0.0.1:8765/v1, no key.

The last user message is JSON: {"action": "...", "segments": [...]}. Replies are deterministic.
Flags: --mangle (inject Markdown/line breaks into every segment), --delay SECONDS,
--status CODE, --junk (non-JSON reply). Logs action and segment count per request, never text.
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
    if action == "weakestSentences":
        return {"indices": [1]}
    if action == "longSentences":
        best, best_count = 1, -1
        for i, seg in enumerate(segments, start=1):
            count = len(seg.split())
            if count > best_count:
                best, best_count = i, count
        return {"indices": [best]}
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
        print("request: %s, %d segments" % (payload.get("action"), len(payload.get("segments", []))), flush=True)
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


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--mangle", action="store_true")
    p.add_argument("--delay", type=float, default=0)
    p.add_argument("--status", type=int, default=200)
    p.add_argument("--junk", action="store_true")
    Handler.args = p.parse_args()
    server = HTTPServer(("127.0.0.1", Handler.args.port), Handler)
    print("Listening on http://127.0.0.1:%d" % Handler.args.port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""aaas-embed: one shared embedding service for every tenant's Mnemosyne.

Serves the OpenAI-compatible POST /v1/embeddings that Mnemosyne's remote
mode calls (MNEMOSYNE_EMBEDDING_API_URL). The model is built by
Mnemosyne's own loader, so vectors are identical to local mode. Request
content is never logged or cached. See docs/adr/0010-shared-services.md.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Must not be set in the server, or Mnemosyne's loader routes to "api"
# instead of loading fastembed.
for _var in ("MNEMOSYNE_EMBEDDING_API_URL", "MNEMOSYNE_EMBEDDINGS_VIA_API"):
    os.environ.pop(_var, None)

from mnemosyne.core import embeddings as mnemo  # noqa: E402

MAX_BODY_BYTES = 1 << 20
MAX_TEXTS = 256

log = logging.getLogger("aaas-embed")


class Model:
    def __init__(self, max_concurrency: int):
        self.name = mnemo._DEFAULT_MODEL
        self.dim = mnemo.EMBEDDING_DIM
        self._slots = threading.BoundedSemaphore(max_concurrency)
        self._model = mnemo._get_model()
        if self._model is None or self._model == "api":
            raise RuntimeError("fastembed model unavailable; install mnemosyne-memory[embeddings]")

    def embed(self, texts: list[str]) -> list[list[float]]:
        # Inputs already carry Mnemosyne's query/doc prefixes; don't re-apply.
        with self._slots:
            return [v.astype("float32").tolist() for v in self._model.embed(texts)]


class Handler(BaseHTTPRequestHandler):
    model: Model

    def log_message(self, fmt, *args):
        pass  # default access log includes client details; we log counts only

    def _send(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, code: int, message: str) -> None:
        self._send(code, {"error": {"message": message}})

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"status": "ok", "model": self.model.name, "dim": self.model.dim})
        else:
            self._error(404, "not found")

    def do_POST(self):
        if self.path not in ("/v1/embeddings", "/embeddings"):
            return self._error(404, "not found")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self._error(400, "bad content-length")
        if not 0 < length <= MAX_BODY_BYTES:
            return self._error(413, "body too large or empty")
        try:
            req = json.loads(self.rfile.read(length))
        except ValueError:
            return self._error(400, "bad json")

        texts = req.get("input")
        if isinstance(texts, str):
            texts = [texts]
        if not isinstance(texts, list) or not texts or len(texts) > MAX_TEXTS \
                or not all(isinstance(t, str) for t in texts):
            return self._error(400, f"input must be 1..{MAX_TEXTS} strings")
        # Mnemosyne always sends its configured model name; a mismatch means
        # a tenant would store vectors from a different space.
        requested = req.get("model")
        if requested and requested != self.model.name:
            return self._error(400, f"model {requested!r} not served; this server serves {self.model.name!r}")

        t0 = time.monotonic()
        try:
            vectors = self.model.embed(texts)
        except Exception:
            log.exception("embedding failed")
            return self._error(500, "embedding failed")
        log.info("embedded %d text(s) in %.0f ms", len(texts), (time.monotonic() - t0) * 1000)

        self._send(200, {
            "object": "list",
            "model": self.model.name,
            "data": [{"object": "embedding", "index": i, "embedding": v} for i, v in enumerate(vectors)],
            "usage": {"prompt_tokens": 0, "total_tokens": 0},
        })


def main() -> None:
    parser = argparse.ArgumentParser(description="aaas-embed shared embedding service")
    parser.add_argument("--host", default=os.environ.get("AAAS_EMBED_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("AAAS_EMBED_PORT", "8800")))
    parser.add_argument("--max-concurrency", type=int,
                        default=int(os.environ.get("AAAS_EMBED_MAX_CONCURRENCY", "2")))
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s aaas-embed %(levelname)s %(message)s")
    Handler.model = Model(args.max_concurrency)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    log.info("serving %s (%d-dim) on %s:%d", Handler.model.name, Handler.model.dim, args.host, args.port)
    server.serve_forever()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Integration test for aaas-embed against a real Mnemosyne client.

Uses two interpreters to mirror production:
  SERVER_PY  has mnemosyne-memory[embeddings] (fastembed + model)
  TENANT_PY  has mnemosyne-memory core + numpy + sqlite-vec only (no fastembed)

Usage:
  AAAS_TEST_SERVER_PY=/path/srv/python AAAS_TEST_TENANT_PY=/path/ten/python \
    python3 shared/embed/test_embed.py
"""
from __future__ import annotations

import concurrent.futures
import json
import math
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
SERVER_PY = os.environ["AAAS_TEST_SERVER_PY"]
TENANT_PY = os.environ["AAAS_TEST_TENANT_PY"]

SENTENCES = [
    "The tenant prefers invoices to be sent on the first Monday of each month.",
    "Our office wifi password rotates every quarter.",
    "Remind me to renew the domain before it expires in March.",
    "Kucing saya suka tidur di atas papan kekunci.",
]

results: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    results.append((name, ok, detail))
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f" - {detail}" if detail else ""), flush=True)


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def run_py(python: str, code: str, env: dict, timeout: int = 300) -> tuple[dict, float]:
    t0 = time.monotonic()
    out = subprocess.run([python, "-c", code], env=env, capture_output=True, text=True, timeout=timeout)
    elapsed = time.monotonic() - t0
    if out.returncode != 0:
        raise RuntimeError(f"subprocess failed:\n{out.stderr[-3000:]}")
    return json.loads(out.stdout.strip().splitlines()[-1]), elapsed


def base_env(home: Path) -> dict:
    env = {k: v for k, v in os.environ.items() if not k.startswith("MNEMOSYNE_")}
    env["HERMES_HOME"] = str(home)
    env["MNEMOSYNE_DATA_DIR"] = str(home / "mnemosyne")
    env["PYTHONIOENCODING"] = "utf-8"
    return env


def post(url: str, payload: dict) -> tuple[int, dict]:
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def cosine(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    return dot / (math.sqrt(sum(x * x for x in a)) * math.sqrt(sum(y * y for y in b)))


EMBED_CODE = """
import json
from mnemosyne.core import embeddings as e
docs = e.embed(%r)
q = e.embed_query(%r)
print(json.dumps({"model": e._DEFAULT_MODEL, "available": e.available(),
                  "docs": None if docs is None else docs.tolist(),
                  "query": None if q is None else q.tolist()}))
"""

E2E_CODE = """
import json, sqlite3
from pathlib import Path
from mnemosyne.core.beam import BeamMemory
db = Path(%r)
m = BeamMemory(session_id="t", db_path=db)
for f in ["The tenant's accountant is named Farah and she prefers email.",
          "Server backups run nightly at 2am Malaysia time.",
          "The company mascot is a blue hornbill."]:
    m.remember(f, importance=0.9)
rows = sqlite3.connect(db).execute("select count(*) from memory_embeddings").fetchone()[0]
recall = {q: [h["content"] for h in m.recall(q, top_k=3)] for q in %r}
print(json.dumps({"stored_vectors": rows, "recall": recall}))
"""

QUERIES = ["accountant email", "when do backups happen", "mascot",
           "who handles our bookkeeping and taxes?", "what bird represents the company"]
KEYWORD_QUERY = "accountant email"


def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="aaas-embed-test-"))
    port = free_port()
    url = f"http://127.0.0.1:{port}/v1"

    # --- Local-mode reference (what a tenant with its own model would produce) ---
    local, _ = run_py(SERVER_PY, EMBED_CODE % (SENTENCES, SENTENCES[0]), base_env(tmp / "local"))
    local_e2e, _ = run_py(SERVER_PY, E2E_CODE % (str(tmp / "local.db"), QUERIES), base_env(tmp / "local"))
    check("local reference model is bge-small", local["model"] == "BAAI/bge-small-en-v1.5", local["model"])

    # --- Start aaas-embed ---
    log = open(tmp / "server.log", "w")
    server = subprocess.Popen([SERVER_PY, str(HERE / "server.py"), "--port", str(port)],
                              env=base_env(tmp / "server"), stdout=log, stderr=subprocess.STDOUT)
    tenant_env = base_env(tmp / "tenant")
    tenant_env["MNEMOSYNE_EMBEDDING_API_URL"] = url
    try:
        for _ in range(240):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as r:
                    health = json.loads(r.read())
                break
            except OSError:
                time.sleep(0.5)
        else:
            raise RuntimeError("server did not become healthy")
        check("health endpoint", health["dim"] == 384, json.dumps(health))

        # --- Remote mode through Mnemosyne's own client, in the tenant env ---
        remote, _ = run_py(TENANT_PY, EMBED_CODE % (SENTENCES, SENTENCES[0]), tenant_env)
        check("tenant (no fastembed) reports embeddings available", remote["available"] is True)
        check("remote returned vectors", remote["docs"] is not None and remote["query"] is not None)
        if remote["docs"]:
            dims_ok = all(len(v) == 384 for v in remote["docs"])
            sims = [cosine(a, b) for a, b in zip(local["docs"], remote["docs"])]
            sims.append(cosine(local["query"], remote["query"]))
            check("vector dim 384", dims_ok)
            check("remote == local vectors (cosine >= 0.9999)", min(sims) >= 0.9999,
                  f"min cosine {min(sims):.7f}")

        # --- End to end: store + semantic recall through the shared service ---
        e2e, _ = run_py(TENANT_PY, E2E_CODE % (str(tmp / "tenant.db"), QUERIES), tenant_env)
        check("memories stored with vectors", e2e["stored_vectors"] >= 3, f"{e2e['stored_vectors']} vectors")
        diff = [q for q in QUERIES if e2e["recall"][q] != local_e2e["recall"][q]]
        check("recall results identical to local mode", not diff,
              f"{len(QUERIES) - len(diff)}/{len(QUERIES)} queries match" + (f", differ: {diff}" if diff else ""))

        # --- Guards ---
        code, _ = post(f"{url}/embeddings", {"model": "some/other-model", "input": ["x"]})
        check("rejects a different model name", code == 400, f"HTTP {code}")
        code, _ = post(f"{url}/embeddings", {"model": "BAAI/bge-small-en-v1.5", "input": ["x"] * 257})
        check("rejects oversized batch", code == 400, f"HTTP {code}")

        # --- Concurrency: 50 tenants firing at once ---
        payload = {"model": "BAAI/bge-small-en-v1.5", "input": [SENTENCES[1]]}
        t0 = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(50) as pool:
            codes = list(pool.map(lambda _: post(f"{url}/embeddings", payload)[0], range(50)))
        check("50 concurrent requests all succeed", codes.count(200) == 50,
              f"{codes.count(200)}/50 in {time.monotonic() - t0:.1f}s")

        # --- Request content must not reach the log ---
        server_log = (tmp / "server.log").read_text(encoding="utf-8", errors="replace")
        check("no request text in server log", not any(s[:30] in server_log for s in SENTENCES))
    finally:
        server.terminate()
        server.wait(timeout=10)
        log.close()

    # --- Outage: service down; tenant must still remember and recall by keyword ---
    def outage(name: str, env: dict, db: str) -> None:
        try:
            e2e, elapsed = run_py(TENANT_PY, E2E_CODE % (str(tmp / db), [KEYWORD_QUERY]), env, timeout=900)
        except subprocess.TimeoutExpired:
            return check(f"outage ({name}): keyword recall still works", False, "exceeded 900s")
        hits = e2e["recall"][KEYWORD_QUERY]
        check(f"outage ({name}): keyword recall still works", bool(hits) and "Farah" in hits[0],
              f"{elapsed:.1f}s for 3 remembers + 1 recall")

    outage("connection refused", tenant_env, "tenant-refused.db")
    outage("blackholed", dict(tenant_env, MNEMOSYNE_EMBEDDING_API_URL="http://10.255.255.1:8800/v1"),
           "tenant-blackhole.db")

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""rag-converse.py — Single-file Linux RAG application with Hybrid Search & Chat.

Combines:
  1. PostgreSQL + pgvector (HNSW index, not IVFFlat)
  2. Nomic Embeddings via local Ollama (with required task prefixes)
  3. Hybrid Search: Reciprocal Rank Fusion (RRF) combining vector similarity + keyword tsvector + date filtering
  4. Interactive terminal chat interface with streaming responses and citations

Usage:
  ./rag-converse.py init                       # Create pgvector tables and HNSW indexes
  ./rag-converse.py ingest <file_or_dir>       # Batch ingest JSONL, CSV, or text/markdown
  ./rag-converse.py search "query" [--start YYYY-MM-DD] [--end YYYY-MM-DD]
  ./rag-converse.py chat                       # Interactive chat querying the database

Configuration (Env vars or CLI flags):
  DATABASE_URL  PostgreSQL connection string (default: postgresql://postgres:postgres@localhost:5432/rag_db)
  OLLAMA_HOST   Ollama server URL (default: http://127.0.0.1:11434)
  EMBED_MODEL   Embedding model (default: nomic-embed-text)
  CHAT_MODEL    Chat completion model (default: llama3.1:8b)
"""

import argparse
import csv
import glob
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

# ---------------------------------------------------------------------------
# Database Driver Adapter (supports psycopg2 or psycopg v3)
# ---------------------------------------------------------------------------
try:
    import psycopg2
    import psycopg2.extras
    DB_DRIVER = "psycopg2"
except ImportError:
    try:
        import psycopg
        DB_DRIVER = "psycopg"
    except ImportError:
        DB_DRIVER = None


def get_db_connection(db_url):
    if DB_DRIVER is None:
        sys.exit(
            "\n[Error] PostgreSQL driver not found.\n"
            "Please install psycopg2 or psycopg:\n"
            "    pip install psycopg2-binary\n"
            "  or:\n"
            "    pip install psycopg[binary]\n"
        )
    if DB_DRIVER == "psycopg2":
        conn = psycopg2.connect(db_url)
        conn.autocommit = False
        return conn
    else:
        conn = psycopg.connect(db_url)
        conn.autocommit = False
        return conn


# ---------------------------------------------------------------------------
# Local Config & Address Resolution
# ---------------------------------------------------------------------------
def resolve_ollama_url():
    """Resolve Ollama endpoint from env or ~/.ragnarok/local.conf."""
    if os.environ.get("OLLAMA_HOST"):
        return os.environ["OLLAMA_HOST"].rstrip("/")
    if os.environ.get("OLLAMA_URL"):
        return os.environ["OLLAMA_URL"].rstrip("/")

    # Check local.conf if present
    conf_path = os.path.expanduser("~/.ragnarok/local.conf")
    if os.path.isfile(conf_path):
        try:
            with open(conf_path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("OLLAMA_URL="):
                        val = line.split("=", 1)[1].strip().strip('"').strip("'")
                        if val:
                            return val.rstrip("/")
                    if line.startswith("ALEXUS_HOST="):
                        val = line.split("=", 1)[1].strip().strip('"').strip("'")
                        if val:
                            return f"http://{val}:11434"
        except Exception:
            pass

    return "http://127.0.0.1:11434"


DEFAULT_DB_URL = os.environ.get(
    "DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/rag_db"
)
DEFAULT_OLLAMA_URL = resolve_ollama_url()
DEFAULT_EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")
DEFAULT_CHAT_MODEL = os.environ.get("CHAT_MODEL", "llama3.1:8b")


# ---------------------------------------------------------------------------
# Embedding Engine (Ollama with Nomic task prefixes)
# ---------------------------------------------------------------------------
class OllamaClient:
    def __init__(self, base_url=DEFAULT_OLLAMA_URL, embed_model=DEFAULT_EMBED_MODEL, chat_model=DEFAULT_CHAT_MODEL):
        self.base_url = base_url.rstrip("/")
        self.embed_model = embed_model
        self.chat_model = chat_model

    def embed(self, texts, is_query=False):
        """Generate embeddings with task prefixes.

        Nomic requirement:
          - documents must use 'search_document: <text>'
          - queries must use 'search_query: <text>'
        """
        prefix = "search_query: " if is_query else "search_document: "
        prefixed = [prefix + t for t in texts]

        # Use /api/embed (batch endpoint in Ollama >= 0.1.44)
        url = f"{self.base_url}/api/embed"
        payload = json.dumps({"model": self.embed_model, "input": prefixed}).encode("utf-8")
        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})

        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                return data.get("embeddings", [])
        except urllib.error.HTTPError as e:
            # Fallback to legacy single /api/embeddings if /api/embed 404s
            if e.code == 404:
                return self._embed_legacy_fallback(prefixed)
            err_body = e.read().decode("utf-8", errors="ignore")
            raise RuntimeError(f"Ollama embedding error ({e.code}): {err_body}") from e
        except Exception as e:
            raise RuntimeError(f"Failed to connect to Ollama at {self.base_url}: {e}") from e

    def _embed_legacy_fallback(self, prefixed_texts):
        results = []
        for text in prefixed_texts:
            url = f"{self.base_url}/api/embeddings"
            payload = json.dumps({"model": self.embed_model, "prompt": text}).encode("utf-8")
            req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                results.append(data.get("embedding", []))
        return results

    def chat_stream(self, messages, temperature=0.3):
        """Stream chat tokens from Ollama /api/chat."""
        url = f"{self.base_url}/api/chat"
        payload = json.dumps({
            "model": self.chat_model,
            "messages": messages,
            "options": {"temperature": temperature},
            "stream": True
        }).encode("utf-8")

        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                for line in resp:
                    if line:
                        chunk = json.loads(line.decode("utf-8"))
                        msg = chunk.get("message", {})
                        content = msg.get("content", "")
                        if content:
                            yield content
                        if chunk.get("done", False):
                            break
        except Exception as e:
            yield f"\n[Error streaming from Ollama: {e}]\n"


# ---------------------------------------------------------------------------
# Schema Management
# ---------------------------------------------------------------------------
SCHEMA_SQL = """
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS documents (
    id BIGSERIAL PRIMARY KEY,
    title TEXT,
    content TEXT NOT NULL,
    publish_date DATE,
    embedding vector(768),
    tsv tsvector GENERATED ALWAYS AS (
        to_tsvector('english', coalesce(title, '') || ' ' || content)
    ) STORED
);

CREATE INDEX IF NOT EXISTS idx_documents_publish_date ON documents (publish_date);
CREATE INDEX IF NOT EXISTS idx_documents_tsv ON documents USING gin (tsv);
CREATE INDEX IF NOT EXISTS idx_documents_embedding_hnsw 
ON documents USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);
"""

def cmd_init(args):
    """Initialize PostgreSQL extension, tables, and HNSW/GIN indexes."""
    print(f"[*] Connecting to PostgreSQL: {args.db}")
    conn = get_db_connection(args.db)
    cursor = conn.cursor()
    try:
        print("[*] Creating extension 'vector' and 'documents' table with HNSW index...")
        cursor.execute(SCHEMA_SQL)
        conn.commit()
        print("[+] Success! Database initialized and ready for hybrid search.")
    except Exception as e:
        conn.rollback()
        print(f"[-] Init failed: {e}")
        sys.exit(1)
    finally:
        cursor.close()
        conn.close()


# ---------------------------------------------------------------------------
# Chunking & Document Ingestion
# ---------------------------------------------------------------------------
def chunk_text(text, max_chars=1200, overlap=200):
    """Clean sliding window chunker preserving paragraph breaks where possible."""
    text = text.strip()
    if len(text) <= max_chars:
        return [text]

    chunks = []
    start = 0
    while start < len(text):
        end = start + max_chars
        if end >= len(text):
            chunks.append(text[start:].strip())
            break

        # Try to find paragraph break or newline
        split_at = text.rfind("\n\n", start + overlap, end)
        if split_at == -1:
            split_at = text.rfind("\n", start + overlap, end)
        if split_at == -1:
            split_at = text.rfind(". ", start + overlap, end)
            if split_at != -1:
                split_at += 1
        if split_at == -1:
            split_at = end

        chunk = text[start:split_at].strip()
        if chunk:
            chunks.append(chunk)
        start = split_at - overlap if split_at - overlap > start else split_at

    return chunks


def load_raw_documents(path):
    """Load items from JSONL, JSON, CSV, or plain text files."""
    docs = []
    if os.path.isdir(path):
        files = glob.glob(os.path.join(path, "**", "*.*"), recursive=True)
    else:
        files = [path]

    for fpath in files:
        ext = os.path.splitext(fpath)[1].lower()
        if ext == ".jsonl":
            with open(fpath, "r", encoding="utf-8") as f:
                for line in f:
                    if line.strip():
                        item = json.loads(line)
                        docs.append({
                            "title": item.get("title") or os.path.basename(fpath),
                            "content": item.get("content") or item.get("text") or "",
                            "publish_date": item.get("publish_date") or item.get("date")
                        })
        elif ext == ".json":
            with open(fpath, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, list):
                    for item in data:
                        docs.append({
                            "title": item.get("title") or os.path.basename(fpath),
                            "content": item.get("content") or item.get("text") or "",
                            "publish_date": item.get("publish_date") or item.get("date")
                        })
                elif isinstance(data, dict):
                    docs.append({
                        "title": data.get("title") or os.path.basename(fpath),
                        "content": data.get("content") or data.get("text") or "",
                        "publish_date": data.get("publish_date") or data.get("date")
                    })
        elif ext == ".csv":
            with open(fpath, "r", encoding="utf-8") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    docs.append({
                        "title": row.get("title") or row.get("name") or os.path.basename(fpath),
                        "content": row.get("content") or row.get("text") or row.get("body") or "",
                        "publish_date": row.get("publish_date") or row.get("date")
                    })
        elif ext in (".txt", ".md"):
            with open(fpath, "r", encoding="utf-8") as f:
                content = f.read()
                # Try to parse date from file mtime or frontmatter
                mtime_date = datetime.fromtimestamp(os.path.getmtime(fpath)).strftime("%Y-%m-%d")
                docs.append({
                    "title": os.path.basename(fpath),
                    "content": content,
                    "publish_date": mtime_date
                })

    return [d for d in docs if d["content"].strip()]


def cmd_ingest(args):
    """Batch ingest documents into PostgreSQL with Nomic embeddings."""
    client = OllamaClient(args.ollama, args.embed_model, args.chat_model)
    raw_docs = load_raw_documents(args.input)
    if not raw_docs:
        print(f"[-] No valid documents found in {args.input}")
        return

    print(f"[*] Loaded {len(raw_docs)} source documents. Chunking...")
    chunked_records = []
    for doc in raw_docs:
        chunks = chunk_text(doc["content"])
        for idx, chunk in enumerate(chunks):
            title = doc["title"]
            if len(chunks) > 1:
                title = f"{doc['title']} (Part {idx + 1})"
            chunked_records.append({
                "title": title,
                "content": chunk,
                "publish_date": doc["publish_date"]
            })

    total_chunks = len(chunked_records)
    print(f"[*] Prepared {total_chunks} chunks. Generating embeddings and inserting...")

    conn = get_db_connection(args.db)
    cursor = conn.cursor()

    batch_size = args.batch_size
    inserted = 0
    t0 = time.time()

    try:
        for i in range(0, total_chunks, batch_size):
            batch = chunked_records[i : i + batch_size]
            texts = [b["content"] for b in batch]
            
            # Embed with Nomic 'search_document: ' prefix
            embeddings = client.embed(texts, is_query=False)

            rows_to_insert = []
            for b, emb in zip(batch, embeddings):
                # Format embedding as pgvector literal string: "[0.123, -0.456, ...]"
                emb_str = "[" + ",".join(f"{x:.6f}" for x in emb) + "]"
                date_val = b["publish_date"] if b["publish_date"] else None
                rows_to_insert.append((b["title"], b["content"], date_val, emb_str))

            if DB_DRIVER == "psycopg2":
                psycopg2.extras.execute_values(
                    cursor,
                    """
                    INSERT INTO documents (title, content, publish_date, embedding)
                    VALUES %s
                    """,
                    rows_to_insert,
                    template="(%s, %s, %s, %s::vector)"
                )
            else:
                with cursor.copy(
                    "COPY documents (title, content, publish_date, embedding) FROM STDIN"
                ) as copy:
                    for row in rows_to_insert:
                        copy.write_row(row)

            conn.commit()
            inserted += len(batch)
            elapsed = time.time() - t0
            rate = inserted / elapsed if elapsed > 0 else 0
            print(f"\r    -> Ingested {inserted}/{total_chunks} chunks ({rate:.1f} chunks/sec)", end="")

        print(f"\n[+] Ingestion complete! {inserted} chunks stored in {time.time() - t0:.2f}s.")
    except Exception as e:
        conn.rollback()
        print(f"\n[-] Ingestion failed: {e}")
        sys.exit(1)
    finally:
        cursor.close()
        conn.close()


# ---------------------------------------------------------------------------
# Hybrid Search (RRF: Semantic + Full-Text + Date Filter)
# ---------------------------------------------------------------------------
RRF_SQL = """
WITH semantic AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY embedding <=> %s::vector) AS rank
    FROM documents
    WHERE (%s::date IS NULL OR publish_date >= %s::date)
      AND (%s::date IS NULL OR publish_date <= %s::date)
    ORDER BY embedding <=> %s::vector
    LIMIT 50
),
keyword AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY ts_rank_cd(tsv, plainto_tsquery('english', %s)) DESC) AS rank
    FROM documents
    WHERE tsv @@ plainto_tsquery('english', %s)
      AND (%s::date IS NULL OR publish_date >= %s::date)
      AND (%s::date IS NULL OR publish_date <= %s::date)
    ORDER BY ts_rank_cd(tsv, plainto_tsquery('english', %s)) DESC
    LIMIT 50
)
SELECT d.id, d.title, d.content, d.publish_date,
       (COALESCE(1.0 / (60 + s.rank), 0.0) + COALESCE(1.0 / (60 + k.rank), 0.0)) AS score,
       s.rank AS sem_rank,
       k.rank AS kw_rank
FROM (
    SELECT id FROM semantic
    UNION
    SELECT id FROM keyword
) matched
JOIN documents d ON d.id = matched.id
LEFT JOIN semantic s ON s.id = d.id
LEFT JOIN keyword k ON k.id = d.id
ORDER BY score DESC
LIMIT %s;
"""

def hybrid_search(cursor, client, query, min_date=None, max_date=None, top_k=5):
    """Execute hybrid search using Reciprocal Rank Fusion."""
    # 1. Embed query with 'search_query: ' prefix
    embeddings = client.embed([query], is_query=True)
    if not embeddings:
        return []
    q_emb_str = "[" + ",".join(f"{x:.6f}" for x in embeddings[0]) + "]"

    # 2. Execute RRF query
    params = (
        q_emb_str, min_date, min_date, max_date, max_date, q_emb_str, # semantic CTE
        query, query, min_date, min_date, max_date, max_date, query,  # keyword CTE
        top_k                                                         # final limit
    )
    cursor.execute(RRF_SQL, params)
    rows = cursor.fetchall()
    
    results = []
    for r in rows:
        results.append({
            "id": r[0],
            "title": r[1],
            "content": r[2],
            "publish_date": str(r[3]) if r[3] else "No date",
            "score": float(r[4]),
            "sem_rank": r[5],
            "kw_rank": r[6]
        })
    return results


def cmd_search(args):
    """Run standalone hybrid search."""
    client = OllamaClient(args.ollama, args.embed_model, args.chat_model)
    conn = get_db_connection(args.db)
    cursor = conn.cursor()

    t0 = time.time()
    results = hybrid_search(cursor, client, args.query, args.start, args.end, args.k)
    duration = time.time() - t0

    print(f"\n[+] Hybrid Search Results for: \"{args.query}\" ({duration:.3f}s)")
    if args.start or args.end:
        print(f"    Date filter: {args.start or 'Any'} to {args.end or 'Any'}")
    print("-" * 75)

    if not results:
        print("    No matching documents found.")
        return

    for rank, item in enumerate(results, 1):
        sem = f"#{item['sem_rank']}" if item['sem_rank'] else "none"
        kw = f"#{item['kw_rank']}" if item['kw_rank'] else "none"
        snippet = item['content'].replace("\n", " ")[:200]
        print(f"#{rank} [Score: {item['score']:.4f} | Sem: {sem} | KW: {kw}] {item['title']} ({item['publish_date']})")
        print(f"    {snippet}...\n")

    cursor.close()
    conn.close()


# ---------------------------------------------------------------------------
# Interactive Chat
# ---------------------------------------------------------------------------
SYSTEM_PROMPT = """You are a knowledgeable, direct AI assistant.
Answer the user's questions based on the provided reference context from their personal documents and notes.
- Use plain English.
- Cite facts accurately. Reference sources using [1], [2], etc.
- If the context does not contain the answer, say so honestly rather than hallucinating."""

def cmd_chat(args):
    """Launch interactive terminal chat with live RAG retrieval."""
    client = OllamaClient(args.ollama, args.embed_model, args.chat_model)
    conn = get_db_connection(args.db)
    cursor = conn.cursor()

    min_date = args.start
    max_date = args.end
    top_k = args.k

    print("=" * 75)
    print(" RAG-Converse: Hybrid Postgres Search & Terminal Chat")
    print(f" Model: {client.chat_model} · Embedder: {client.embed_model}")
    print(f" DB: {args.db}")
    print(" Commands: /filter start=YYYY-MM-DD end=YYYY-MM-DD · /filter clear · /k N · /clear · /exit")
    print("=" * 75)

    history = []
    last_hits = []

    try:
        while True:
            try:
                user_input = input("\nYou > ").strip()
            except (KeyboardInterrupt, EOFError):
                print("\nGoodbye!")
                break

            if not user_input:
                continue

            # Command handling
            if user_input.lower() in ("/exit", "/quit"):
                print("Goodbye!")
                break
            elif user_input.lower() == "/clear":
                history = []
                last_hits = []
                print("[*] Conversation history cleared.")
                continue
            elif user_input.lower() == "/sources":
                if not last_hits:
                    print("[!] No recent sources retrieved.")
                else:
                    print("\n--- Last Retrieved Sources ---")
                    for i, h in enumerate(last_hits, 1):
                        print(f"[{i}] {h['title']} ({h['publish_date']}) [Score: {h['score']:.4f}]")
                        print(f"    {h['content'][:400]}...\n")
                continue
            elif user_input.startswith("/filter"):
                parts = user_input.split()
                if len(parts) == 2 and parts[1].lower() == "clear":
                    min_date, max_date = None, None
                    print("[*] Date filter cleared.")
                else:
                    for p in parts[1:]:
                        if p.startswith("start="):
                            min_date = p.split("=", 1)[1]
                        elif p.startswith("end="):
                            max_date = p.split("=", 1)[1]
                    print(f"[*] Active filter: {min_date or 'Any'} to {max_date or 'Any'}")
                continue
            elif user_input.startswith("/k"):
                try:
                    top_k = int(user_input.split()[1])
                    print(f"[*] Top-K set to {top_k}")
                except Exception:
                    print("[!] Usage: /k <integer>")
                continue
            elif user_input == "/help":
                print("Commands:")
                print("  /filter start=YYYY-MM-DD end=YYYY-MM-DD  Set date bounds")
                print("  /filter clear                           Remove date bounds")
                print("  /k 5                                    Change number of retrieved excerpts")
                print("  /sources                                Show full text of last retrieved citations")
                print("  /clear                                  Reset conversation context")
                print("  /exit                                   Exit chat")
                continue

            # 1. Retrieve relevant context via Hybrid RRF Search
            t0 = time.time()
            hits = hybrid_search(cursor, client, user_input, min_date, max_date, top_k)
            retrieval_sec = time.time() - t0
            last_hits = hits

            # 2. Build augmented prompt
            context_blocks = []
            for i, h in enumerate(hits, 1):
                context_blocks.append(
                    f"[{i}] (Date: {h['publish_date']} | Title: {h['title']})\n{h['content']}"
                )
            context_str = "\n\n---\n\n".join(context_blocks) if context_blocks else "No relevant documents found."

            user_turn_with_context = (
                f"Reference Documents:\n{context_str}\n\n"
                f"User Question:\n{user_input}"
            )

            # Messages payload
            messages = [{"role": "system", "content": SYSTEM_PROMPT}]
            for h in history[-6:]:  # keep last 3 turns of back-and-forth
                messages.append(h)
            messages.append({"role": "user", "content": user_turn_with_context})

            # 3. Stream Response
            print(f"\nAssistant [{len(hits)} sources retrieved in {retrieval_sec:.2f}s] > ", end="", flush=True)
            full_response = ""
            for chunk in client.chat_stream(messages):
                sys.stdout.write(chunk)
                sys.stdout.flush()
                full_response += chunk
            print()

            # 4. Display source citations footer
            if hits:
                cites = [f"[{i}] {h['title']} ({h['publish_date']})" for i, h in enumerate(hits, 1)]
                print(f"\033[90mSources: {' · '.join(cites)}\033[0m")

            # Update history
            history.append({"role": "user", "content": user_input})
            history.append({"role": "assistant", "content": full_response})

    finally:
        cursor.close()
        conn.close()


# ---------------------------------------------------------------------------
# CLI Entrypoint
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Single-file Linux RAG app with Hybrid Search & Chat",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--db", default=DEFAULT_DB_URL, help="PostgreSQL connection string")
    parser.add_argument("--ollama", default=DEFAULT_OLLAMA_URL, help="Ollama server URL")
    parser.add_argument("--embed-model", default=DEFAULT_EMBED_MODEL, help="Embedding model name")
    parser.add_argument("--chat-model", default=DEFAULT_CHAT_MODEL, help="Chat model name")

    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    # init
    p_init = subparsers.add_parser("init", help="Create tables and indexes in PostgreSQL")
    p_init.set_defaults(func=cmd_init)

    # ingest
    p_ingest = subparsers.add_parser("ingest", help="Batch ingest documents (JSONL, CSV, TXT, MD)")
    p_ingest.add_argument("input", help="File or directory path to ingest")
    p_ingest.add_argument("--batch-size", type=int, default=32, help="Embedding batch size (default: 32)")
    p_ingest.set_defaults(func=cmd_ingest)

    # search
    p_search = subparsers.add_parser("search", help="Execute hybrid RRF search query")
    p_search.add_argument("query", help="Search query string")
    p_search.add_argument("--start", help="Minimum date (YYYY-MM-DD)")
    p_search.add_argument("--end", help="Maximum date (YYYY-MM-DD)")
    p_search.add_argument("-k", type=int, default=5, help="Top-K results (default: 5)")
    p_search.set_defaults(func=cmd_search)

    # chat
    p_chat = subparsers.add_parser("chat", help="Launch interactive terminal chat")
    p_chat.add_argument("--start", help="Initial minimum date filter (YYYY-MM-DD)")
    p_chat.add_argument("--end", help="Initial maximum date filter (YYYY-MM-DD)")
    p_chat.add_argument("-k", type=int, default=4, help="Retrieved context chunks per turn (default: 4)")
    p_chat.set_defaults(func=cmd_chat)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

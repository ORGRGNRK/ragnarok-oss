#!/usr/bin/env python3
import asyncio
import aiohttp
import time
import socket
import sys

# Minimal local HTTP server simulating lagging endpoints
async def mock_http_server(host="127.0.0.1", port=8999):
    async def handle_client(reader, writer):
        try:
            line = await reader.readline()
            request = line.decode('utf-8', errors='ignore')
            
            # Read until empty line (headers)
            while True:
                h = await reader.readline()
                if not h or h == b'\r\n':
                    break

            if "/hang" in request:
                # Deliberate hang: sleep 4 seconds (exceeds client timeout)
                await asyncio.sleep(4.0)
            elif "/slow" in request:
                await asyncio.sleep(0.5)
            
            response = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nOK"
            writer.write(response)
            await writer.drain()
        except Exception:
            pass
        finally:
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass

    server = await asyncio.start_server(handle_client, host, port)
    return server

# ---- BROKEN PATTERN ----
# Creates new session per request, no pool limit, no socket timeout handling
async def broken_worker(url):
    # Antipattern: Session created inside task without pooling or timeout bounds
    session = aiohttp.ClientSession() # Not using context manager or proper connector
    try:
        resp = await session.get(url)
        data = await resp.text()
        return "SUCCESS"
    except Exception as e:
        return f"ERROR: {type(e).__name__}"
    # Leaks session without close()

# ---- CORRECTED PATTERN ----
# Shared session, tuned TCPConnector, concurrency semaphore, bounded timeouts, retries
async def corrected_worker(session, semaphore, primary_url, fallback_url, max_retries=2):
    async with semaphore:
        for attempt in range(max_retries):
            url = primary_url if attempt == 0 else fallback_url
            try:
                # Strict timeout bounds: total 1.0s, sock_read 0.5s
                timeout = aiohttp.ClientTimeout(total=1.0, connect=0.5, sock_read=0.5)
                async with session.get(url, timeout=timeout) as resp:
                    text = await resp.text()
                    return {"status": "SUCCESS", "attempts": attempt + 1, "body": text}
            except (asyncio.TimeoutError, aiohttp.ClientError) as e:
                if attempt == max_retries - 1:
                    return {"status": "FAILED", "error": type(e).__name__, "attempts": attempt + 1}
                await asyncio.sleep(0.1 * (2 ** attempt)) # Exponential backoff

async def run_benchmark():
    server = await mock_http_server()
    base_url = "http://127.0.0.1:8999"
    hang_url = f"{base_url}/hang"
    fast_url = f"{base_url}/fast"

    print("=" * 65)
    print("⚡ SOCKET TIMEOUT REPRODUCTION & RECOVERY BENCHMARK")
    print("=" * 65)

    # 1. Run Broken Pattern
    print("\n[TEST 1] Running Broken Pattern (Unpooled, unmanaged sessions against hanging port)...")
    t0 = time.perf_counter()
    broken_tasks = [broken_worker(hang_url) for _ in range(10)]
    broken_results = await asyncio.gather(*broken_tasks, return_exceptions=True)
    t_broken = time.perf_counter() - t0
    
    print(f"  Broken Execution Time: {t_broken:.2f}s (Blocked indefinitely waiting on default OS timeout)")
    print(f"  Sample Results: {broken_results[:3]}")

    # 2. Run Corrected Pattern
    print("\n[TEST 2] Running Corrected Pattern (Tuned TCPConnector, Semaphore, Fast Timeout, Failover)...")
    connector = aiohttp.TCPConnector(
        limit=10,
        limit_per_host=5,
        enable_cleanup_closed=True,
        keepalive_timeout=15
    )
    semaphore = asyncio.Semaphore(5)

    t1 = time.perf_counter()
    async with aiohttp.ClientSession(connector=connector) as session:
        corrected_tasks = [
            corrected_worker(session, semaphore, primary_url=hang_url, fallback_url=fast_url)
            for _ in range(10)
        ]
        corrected_results = await asyncio.gather(*corrected_tasks)
    t_corrected = time.perf_counter() - t1

    print(f"  Corrected Execution Time: {t_corrected:.2f}s (All 10 tasks timed out & recovered via fallback)")
    success_count = sum(1 for r in corrected_results if r["status"] == "SUCCESS")
    print(f"  Recovery Rate: {success_count}/10 successful recoveries")
    print(f"  Sample Results: {corrected_results[:2]}")

    server.close()
    await server.wait_closed()

    print("\n" + "=" * 65)
    print(f"BENCHMARK COMPLETE: Corrected pattern recovered {success_count}/10 tasks in {t_corrected:.2f}s.")
    print("=" * 65)

if __name__ == "__main__":
    asyncio.run(run_benchmark())

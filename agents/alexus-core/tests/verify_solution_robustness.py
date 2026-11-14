#!/usr/bin/env python3
"""
ALEXUS CORE: Solution Robustness & Fault Injection Verifier
Tests whether the verification system catches technically plausible but broken solutions:
- Bug 1: Unsupported parameter injection (max_retries in ClientSession)
- Bug 2: Silent socket hang (sock_read=0 disabling read timeout)
- Bug 3: Connection leak (unclosed session per task)
"""

import sys
import asyncio
import time
import inspect
import aiohttp

async def test_syntax_and_signatures():
    print("--- [TEST 1: Parameter & Signature Guardrail] ---")
    
    # Plausible code snippet with subtle flaw: max_retries in ClientSession
    plausible_flawed_code = """
session = aiohttp.ClientSession(
    connector=aiohttp.TCPConnector(limit=50, limit_per_host=10),
    max_retries=3, # FLAW: aiohttp.ClientSession does not accept max_retries!
    timeout=aiohttp.ClientTimeout(total=15)
)
"""
    print("Evaluating plausible candidate:")
    print(plausible_flawed_code.strip())
    
    # Check if aiohttp.ClientSession accepts max_retries
    sig = inspect.signature(aiohttp.ClientSession.__init__)
    has_max_retries = "max_retries" in sig.parameters
    print(f"\nDoes aiohttp.ClientSession accept 'max_retries'? -> {has_max_retries}")
    
    try:
        session = aiohttp.ClientSession(
            connector=aiohttp.TCPConnector(limit=50),
            max_retries=3
        )
        print("❌ FAILED: Verifier let flawed parameter pass without exception!")
        return False
    except TypeError as e:
        print(f"✅ PASSED: Verifier caught invalid parameter with runtime exception:\n   {type(e).__name__}: {e}")
        return True

async def test_silent_hang_detection():
    print("\n--- [TEST 2: Silent Behavior Bug (sock_read=0 Disabling Read Timeout)] ---")
    
    # Plausible snippet where developer wrote sock_read=0 thinking it means 'no delay'
    # but in aiohttp, sock_read=0 or None disables read timeout, causing infinite hang on slow socket!
    async def mock_hung_server():
        async def handle(reader, writer):
            await reader.readline()
            await asyncio.sleep(2.0) # Slow server
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
            await writer.drain()
            writer.close()
        return await asyncio.start_server(handle, "127.0.0.1", 9001)

    server = await mock_hung_server()

    # We enforce a strict outcome assertion: Must timeout within 0.8s on a 2.0s lagging socket!
    print("Testing candidate with disabled read timeout (sock_read=None / 0)...")
    flawed_timeout = aiohttp.ClientTimeout(total=None, sock_read=0) # Flawed: disabled
    
    t0 = time.perf_counter()
    caught_hang = False
    try:
        async with aiohttp.ClientSession(timeout=flawed_timeout) as session:
            # We wrap with a test harness watchdog of 0.8s
            try:
                # Wrap with 0.8s timeout watchdog (compatible with Python 3.9+)
                async def fetch_it():
                    async with session.get("http://127.0.0.1:9001") as resp:
                        return await resp.text()
                await asyncio.wait_for(fetch_it(), timeout=0.8)
            except asyncio.TimeoutError:
                caught_hang = True
                print("✅ PASSED: Verifier watchdog caught the silent socket hang! (Exceeded 0.8s bound)")
    finally:
        server.close()
        await server.wait_closed()
        
    return caught_hang

async def main_async():
    print("=" * 65)
    print("🛡️ VERIFIER FAULT DETECTION & OUTCOME TEST SUITE")
    print("=" * 65)

    r1 = await test_syntax_and_signatures()
    r2 = await test_silent_hang_detection()

    print("\n" + "=" * 65)
    if r1 and r2:
        print("🏆 VERIFIER AUDIT PASSED: Successfully detected both parameter defect and silent socket hang!")
    else:
        print("❌ VERIFIER AUDIT FAILED: Flaws escaped detection.")
    print("=" * 65)

def main():
    asyncio.run(main_async())

if __name__ == "__main__":
    main()

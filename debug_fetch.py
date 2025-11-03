import sys
import urllib.request
import urllib.error
import ssl
import traceback

# Create SSL context that ignores certificate verification
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

# Get URL from command line or use default
url = sys.argv[1] if len(sys.argv) > 1 else "https://example.com/myvault"

req = urllib.request.Request(url, headers={"User-Agent": "VaultFinder/1.0"})

try:
    with urllib.request.urlopen(req, timeout=30, context=ctx) as r:
        print("URL:", url)
        print("STATUS:", r.getcode())
        print("HEADERS:", dict(r.getheaders()))
        print("\nBODY (first 2000 bytes):")
        print(r.read(2000).decode("utf-8", "replace"))

except urllib.error.HTTPError as e:
    print("URL:", url)
    print("HTTPError:", e.code)
    hdrs = dict(e.headers) if getattr(e, "headers", None) else {}
    print("HEADERS:", hdrs)
    try:
        print("\nBODY (first 2000 bytes):")
        print(e.read(2000).decode("utf-8", "replace"))
    except Exception:
        print("(no body or failed to read body)")

except Exception as e:
    print("EXCEPTION:", type(e).__name__, str(e))
    traceback.print_exc()
    sys.exit(2)

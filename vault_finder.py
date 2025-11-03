#!/usr/bin/env python3
import urllib.request, urllib.error, ssl, socket, json, re, time, traceback
from pathlib import Path
from datetime import datetime


def probe_url(url, ctx, timeout=30, retries=2, backoff=1.0):
    last_exc = None
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'VaultFinder/1.0'})
            try:
                with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
                    status = r.getcode()
                    headers = dict(r.getheaders())
                    body = r.read(8192).decode('utf-8', 'replace')
            except urllib.error.HTTPError as e:
                status = e.code
                headers = dict(e.headers) if getattr(e, 'headers', None) else {}
                try:
                    body = e.read(8192).decode('utf-8', 'replace')
                except Exception:
                    body = ''
            return status, headers, body, None
        except Exception as e:
            last_exc = e
            # retry transient network errors
            if attempt < retries:
                time.sleep(backoff * (2 ** attempt))
                continue
            return None, {}, '', e


def main():
    tfile = Path('targets.txt')
    sfile = Path('seeds.txt')
    if not tfile.exists() or not sfile.exists():
        print(json.dumps({'error': 'targets.txt or seeds.txt missing'}))
        return

    targets = [l.strip() for l in tfile.read_text(encoding='utf-8').splitlines() if l.strip()]
    seeds = [l.strip() for l in sfile.read_text(encoding='utf-8').splitlines() if l.strip()]

    templates = [
        'https://{target}/{seed}',
        'https://{target}/{seed}/',
        'https://{target}/.well-known/{seed}',
        'http://{target}/{seed}',
        # removed noisy 'http://{seed}.{target}/' template
        'https://{seed}.vault.azure.net/',
        'https://{seed}.vault.azure.net/secrets?api-version=7.3',
        'https://{target}/v1/sys/health',
        'https://{target}/v1/secret/{seed}',
        'https://{target}/ui/',
    ]

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    socket.setdefaulttimeout(30)

    outpath = Path('results.jsonl')
    with outpath.open('w', encoding='utf-8') as outf:
        for target in targets:
            for seed in seeds:
                for tpl in templates:
                    url = tpl.format(target=target, seed=seed)
                    rec = {
                        'target': target,
                        'seed': seed,
                        'url': url,
                        'ts': datetime.utcnow().isoformat() + 'Z'
                    }
                    status, headers, body, err = probe_url(url, ctx, timeout=30, retries=2, backoff=1.0)
                    if err:
                        rec['error'] = f'{type(err).__name__}: {err}'
                        rec['traceback'] = traceback.format_exc()
                    else:
                        rec['status'] = status
                        rec['headers'] = headers
                        rec['www_authenticate'] = headers.get('WWW-Authenticate', '')
                        rec['body_snippet'] = body[:2000]
                        fps = []
                        wa = rec['www_authenticate']
                        if 'login.windows.net' in wa or 'authorization_uri' in wa or 'Bearer error' in wa:
                            fps.append('azure_key_vault_fingerprint')
                        if '"initialized"' in body and '"sealed"' in body:
                            fps.append('hashicorp_vault_health')
                        rec['fingerprints'] = fps
                        rec['matches'] = [s for s in seeds if re.search(re.escape(s), body, re.IGNORECASE)]
                    outf.write(json.dumps(rec, ensure_ascii=False) + '\n')
                    outf.flush()


if __name__ == '__main__':
    main()

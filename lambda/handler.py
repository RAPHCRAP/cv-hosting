"""Multi-tenant CV host — AWS Lambda (function URL, payload format 2.0).

Responsibilities
  GET  /                      -> gated upload page (HTML)
  POST /upload                -> validate + write tenants/<roll>/site/{index.html,style.css,cv.pdf}
  GET  /u/<roll>/             -> that tenant's index.html, footer stamped "Lambda <fn>"
  GET  /u/<roll>/style.css    -> text/css
  GET  /u/<roll>/cv.pdf       -> application/pdf (binary, base64)
  anything else               -> 404 short HTML page

Config comes from environment variables (never hard-coded):
  BUCKET           target S3 bucket
  PREFIX           tenant root prefix (e.g. "tenants")
  UPLOAD_PASSCODE  shared gate for uploads
  EC2_BASE         optional, e.g. http://1.2.3.4 ; used to also hand back the EC2 link
"""

import base64
import json
import os
import re
import time

import boto3

s3 = boto3.client("s3")

BUCKET = os.environ["BUCKET"]
PREFIX = os.environ.get("PREFIX", "tenants").strip("/")
PASSCODE = os.environ.get("UPLOAD_PASSCODE", "")
EC2_BASE = os.environ.get("EC2_BASE", "").rstrip("/")

ROLL_RE = re.compile(r"^[a-z0-9-]{3,20}$")

# size caps (bytes), matching the assignment
MAX_HTML = 100 * 1024
MAX_CSS = 100 * 1024
MAX_PDF = 1 * 1024 * 1024

CSP = (
    "default-src 'none'; img-src 'self' data:; "
    "style-src 'self' 'unsafe-inline'; font-src 'self'; base-uri 'none'"
)


def _resp(status, body, content_type="text/html; charset=utf-8",
          extra_headers=None, is_b64=False):
    headers = {"Content-Type": content_type}
    if extra_headers:
        headers.update(extra_headers)
    return {
        "statusCode": status,
        "headers": headers,
        "body": body,
        "isBase64Encoded": is_b64,
    }


def _json(status, obj):
    return _resp(status, json.dumps(obj), "application/json")


def _log(fn, path, status, start):
    ms = int((time.time() - start) * 1000)
    print(json.dumps({"fn": fn, "path": path, "status": status, "ms": ms}))


def _get_object(key):
    obj = s3.get_object(Bucket=BUCKET, Key=key)
    return obj["Body"].read()


def _serve_cv(roll, filename, fn):
    key = f"{PREFIX}/{roll}/site/{filename}"
    try:
        data = _get_object(key)
    except s3.exceptions.NoSuchKey:
        return None
    except s3.exceptions.ClientError:
        return None

    if filename == "cv.pdf":
        return _resp(200, base64.b64encode(data).decode(), "application/pdf",
                     {"Cache-Control": "max-age=60"}, is_b64=True)
    if filename == "style.css":
        return _resp(200, data.decode("utf-8", "replace"), "text/css",
                     {"Cache-Control": "max-age=60"})
    # index.html: stamp the Lambda footer
    html = data.decode("utf-8", "replace").replace("{{HOSTED_ON}}", f"Lambda {fn}")
    return _resp(200, html, "text/html; charset=utf-8",
                 {"Cache-Control": "max-age=60", "Content-Security-Policy": CSP})


def _upload_page():
    # served to the student; the actual passcode lives only in the env var
    return _resp(200, UPLOAD_HTML)


def _handle_upload(event, fn):
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8", "replace")
    try:
        body = json.loads(raw)
    except (ValueError, TypeError):
        return _json(400, {"error": "body must be JSON"})

    if body.get("passcode") != PASSCODE or not PASSCODE:
        return _json(403, {"error": "wrong or missing passcode"})

    roll = str(body.get("roll", "")).strip().lower()
    if not ROLL_RE.match(roll):
        return _json(400, {"error": "roll must be 3-20 chars of a-z 0-9 -"})

    files = {
        "index.html": (body.get("index_html_b64"), MAX_HTML, "text/html"),
        "style.css": (body.get("style_css_b64"), MAX_CSS, "text/css"),
        "cv.pdf": (body.get("cv_pdf_b64"), MAX_PDF, "application/pdf"),
    }

    decoded = {}
    for name, (b64, cap, ctype) in files.items():
        if not b64:
            return _json(400, {"error": f"missing {name}"})
        try:
            raw_bytes = base64.b64decode(b64)
        except (ValueError, TypeError):
            return _json(400, {"error": f"{name} is not valid base64"})
        if len(raw_bytes) > cap:
            return _json(413, {"error": f"{name} exceeds {cap} bytes"})
        if name == "cv.pdf" and not raw_bytes[:5].startswith(b"%PDF-"):
            return _json(400, {"error": "cv.pdf is not a real PDF"})
        decoded[name] = (raw_bytes, ctype)

    for name, (raw_bytes, ctype) in decoded.items():
        s3.put_object(
            Bucket=BUCKET,
            Key=f"{PREFIX}/{roll}/site/{name}",
            Body=raw_bytes,
            ContentType=ctype,
        )

    host = (event.get("headers") or {}).get("host", "")
    lambda_url = f"https://{host}/u/{roll}/" if host else f"/u/{roll}/"
    out = {"ok": True, "roll": roll, "lambda_url": lambda_url}
    if EC2_BASE:
        out["ec2_url"] = f"{EC2_BASE}/u/{roll}/"
    return _json(200, out)


def handler(event, context):
    start = time.time()
    fn = getattr(context, "function_name", "unknown")
    http = (event.get("requestContext") or {}).get("http", {})
    method = http.get("method", "GET")
    path = event.get("rawPath", "/") or "/"

    try:
        if method == "GET" and path == "/":
            r = _upload_page()
        elif method == "POST" and path.rstrip("/") == "/upload":
            r = _handle_upload(event, fn)
        elif method == "GET" and path.startswith("/u/"):
            parts = [p for p in path.split("/") if p]  # ["u", roll, maybe file]
            if len(parts) >= 2 and ROLL_RE.match(parts[1]):
                roll = parts[1]
                filename = parts[2] if len(parts) >= 3 else "index.html"
                if filename not in ("index.html", "style.css", "cv.pdf"):
                    filename = "index.html"
                r = _serve_cv(roll, filename, fn)
                if r is None:
                    r = _resp(404, NOT_FOUND_HTML)
            else:
                r = _resp(404, NOT_FOUND_HTML)
        else:
            r = _resp(404, NOT_FOUND_HTML)
    except Exception as exc:  # never 500 silently; log and show 404-style page
        print(json.dumps({"fn": fn, "path": path, "error": str(exc)}))
        r = _resp(404, NOT_FOUND_HTML)

    _log(fn, path, r["statusCode"], start)
    return r


NOT_FOUND_HTML = (
    "<!doctype html><meta charset=utf-8><title>Not found</title>"
    "<body style='font-family:system-ui;max-width:480px;margin:4rem auto;text-align:center'>"
    "<h1>404</h1><p>No CV at this path. Open <code>/u/&lt;roll-number&gt;/</code> "
    "or go to <a href='/'>the upload page</a>.</p></body>"
)

UPLOAD_HTML = """<!doctype html>
<html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Host your CV</title>
<style>
 body{font:16px/1.6 system-ui,Segoe UI,Roboto,sans-serif;max-width:560px;margin:3rem auto;padding:0 1rem;color:#1a1a1a}
 h1{font-size:1.5rem}
 label{display:block;margin:1rem 0 .3rem;font-weight:600}
 input[type=text],input[type=password]{width:100%;padding:.5rem;border:1px solid #ccc;border-radius:6px}
 input[type=file]{margin-top:.3rem}
 button{margin-top:1.5rem;background:#2563eb;color:#fff;border:0;padding:.6rem 1.2rem;border-radius:6px;font-size:1rem;cursor:pointer}
 small{color:#666}
 #out{margin-top:1.5rem;padding:1rem;border-radius:8px;background:#f3f4f6;white-space:pre-wrap;display:none}
 a{color:#2563eb}
</style></head><body>
<h1>Host your CV</h1>
<p><small>Enter your roll number, the passcode you were given, and your three files.
You'll get two links to paste into your deliverables.</small></p>

<label>Roll number <small>(a-z, 0-9, dash)</small></label>
<input id=roll type=text placeholder="22l-6543" autocomplete=off>

<label>Passcode</label>
<input id=pass type=password autocomplete=off>

<label>index.html <small>(max 100 KB)</small></label>
<input id=html type=file accept=".html,text/html">

<label>style.css <small>(max 100 KB)</small></label>
<input id=css type=file accept=".css,text/css">

<label>cv.pdf <small>(max 1 MB)</small></label>
<input id=pdf type=file accept="application/pdf,.pdf">

<button id=go>Upload & get my links</button>
<div id=out></div>

<script>
const $=id=>document.getElementById(id);
const b64=f=>new Promise((res,rej)=>{const r=new FileReader();
  r.onload=()=>res(r.result.split(',')[1]);r.onerror=rej;r.readAsDataURL(f);});
$('go').onclick=async()=>{
  const out=$('out');out.style.display='block';out.textContent='Uploading...';
  try{
    const [h,c,p]=[$('html').files[0],$('css').files[0],$('pdf').files[0]];
    if(!h||!c||!p){out.textContent='Please choose all three files.';return;}
    const payload={roll:$('roll').value.trim().toLowerCase(),passcode:$('pass').value,
      index_html_b64:await b64(h),style_css_b64:await b64(c),cv_pdf_b64:await b64(p)};
    const res=await fetch('/upload',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify(payload)});
    const j=await res.json();
    if(!res.ok){out.textContent='Error: '+(j.error||res.status);return;}
    let msg='Done! Your CV is live.\\n\\nLambda link:\\n'+j.lambda_url;
    if(j.ec2_url) msg+='\\n\\nEC2 link (live within 5 min):\\n'+j.ec2_url;
    out.innerHTML=msg.replace(/(https?:\\/\\/\\S+)/g,'<a href="$1">$1</a>');
  }catch(e){out.textContent='Error: '+e;}
};
</script>
</body></html>"""

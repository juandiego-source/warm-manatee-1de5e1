#!/bin/sh
# Local proof that a subcontractor JWT cannot read prices or office rows.
# Do not point this at the hosted Sumak database.
set -eu
cd "$(dirname "$0")/.."
sudo pg_ctlcluster 16 main start || true
# A leftover PostgREST keeps the test database open and blocks DROP.
sudo pkill -f '/tmp/postgrest' || true
sleep 0.3
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS sumak_sub_access;"
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE sumak_sub_access;"
sudo -u postgres psql -d sumak_sub_access -v ON_ERROR_STOP=1 -f test/sub-access-setup.sql
sudo -u postgres psql -d sumak_sub_access -v ON_ERROR_STOP=1 -f sql/2026-10-23-sub-access.sql >/tmp/sub-access-migrate.log
sudo -u postgres psql -d sumak_sub_access -v ON_ERROR_STOP=1 -f test/sub-access-assert.sql
sudo -u postgres psql -d sumak_sub_access -v ON_ERROR_STOP=1 -f sql/2026-10-24-sub-office-comms.sql >/tmp/sub-comms-migrate.log
sudo -u postgres psql -d sumak_sub_access -v ON_ERROR_STOP=1 -f sql/2026-10-24-sub-office-comms.sql >/tmp/sub-comms-migrate-again.log
sudo -u postgres psql -d sumak_sub_access -v ON_ERROR_STOP=1 -f test/sub-comms-assert.sql

# HTTP proof through PostgREST, the same check the hosted API makes.
# PostgREST rejects an HS256 secret shorter than 32 characters.
PGRST_BIN=""
if [ -x /tmp/postgrest ]; then
  PGRST_BIN=/tmp/postgrest
elif command -v postgrest >/dev/null 2>&1; then
  PGRST_BIN=$(command -v postgrest)
fi
if [ -z "$PGRST_BIN" ]; then
  echo "SUB_ACCESS_HTTP_SKIPPED no postgrest binary"
  exit 0
fi

SECRET='reallyreallyreallyreallyverysafe'
cat > /tmp/sub-access-postgrest.conf << EOF
db-uri = "postgresql:///sumak_sub_access?host=/var/run/postgresql"
db-schemas = "public"
db-anon-role = "anon"
db-config = false
jwt-secret = "$SECRET"
jwt-secret-is-base64 = false
server-port = 3001
server-host = "127.0.0.1"
log-level = "info"
EOF
sudo -u postgres "$PGRST_BIN" /tmp/sub-access-postgrest.conf >/tmp/sub-access-postgrest.log 2>&1 &
PGRST_PID=$!
trap 'sudo kill "$PGRST_PID" 2>/dev/null || true; sudo pkill -f /tmp/sub-access-postgrest.conf || true' EXIT
i=0
while [ "$i" -lt 50 ]; do
  if curl -sS -o /dev/null "http://127.0.0.1:3001/" 2>/dev/null; then
    break
  fi
  i=$((i + 1))
  sleep 0.1
done
if [ "$i" -eq 50 ]; then
  echo "PostgREST did not start" >&2
  cat /tmp/sub-access-postgrest.log >&2 || true
  exit 1
fi

python3 - "$SECRET" << 'PY'
import json, sys, urllib.error, urllib.request
secret = sys.argv[1]
import hmac, hashlib, base64
def b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=")
def token(sub):
    header = b64(b'{"alg":"HS256","typ":"JWT"}')
    payload = b64(json.dumps({"role": "authenticated", "sub": sub}, separators=(",", ":")).encode())
    sig = b64(hmac.new(secret.encode(), header + b"." + payload, hashlib.sha256).digest())
    return (header + b"." + payload + b"." + sig).decode()

sub = token("aaaa2222-2222-4222-8222-222222222222")

def get(path, auth=None, headers=None):
    req = urllib.request.Request("http://127.0.0.1:3001" + path)
    req.add_header("Accept", "application/json")
    if auth:
        req.add_header("Authorization", "Bearer " + auth)
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req) as res:
            return res.status, res.read().decode(), dict(res.headers)
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode(), dict(err.headers)

def empty(path, auth=sub):
    status, body, _ = get(path, auth)
    if status != 200 or json.loads(body) != []:
        raise SystemExit(f"expected empty 200 for {path}, got {status} {body}")

def denied(path):
    status, body, _ = get(path, None)
    if status != 401 or "permission denied" not in body:
        raise SystemExit(f"expected anon denial for {path}, got {status} {body}")

empty("/jobs?select=client_price,sub_pay")
empty("/jobs?select=id,client_price&client_price=eq.125")
status, body, headers = get("/jobs?select=client_price", sub, {"Prefer": "count=exact"})
if status != 200 or json.loads(body) != [] or headers.get("Content-Range") != "*/0":
    raise SystemExit(f"count leaked jobs: {status} {body} {headers.get('Content-Range')}")
status, body, _ = get("/jobs?select=client_price.max()", sub)
if status != 400 or "aggregate" not in body.lower():
    raise SystemExit(f"aggregate was allowed: {status} {body}")

status, body, _ = get("/sub_jobs?select=client_price", sub)
if status != 400 or "client_price" not in body:
    raise SystemExit(f"sub_jobs still exposes client_price: {status} {body}")
status, body, _ = get("/sub_jobs?select=job_number,sub_pay,customer_name", sub)
rows = json.loads(body)
if status != 200 or len(rows) != 1 or rows[0].get("job_number") != "SMK-A" or float(rows[0].get("sub_pay")) != 40:
    raise SystemExit(f"own sub_jobs mismatch: {status} {body}")
if "SMK-B" in body or "77" in body or "secret@customer.test" in body:
    raise SystemExit(f"other sub or customer data in sub_jobs: {body}")

empty("/invoice_items?select=total,cost,margin_pct")
empty("/invoice_items?select=total,cost,margin_pct&margin_pct=gt.0")
empty("/customers?select=name,email")
empty("/customers?select=email&email=eq.secret@customer.test")
empty("/sub_payments?select=amount")
empty("/estimates?select=total,public_token")
empty("/activity_log?select=*")
status, body, _ = get("/sub_cost_requests?select=office_price", sub)
if status != 400 or "office_price" not in body:
    raise SystemExit(f"office_price still on sub_cost_requests: {status} {body}")
status, body, _ = get("/job_photos?select=job_id", sub)
photos = json.loads(body)
if status != 200 or len(photos) != 1 or photos[0].get("job_id") != "11111111-1111-4111-8111-111111111111":
    raise SystemExit(f"job_photos mismatch: {status} {body}")
if "22222222-2222-4222-8222-222222222222" in body:
    raise SystemExit(f"other sub photo visible: {body}")
denied("/jobs?select=client_price")
print("SUB_ACCESS_HTTP_OK")
PY

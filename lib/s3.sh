#!/usr/bin/env bash
# Anonymous read access for individual objects in Glance's S3 store.
#
# Why this exists: Metal3's baremetal-operator refuses anything but an
# http(s) image URL (its admission webhook rejects glance://), and it sends
# no credentials. Glance's own download API needs a Keystone token, and the
# RBD store only ever produces rbd:// URIs, so neither can serve BMO. The
# S3 store can: glance_store writes the image to <bucket>/<image-id>, and
# RGW speaks HTTP. All that is missing is read access for an unauthenticated
# client, which is what this grants - per object, never per bucket, so the
# other images that share the bucket stay private.
#
# The grant is the canned "public-read" ACL: one extra entry for the
# AllUsers group with READ. Ownership and write access are untouched.
#
# Environment:
#   S3_ENDPOINT     e.g. http://10.224.18.10   (RGW, reachable by the node)
#   S3_BUCKET       the bucket glance_store writes to (s3_store_bucket)
#   S3_ACCESS_KEY   the same credentials glance-api uses
#   S3_SECRET_KEY
#   S3_REGION       optional, defaults to us-east-1 (RGW ignores it, SigV4 does not)
#
# Signing is SigV4 done with the standard library: the runner needs python3
# and nothing else.
# shellcheck shell=bash

[[ -n "${_LIB_S3_SH:-}" ]] && return 0
_LIB_S3_SH=1

S3_ENDPOINT=${S3_ENDPOINT:-}
S3_BUCKET=${S3_BUCKET:-}
S3_ACCESS_KEY=${S3_ACCESS_KEY:-}
S3_SECRET_KEY=${S3_SECRET_KEY:-}
S3_REGION=${S3_REGION:-us-east-1}

# s3_acl_configured — true when there is enough to sign a request.
s3_acl_configured() {
    [[ -n "$S3_ENDPOINT" && -n "$S3_BUCKET" && \
       -n "$S3_ACCESS_KEY" && -n "$S3_SECRET_KEY" ]]
}

s3_acl_check_env() {
    require_cmd python3
    : "${S3_ENDPOINT:?S3_ENDPOINT is required}"
    : "${S3_BUCKET:?S3_BUCKET is required}"
    : "${S3_ACCESS_KEY:?S3_ACCESS_KEY is required}"
    : "${S3_SECRET_KEY:?S3_SECRET_KEY is required}"
}

# s3_public_read <key> [<key> ...]
#
# Grants public-read on each object, then proves it by reading the object
# back with no credentials at all - the way the consumer will.
s3_public_read() {
    s3_acl_check_env
    local key
    for key in "$@"; do
        S3_KEY="$key" S3_REGION="$S3_REGION" python3 - <<'PY'
import datetime, hashlib, hmac, http.client, os, sys, urllib.parse, urllib.request

ep = os.environ["S3_ENDPOINT"].rstrip("/")
bucket, key = os.environ["S3_BUCKET"], os.environ["S3_KEY"]
region, service = os.environ["S3_REGION"], "s3"
access, secret = os.environ["S3_ACCESS_KEY"], os.environ["S3_SECRET_KEY"]

url = urllib.parse.urlparse(ep)
host = url.netloc
# Path-style addressing: glance_store is configured with
# s3_store_bucket_url_format = path, so the object lives at /<bucket>/<key>.
path = f"/{urllib.parse.quote(bucket)}/{urllib.parse.quote(key)}"
now = datetime.datetime.now(datetime.timezone.utc)
amzdate, datestamp = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
payload_hash = hashlib.sha256(b"").hexdigest()

headers = {"host": host, "x-amz-acl": "public-read",
           "x-amz-content-sha256": payload_hash, "x-amz-date": amzdate}
signed = ";".join(sorted(headers))
canonical = "\n".join([
    "PUT", path, "acl=",
    "".join(f"{k}:{headers[k]}\n" for k in sorted(headers)),
    signed, payload_hash])
scope = f"{datestamp}/{region}/{service}/aws4_request"
to_sign = "\n".join(["AWS4-HMAC-SHA256", amzdate, scope,
                     hashlib.sha256(canonical.encode()).hexdigest()])

def sign(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
k = sign(sign(sign(sign(("AWS4" + secret).encode(), datestamp), region), service), "aws4_request")
sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
headers["Authorization"] = (f"AWS4-HMAC-SHA256 Credential={access}/{scope}, "
                            f"SignedHeaders={signed}, Signature={sig}")

# http.client, not urllib: urllib adds a Content-Type of its own choosing to
# any request that carries a body, and RGW rejects the signature once that
# header appears. The signature itself is identical either way - this was
# verified by diffing the canonical request against botocore's.
send = {k: v for k, v in headers.items() if k != "host"}
send["Content-Length"] = "0"
klass = http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
conn = klass(host, timeout=30)
conn.request("PUT", f"{path}?acl", body=b"", headers=send)
resp = conn.getresponse()
body = resp.read()
if resp.status not in (200, 204):
    sys.exit(f"setting the ACL failed: {resp.status} {body[:300].decode(errors='replace')}")

# Read it back the way the consumer will: no credentials at all.
try:
    check = urllib.request.Request(f"{ep}{path}", method="HEAD")
    with urllib.request.urlopen(check, timeout=30) as r:
        print(f"  {key}: anonymous HEAD {r.status}, {r.headers.get('Content-Length')} bytes")
except urllib.error.HTTPError as e:
    sys.exit(f"the object is still not anonymously readable: {e.code}")
PY
    done
}

# s3_object_url <key> — the URL an unauthenticated client fetches.
s3_object_url() {
    printf '%s/%s/%s\n' "${S3_ENDPOINT%/}" "$S3_BUCKET" "$1"
}

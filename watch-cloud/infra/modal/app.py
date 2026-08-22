from pathlib import Path
import hashlib
import ipaddress
import os
import socket
import subprocess
from urllib.parse import urljoin, urlparse

import modal

if modal.is_local():
    root = Path(__file__).resolve().parents[2]
    image = modal.Image.from_dockerfile(
        root / "services" / "resolver" / "Dockerfile",
        context_dir=root,
        add_python="3.12",
    ).pip_install("boto3==1.40.21", "fastapi==0.116.1", "requests==2.32.5")
else:
    image = modal.Image.debian_slim().pip_install("boto3==1.40.21", "fastapi==0.116.1", "requests==2.32.5")
app = modal.App("lustre-watch-resolver")
progress = modal.Dict.from_name("lustre-stage-progress", create_if_missing=True)
r2_secret = modal.Secret.from_name("lustre-r2-staging")


@app.function(
    image=image,
    cpu=0.25,
    memory=(512, 768),
    min_containers=0,
    max_containers=3,
    scaledown_window=30,
    timeout=60,
)
@modal.concurrent(max_inputs=4)
@modal.web_server(port=8080, startup_timeout=60, requires_proxy_auth=True)
def serve():
    env = {**os.environ, "PORT": "8080", "NODE_ENV": "production"}
    subprocess.Popen(
        ["node", "/app/services/resolver/dist/server.js"],
        env=env,
        stdin=subprocess.DEVNULL,
    )


def public_url(value):
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("invalid_url")
    addresses = socket.getaddrinfo(parsed.hostname, 443, type=socket.SOCK_STREAM)
    for address in addresses:
        ip = ipaddress.ip_address(address[4][0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved:
            raise ValueError("invalid_url")
    return value


def source_response(url, headers):
    import requests
    current = public_url(url)
    allowed = {key: value for key, value in headers.items() if key in {"Referer", "Origin", "User-Agent"} and isinstance(value, str) and len(value) <= 1000}
    session = requests.Session()
    session.trust_env = False
    for _ in range(4):
        response = session.get(current, headers=allowed, stream=True, allow_redirects=False, timeout=(15, 60))
        if response.status_code not in {301, 302, 303, 307, 308}:
            if response.status_code < 200 or response.status_code > 299:
                response.close()
                raise ValueError("provider_unavailable")
            return response
        location = response.headers.get("Location")
        response.close()
        if not location:
            raise ValueError("unsafe_redirect")
        current = public_url(urljoin(current, location))
    raise ValueError("unsafe_redirect")


@app.function(image=image, secrets=[r2_secret], cpu=0.5, memory=(512, 1024), timeout=21_600, retries=modal.Retries(max_retries=1, backoff_coefficient=2.0), max_containers=3)
def stage_mp4(payload):
    import boto3
    stage_id = payload["stageID"]
    maximum = min(int(payload["maximumBytes"]), 10 * 1024 * 1024 * 1024)
    progress[stage_id] = {"status": "staging", "progressBytes": 0}
    client = boto3.client(
        "s3",
        endpoint_url=f"https://{os.environ['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
        region_name="auto",
    )
    bucket = os.environ["R2_STAGING_BUCKET"]
    key = payload["objectKey"]
    upload_id = None
    response = None
    try:
        response = source_response(payload["mediaURL"], payload.get("headers", {}))
        content_type = response.headers.get("Content-Type", "").split(";")[0].strip().lower()
        if content_type not in {"video/mp4", "application/mp4", "application/octet-stream"}:
            raise ValueError("not_mp4")
        expected = response.headers.get("Content-Length")
        expected_bytes = int(expected) if expected and expected.isdigit() else None
        if expected_bytes is not None and (expected_bytes < 1024 or expected_bytes > maximum):
            raise ValueError("file_too_large")
        created = client.create_multipart_upload(Bucket=bucket, Key=key, ContentType="video/mp4", Metadata={"stage-id": stage_id})
        upload_id = created["UploadId"]
        parts = []
        digest = hashlib.sha256()
        buffered = bytearray()
        written = 0
        part_number = 1
        validated = False
        for chunk in response.iter_content(chunk_size=1024 * 1024):
            if not chunk:
                continue
            written += len(chunk)
            if written > maximum:
                raise ValueError("file_too_large")
            digest.update(chunk)
            buffered.extend(chunk)
            if not validated and len(buffered) >= 12:
                if buffered[4:8] != b"ftyp":
                    raise ValueError("not_mp4")
                validated = True
            if len(buffered) >= 16 * 1024 * 1024:
                uploaded = client.upload_part(Bucket=bucket, Key=key, UploadId=upload_id, PartNumber=part_number, Body=bytes(buffered))
                parts.append({"ETag": uploaded["ETag"], "PartNumber": part_number})
                part_number += 1
                buffered.clear()
                progress[stage_id] = {"status": "staging", "progressBytes": written, **({"totalBytes": expected_bytes} if expected_bytes else {})}
        if written < 1024:
            raise ValueError("response_too_small")
        if not validated:
            raise ValueError("not_mp4")
        if buffered:
            uploaded = client.upload_part(Bucket=bucket, Key=key, UploadId=upload_id, PartNumber=part_number, Body=bytes(buffered))
            parts.append({"ETag": uploaded["ETag"], "PartNumber": part_number})
        client.complete_multipart_upload(Bucket=bucket, Key=key, UploadId=upload_id, MultipartUpload={"Parts": parts})
        result = {"status": "ready", "progressBytes": written, "totalBytes": written, "sha256": digest.hexdigest()}
        progress[stage_id] = result
        return result
    except Exception as error:
        if upload_id:
            try:
                client.abort_multipart_upload(Bucket=bucket, Key=key, UploadId=upload_id)
            except Exception:
                pass
        try:
            client.delete_object(Bucket=bucket, Key=key)
        except Exception:
            pass
        code = str(error) if str(error) in {"invalid_url", "provider_unavailable", "unsafe_redirect", "not_mp4", "file_too_large", "response_too_small"} else "staging_failed"
        result = {"status": "failed", "progressBytes": 0, "failureCode": code}
        progress[stage_id] = result
        return result
    finally:
        if response is not None:
            response.close()


@app.function(image=image)
@modal.asgi_app(requires_proxy_auth=True)
def staging_api():
    from fastapi import FastAPI, HTTPException
    api = FastAPI()

    @api.post("/submit")
    async def submit(payload: dict):
        required = {"stageID", "mediaURL", "objectKey", "filename", "maximumBytes"}
        if not required.issubset(payload) or not isinstance(payload.get("headers", {}), dict):
            raise HTTPException(status_code=400, detail="invalid_request")
        call = await stage_mp4.spawn.aio(payload)
        progress[payload["stageID"]] = {"status": "staging", "progressBytes": 0, "callID": call.object_id}
        return {"callID": call.object_id}

    @api.get("/result/{call_id}")
    async def result(call_id: str, stageID: str):
        call = modal.FunctionCall.from_id(call_id)
        try:
            value = await call.get.aio(timeout=0)
            return value
        except TimeoutError:
            return progress.get(stageID, {"status": "staging", "progressBytes": 0})

    @api.post("/cancel/{call_id}")
    async def cancel(call_id: str):
        await modal.FunctionCall.from_id(call_id).cancel.aio()
        return {"status": "cancelled"}

    return api

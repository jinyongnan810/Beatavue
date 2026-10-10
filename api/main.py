"""One public HTTP function, plus an IAM-only durable deletion worker."""
import base64
import hashlib
import hmac
import json
import os
import re
import time
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import functions_framework
from google.api_core.exceptions import AlreadyExists
from google.cloud import tasks_v2
from pydantic import ValidationError

from models import DeleteRequest, ImportRequest, SyncBatch
from repository import Conflict, RateLimited, Repository

MAX_BODY = 256 * 1024
MAX_SUMMARY_SAMPLES = 20000


@lru_cache
def repository():
    return Repository()


def response(body, status=200, cache=False):
    return json.dumps(body), status, {"Content-Type": "application/json",
                                    "Cache-Control": "public, max-age=60" if cache else "no-store",
                                    "X-Content-Type-Options": "nosniff"}


def authorized(request):
    token = os.environ.get("UPLOAD_TOKEN", "")
    supplied = request.headers.get("Authorization", "")
    return len(token) >= 32 and hmac.compare_digest(supplied.encode(), ("Bearer " + token).encode())


def body(request, model):
    if request.mimetype != "application/json":
        raise ValueError("Use application/json")
    raw = request.get_data()
    if len(raw) > MAX_BODY:
        raise OverflowError()
    return model.model_validate_json(raw)


def instant(value):
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("Timezone required")
    return result.astimezone(timezone.utc)


def parameters(request):
    metric = request.args["metric"]
    if metric not in ("heart_rate", "hrv_sdnn"):
        raise ValueError("Unsupported metric")
    start, end = instant(request.args["from"]), instant(request.args["to"])
    # A 31-calendar-day month may exceed 31 elapsed days at a DST fall-back.
    if not timedelta(0) < end - start <= timedelta(days=32):
        raise ValueError("Range must be positive and at most 32 elapsed days")
    return metric, start, end


def public_sample(data):
    return {"value": data["value"], "unit": data["unit"], "start": data["start"].isoformat(),
            "end": data["end"].isoformat(), "source": "Apple Health"}


def cursor_encode(state, metric, start, end, doc):
    payload = [state["generation"], metric, start.isoformat(), end.isoformat(),
               doc.to_dict()["start"].isoformat(), doc.id]
    return base64.urlsafe_b64encode(json.dumps(payload).encode()).decode()


def cursor_decode(cursor, state, metric, start, end):
    if len(cursor) > 1024:
        raise ValueError("Invalid cursor")
    value = json.loads(base64.urlsafe_b64decode(cursor))
    if (len(value) != 6 or value[:4] != [state.get("generation"), metric, start.isoformat(), end.isoformat()]
            or not re.fullmatch(r"[a-f0-9]{64}", value[5])):
        raise ValueError("Cursor does not match query")
    stamp = instant(value[4])
    if not start <= stamp < end:
        raise ValueError("Cursor outside range")
    return stamp, value[5]


def enqueue_cleanup(state):
    client = tasks_v2.CloudTasksClient()
    queue = client.queue_path(os.environ["GOOGLE_CLOUD_PROJECT"], os.environ["REGION"], "beatavue-cleanup")
    url = os.environ["CLEANUP_URL"]
    task = {"name": f'{queue}/tasks/{state["deletion_id"]}',
            "http_request": {"http_method": tasks_v2.HttpMethod.POST, "url": url,
                             "headers": {"Content-Type": "application/json"},
                             "body": json.dumps({"generation": state["generation"]}).encode(),
                             "oidc_token": {"service_account_email": os.environ["TASK_SERVICE_ACCOUNT"], "audience": url}}}
    try:
        client.create_task(parent=queue, task=task)
    except AlreadyExists:
        pass


def stats(values):
    return {"count": len(values), "min": min(values) if values else None,
            "max": max(values) if values else None,
            "average": sum(values) / len(values) if values else None}


def summaries(docs, zone, bucket):
    groups = {}
    for doc in docs:
        data = doc.to_dict()
        stamp = data["start"]
        if bucket == "hour":
            # UTC hours distinguish both occurrences of a DST fall-back hour.
            key = stamp.astimezone(timezone.utc).replace(minute=0, second=0, microsecond=0)
        else:
            key = datetime.combine(stamp.astimezone(zone).date(), datetime.min.time(), tzinfo=zone)
        groups.setdefault(key, []).append(data["value"])
    return [{"start": key.isoformat(), **stats(values)} for key, values in sorted(groups.items())]


@functions_framework.http
def api(request):
    if request.content_length and request.content_length > MAX_BODY:
        return response({"error": "payload_too_large"}, 413)
    path = request.path.rstrip("/")
    private = {("POST", "/v1/sync"), ("POST", "/v1/import"), ("DELETE", "/v1/data")}
    if (request.method, path) in private and not authorized(request):
        return response({"error": "unauthorized"}, 401)
    try:
        repo = repository()
        if request.method == "POST" and path == "/v1/import":
            return response(repo.begin_import(body(request, ImportRequest).import_id))
        if request.method == "POST" and path == "/v1/sync":
            batch = body(request, SyncBatch)
            canonical = json.dumps(batch.model_dump(mode="json"), sort_keys=True, separators=(",", ":"))
            return response(repo.sync(batch, hashlib.sha256(canonical.encode()).hexdigest()))
        if request.method == "DELETE" and path == "/v1/data":
            state = repo.begin_delete(body(request, DeleteRequest))
            if state["cleanup_pending"]:
                enqueue_cleanup(state)
            return response({"deletion_id": state["deletion_id"], "cleanup_pending": state["cleanup_pending"]},
                            202 if state["cleanup_pending"] else 200)
        if request.method == "GET" and path == "/v1/sync-status":
            repo.reserve_public_reads(1)
            state = repo.status()
            stamp = state.get("last_ingestion")
            return response({"last_ingestion": stamp.isoformat() if stamp else None})
        if request.method == "GET" and path in ("/v1/samples", "/v1/summaries"):
            metric, start, end = parameters(request)
            state = repo.status()
            if path == "/v1/samples":
                limit = int(request.args.get("limit", 500))
                if not 1 <= limit <= 500:
                    raise ValueError("Limit must be 1–500")
                after = cursor_decode(request.args["cursor"], state, metric, start, end) if "cursor" in request.args else None
                repo.reserve_public_reads(limit + 1)
                docs = repo.query(state, metric, start, end, limit + 1, after)
                result = {"samples": [public_sample(doc.to_dict()) for doc in docs[:limit]],
                          "next_cursor": cursor_encode(state, metric, start, end, docs[limit - 1]) if len(docs) > limit else None}
            else:
                zone = ZoneInfo(request.args.get("timezone", "UTC"))
                bucket = request.args.get("bucket", "day")
                if bucket not in ("hour", "day"):
                    raise ValueError("Unsupported bucket")
                repo.reserve_public_reads(MAX_SUMMARY_SAMPLES + 1)
                docs = repo.query(state, metric, start, end, MAX_SUMMARY_SAMPLES + 1)
                if len(docs) > MAX_SUMMARY_SAMPLES:
                    return response({"error": "range_too_dense", "message": "Select a shorter range"}, 422)
                result = {"buckets": summaries(docs, zone, bucket), "summary": stats([d.to_dict()["value"] for d in docs]),
                          "latest": public_sample(docs[-1].to_dict()) if docs else None,
                          "unit": "bpm" if metric == "heart_rate" else "ms", "timezone": str(zone), "bucket": bucket}
            # Recheck the deletion fence before returning queried data.
            current = repo.status()
            if current.get("generation") != state.get("generation") or current.get("enabled") != state.get("enabled"):
                return response({"error": "dataset_changed", "message": "Retry the query"}, 409)
            return response(result)
        return response({"error": "not_found"}, 404)
    except OverflowError:
        return response({"error": "payload_too_large"}, 413)
    except (ValidationError, ValueError, KeyError, TypeError, ZoneInfoNotFoundError):
        return response({"error": "invalid_request", "message": "Check the API contract, fields, and query limits"}, 400)
    except Conflict as error:
        return response({"error": "conflict", "message": str(error)}, 409)
    except RateLimited:
        content, status, headers = response({"error": "rate_limited"}, 429)
        headers["Retry-After"] = "60"
        return content, status, headers
    except Exception:
        # Never print exception text: SDK errors can contain sample values or credentials.
        print(json.dumps({"event": "api_failure", "path": path, "method": request.method}))
        return response({"error": "temporarily_unavailable"}, 503)


@functions_framework.http
def cleanup(request):
    # Cloud Run IAM admits only the task service account; this endpoint is a separate function.
    if request.method != "POST":
        return response({"error": "method_not_allowed"}, 405)
    try:
        from uuid import UUID
        generation = str(UUID(request.get_json()["generation"]))
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            if repository().cleanup_chunk(generation):
                return response({"complete": True})
        # Cloud Tasks retries this same durable task until every chunk is removed.
        return response({"complete": False}, 503)
    except Exception:
        print('{"event":"cleanup_retry"}')
        return response({"complete": False}, 503)

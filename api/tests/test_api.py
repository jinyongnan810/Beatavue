"""Contract and persistence tests with an atomic in-memory Firestore adapter.

These exercise the real Repository methods. A live emulator/deployment is still
needed to verify SDK queries, IAM, indexes, and transaction contention.
"""
import copy
import json
from datetime import datetime, timezone
from uuid import uuid4

import pytest
from flask import Flask, request

import main
import repository as persistence
from models import DeleteRequest, SyncBatch


class Snapshot:
    def __init__(self, ref, value):
        self.reference = ref
        self.id = ref.path.split("/")[-1]
        self.value = copy.deepcopy(value)

    def to_dict(self):
        return self.value


class Reference:
    def __init__(self, db, path):
        self.db, self.path = db, path

    def collection(self, name):
        return Collection(self.db, self.path + "/" + name)

    def get(self, transaction=None):
        return Snapshot(self, self.db.values.get(self.path))


class Collection:
    def __init__(self, db, path):
        self.db, self.path = db, path

    def document(self, name):
        return Reference(self.db, self.path + "/" + name)

    def limit(self, count):
        self.count = count
        return self

    def stream(self):
        depth = self.path.count("/") + 1
        return [Snapshot(Reference(self.db, key), value) for key, value in self.db.values.items()
                if key.startswith(self.path + "/") and key.count("/") == depth][:self.count]


class Transaction:
    def __init__(self, db):
        self.db, self.writes = db, []

    def set(self, ref, value):
        self.writes.append(("set", ref.path, copy.deepcopy(value)))

    def update(self, ref, value):
        self.writes.append(("update", ref.path, copy.deepcopy(value)))

    def delete(self, ref):
        self.writes.append(("delete", ref.path, None))

    def commit(self):
        result = copy.deepcopy(self.db.values)
        for kind, path, value in self.writes:
            if kind == "delete":
                result.pop(path, None)
            elif kind == "update":
                result[path].update(value)
            else:
                result[path] = value
        self.db.values = result


class Database:
    def __init__(self):
        self.values = {}

    def collection(self, name):
        return Collection(self, name)

    def transaction(self):
        return Transaction(self)

    def batch(self):
        return Transaction(self)


@pytest.fixture
def repo(monkeypatch):
    def atomic(function):
        def execute(tx):
            result = function(tx)
            tx.commit()
            return result
        return execute
    monkeypatch.setattr(persistence.firestore, "transactional", atomic)
    instance = persistence.Repository(Database())
    monkeypatch.setattr(main, "repository", lambda: instance)
    monkeypatch.setenv("UPLOAD_TOKEN", "test-only-" + "x" * 40)
    return instance


def invoke(method, path, payload=None, token=True, raw=None):
    app = Flask(__name__)
    headers = {"Authorization": "Bearer test-only-" + "x" * 40} if token else {}
    with app.test_request_context(path, method=method, json=payload if raw is None else None,
                                  data=raw, content_type="application/json", headers=headers):
        value, code, response_headers = main.api(request)
        return json.loads(value), code, response_headers


def sample(uuid=None):
    return {"uuid": str(uuid or uuid4()), "metric": "heart_rate", "value": 72.5, "unit": "bpm",
            "start": "2026-10-09T01:00:00.123Z", "end": "2026-10-09T01:00:00.123Z",
            "source_name": "Watch", "source_identifier": "com.apple.health", "device_name": "Private device"}


def upload(repo, sample_value=None, kind="upsert", generation=None, batch_id=None):
    value = sample_value or sample()
    generation = generation or repo.begin_import(uuid4())["generation"]
    op = {"kind": kind, "uuid": value["uuid"]}
    if kind == "upsert":
        op["sample"] = value
    return {"schema_version": 1, "generation": generation, "batch_id": str(batch_id or uuid4()), "operations": [op]}


@pytest.mark.parametrize("method,path,payload", [
    ("POST", "/v1/import", {"import_id": str(uuid4())}),
    ("POST", "/v1/sync", {}),
    ("DELETE", "/v1/data", {}),
])
def test_unauthorized_mutations_never_write(repo, method, path, payload):
    _, status, _ = invoke(method, path, payload, token=False)
    assert status == 401
    assert repo.db.values == {}


def test_duplicate_retry_returns_same_ack_and_does_not_reingest(repo):
    batch = upload(repo)
    first, status, _ = invoke("POST", "/v1/sync", batch)
    snapshot = copy.deepcopy(repo.db.values)
    second, retry_status, _ = invoke("POST", "/v1/sync", batch)
    assert status == retry_status == 200
    assert first == second
    assert repo.db.values == snapshot


def test_reused_batch_id_with_changed_payload_conflicts(repo):
    batch = upload(repo)
    invoke("POST", "/v1/sync", batch)
    before = copy.deepcopy(repo.db.values)
    batch["operations"][0]["sample"]["value"] = 99
    assert invoke("POST", "/v1/sync", batch)[1] == 409
    assert repo.db.values == before


def test_invalid_operation_rejects_entire_batch(repo):
    batch = upload(repo)
    malformed = sample()
    malformed["unit"] = "ms"
    batch["operations"].append({"kind": "upsert", "uuid": malformed["uuid"], "sample": malformed})
    before = copy.deepcopy(repo.db.values)
    assert invoke("POST", "/v1/sync", batch)[1] == 400
    assert repo.db.values == before


def test_delete_then_delayed_addition_cannot_resurrect(repo):
    value = sample()
    addition = upload(repo, value)
    invoke("POST", "/v1/sync", addition)
    deletion = upload(repo, value, kind="delete", generation=addition["generation"])
    invoke("POST", "/v1/sync", deletion)
    late = upload(repo, value, generation=addition["generation"])
    assert invoke("POST", "/v1/sync", late)[1] == 200
    stored = repo.samples(addition["generation"]).document(persistence.document_id(value["uuid"])).get().to_dict()
    assert stored["deleted"] is True
    assert "value" not in stored
    assert "device_name" not in stored


def test_delete_all_fences_old_batches_and_purges_in_chunks(repo, monkeypatch):
    batch = upload(repo)
    invoke("POST", "/v1/sync", batch)
    monkeypatch.setattr(main, "enqueue_cleanup", lambda state: None)
    payload = {"generation": batch["generation"], "deletion_id": str(uuid4())}
    assert invoke("DELETE", "/v1/data", payload)[1] == 202
    assert invoke("POST", "/v1/sync", batch)[1] == 409
    assert invoke("POST", "/v1/import", {"import_id": str(uuid4())})[1] == 409
    for _ in range(10):
        if repo.cleanup_chunk(batch["generation"]):
            break
    assert repo.status()["cleanup_pending"] is False
    assert list(repo.samples(batch["generation"]).limit(1).stream()) == []
    assert invoke("DELETE", "/v1/data", payload)[1] == 200
    assert invoke("POST", "/v1/import", {"import_id": batch["generation"]})[1] == 409
    assert invoke("POST", "/v1/import", {"import_id": str(uuid4())})[1] == 200
    assert invoke("POST", "/v1/sync", batch)[1] == 409


def test_enqueue_failure_keeps_fence_and_delete_retry_recovers(repo, monkeypatch):
    batch = upload(repo)
    invoke("POST", "/v1/sync", batch)
    def unavailable(state):
        raise RuntimeError("queue unavailable")
    monkeypatch.setattr(main, "enqueue_cleanup", unavailable)
    payload = {"generation": batch["generation"], "deletion_id": str(uuid4())}
    assert invoke("DELETE", "/v1/data", payload)[1] == 503
    assert repo.status()["enabled"] is False
    monkeypatch.setattr(main, "enqueue_cleanup", lambda state: None)
    assert invoke("DELETE", "/v1/data", payload)[1] == 202


def test_distinct_uuids_at_same_time_are_retained(repo):
    one = upload(repo)
    two = upload(repo, generation=one["generation"])
    invoke("POST", "/v1/sync", one)
    invoke("POST", "/v1/sync", two)
    assert len(repo.samples(one["generation"]).limit(10).stream()) == 2


def test_public_fields_hide_private_identifiers(repo):
    value = sample()
    result = main.public_sample(SyncBatch.model_validate(upload(repo, value)).operations[0].sample.model_dump())
    assert set(result) == {"value", "unit", "start", "end", "source"}
    assert value["uuid"] not in json.dumps(result)
    assert "Private device" not in json.dumps(result)


@pytest.mark.parametrize("query", [
    "metric=ecg&from=2026-10-01T00:00:00Z&to=2026-10-02T00:00:00Z",
    "metric=heart_rate&from=2026-01-01T00:00:00Z&to=2026-10-02T00:00:00Z",
    "metric=heart_rate&from=2026-10-02&to=2026-10-03",
    "metric=heart_rate&from=2026-10-01T00:00:00Z&to=2026-10-02T00:00:00Z&limit=501",
])
def test_bounded_public_queries(repo, query):
    assert invoke("GET", "/v1/samples?" + query, token=False)[1] == 400


def test_public_rate_limit_is_shared_and_returns_retry_after(repo):
    for _ in range(60):
        assert invoke("GET", "/v1/sync-status", token=False)[1] == 200
    _, status, headers = invoke("GET", "/v1/sync-status", token=False)
    assert status == 429
    assert headers["Retry-After"] == "60"


def test_oversized_payload(repo):
    assert invoke("POST", "/v1/sync", raw=b" " * (main.MAX_BODY + 1))[1] == 413


def test_31_day_month_with_dst_fall_back_is_allowed(repo, monkeypatch):
    monkeypatch.setattr(repo, "query", lambda *args, **kwargs: [])
    # October in London lasts 31 days plus one hour.
    query = "/v1/summaries?metric=heart_rate&from=2026-09-30T23:00:00Z&to=2026-11-01T00:00:00Z&timezone=Europe%2FLondon&bucket=day"
    assert invoke("GET", query, token=False)[1] == 200


def test_dst_day_buckets_keep_calendar_boundaries(repo):
    from zoneinfo import ZoneInfo
    docs = [Snapshot(Reference(repo.db, str(index)), {"start": datetime.fromisoformat(stamp), "value": value})
            for index, (stamp, value) in enumerate([
                ("2026-11-01T05:30:00+00:00", 60), ("2026-11-01T06:30:00+00:00", 80)])]
    zone = ZoneInfo("America/New_York")
    assert len(main.summaries(docs, zone, "day")) == 1
    assert main.summaries(docs, zone, "day")[0]["average"] == 70
    assert len(main.summaries(docs, zone, "hour")) == 2


HISTORY_QUERY = "metric=heart_rate&from=2026-10-09T00:00:00Z&to=2026-10-10T00:00:00Z"


def test_history_includes_ingestion_without_extra_status_request(repo, monkeypatch):
    invoke("POST", "/v1/sync", upload(repo))
    docs = list(repo.samples(repo.status()["generation"]).limit(10).stream())
    monkeypatch.setattr(repo, "query", lambda *args: docs)
    for path in ("/v1/samples", "/v1/summaries"):
        result, status, headers = invoke("GET", path + "?" + HISTORY_QUERY, token=False)
        assert status == 200
        assert result["last_ingestion"] == repo.status()["last_ingestion"].isoformat()
        assert headers["Cache-Control"] == "no-store"


def test_summary_cache_avoids_sample_reads_and_invalidates_after_sync(repo, monkeypatch):
    batch = upload(repo)
    invoke("POST", "/v1/sync", batch)
    queries = []
    def query(state, *args):
        queries.append(state)
        return list(repo.samples(state["generation"]).limit(10).stream())
    monkeypatch.setattr(repo, "query", query)
    path = "/v1/summaries?" + HISTORY_QUERY
    first = invoke("GET", path, token=False)
    assert invoke("GET", path, token=False) == first
    assert len(queries) == 1
    budget = repo.db.values["api_limits/public"]
    assert budget["requests"] == 2
    assert budget["reserved_reads"] == main.MAX_SUMMARY_SAMPLES + 1
    invoke("POST", "/v1/sync", upload(repo, generation=batch["generation"]))
    result, status, _ = invoke("GET", path, token=False)
    assert status == 200 and result["summary"]["count"] == 2
    assert len(queries) == 2


def test_summary_cache_respects_deletion_fence(repo, monkeypatch):
    batch = upload(repo)
    invoke("POST", "/v1/sync", batch)
    def query(state, *args):
        return list(repo.samples(state["generation"]).limit(10).stream()) if state.get("enabled") else []
    monkeypatch.setattr(repo, "query", query)
    path = "/v1/summaries?" + HISTORY_QUERY
    assert invoke("GET", path, token=False)[0]["summary"]["count"] == 1
    monkeypatch.setattr(main, "enqueue_cleanup", lambda state: None)
    invoke("DELETE", "/v1/data", {"generation": batch["generation"], "deletion_id": str(uuid4())})
    assert invoke("GET", path, token=False)[0]["summary"]["count"] == 0


def test_cached_summary_still_rechecks_fence(repo, monkeypatch):
    monkeypatch.setattr(repo, "query", lambda *args: [])
    path = "/v1/summaries?" + HISTORY_QUERY
    assert invoke("GET", path, token=False)[1] == 200
    states = iter([{}, {"generation": "changed", "enabled": True}])
    monkeypatch.setattr(repo, "status", lambda: next(states))
    assert invoke("GET", path, token=False)[1] == 409


def test_cached_summary_still_enforces_request_allowance(repo, monkeypatch):
    monkeypatch.setattr(repo, "query", lambda *args: [])
    path = "/v1/summaries?" + HISTORY_QUERY
    for _ in range(60):
        assert invoke("GET", path, token=False)[1] == 200
    assert invoke("GET", path, token=False)[1] == 429


@pytest.mark.parametrize("path", [
    "/v1/samples?" + HISTORY_QUERY + "&limit=501",
    "/v1/summaries?" + HISTORY_QUERY + "&bucket=month",
    "/v1/summaries?" + HISTORY_QUERY + "&timezone=Invalid/Zone",
])
def test_invalid_query_options_do_not_read_firestore(repo, monkeypatch, path):
    def unexpected():
        pytest.fail("Invalid query must be rejected before reading Firestore")
    monkeypatch.setattr(repo, "status", unexpected)
    assert invoke("GET", path, token=False)[1] == 400

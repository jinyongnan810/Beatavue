"""Optional SDK integration checks; run only against the local Firestore emulator."""
import hashlib
import json
import os
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from uuid import uuid4

import pytest
from google.cloud import firestore

import main
from models import DeleteRequest, SyncBatch
from repository import Conflict, Repository
from test_api import invoke, sample

pytestmark = pytest.mark.skipif(not os.environ.get("FIRESTORE_EMULATOR_HOST"), reason="Local Firestore emulator not configured")


@pytest.fixture
def live_repo(monkeypatch):
    assert os.environ["FIRESTORE_EMULATOR_HOST"] in ("127.0.0.1:8081", "localhost:8081"), "Never run these tests against a remote service"
    # Unique demo namespace prevents collisions with another local application.
    repo = Repository(firestore.Client(project="demo-beatavue-test-" + uuid4().hex[:8]))
    monkeypatch.setattr(main, "repository", lambda: repo)
    monkeypatch.setenv("UPLOAD_TOKEN", "test-only-" + "x" * 40)
    return repo


def batch(generation, values):
    return {"schema_version": 1, "generation": generation, "batch_id": str(uuid4()),
            "operations": [{"kind": "upsert", "uuid": value["uuid"], "sample": value} for value in values]}


def test_sdk_pagination_keeps_overlapping_samples_and_hides_uuids(live_repo):
    generation = live_repo.begin_import(uuid4())["generation"]
    values = [sample() for _ in range(3)]
    assert invoke("POST", "/v1/sync", batch(generation, values))[1] == 200
    query = "/v1/samples?metric=heart_rate&from=2026-10-09T00:00:00Z&to=2026-10-10T00:00:00Z&limit=2"
    first, status, _ = invoke("GET", query, token=False)
    assert status == 200
    assert len(first["samples"]) == 2 and first["next_cursor"]
    second, status, _ = invoke("GET", query + "&cursor=" + first["next_cursor"], token=False)
    assert status == 200
    assert len(second["samples"]) == 1 and second["next_cursor"] is None
    for value in values:
        assert value["uuid"] not in json.dumps(first)


def test_sdk_concurrent_retries_commit_one_receipt(live_repo):
    generation = live_repo.begin_import(uuid4())["generation"]
    payload = SyncBatch.model_validate(batch(generation, [sample()]))
    digest = hashlib.sha256(payload.model_dump_json().encode()).hexdigest()
    with ThreadPoolExecutor(max_workers=4) as pool:
        acknowledgments = list(pool.map(lambda _: live_repo.sync(payload, digest), range(4)))
    assert acknowledgments.count(acknowledgments[0]) == 4
    assert len(list(live_repo.samples(generation).stream())) == 1


def test_sdk_deletion_worker_purges_and_generation_fences_retry(live_repo):
    generation = live_repo.begin_import(uuid4())["generation"]
    payload = batch(generation, [sample(), sample()])
    assert invoke("POST", "/v1/sync", payload)[1] == 200
    live_repo.begin_delete(DeleteRequest(generation=generation, deletion_id=uuid4()))
    assert invoke("POST", "/v1/sync", payload)[1] == 409
    # Exercise the actual HTTP cleanup entry point without requiring Cloud Tasks IAM locally.
    from flask import Flask, request
    with Flask(__name__).test_request_context("/", method="POST", json={"generation": generation}):
        assert main.cleanup(request)[1] == 200
    assert live_repo.status()["cleanup_pending"] is False
    assert list(live_repo.samples(generation).stream()) == []
    with pytest.raises(Conflict):
        live_repo.begin_import(generation)


def test_sdk_public_summary_exact_and_private_metadata_absent(live_repo):
    generation = live_repo.begin_import(uuid4())["generation"]
    values = [sample(), sample()]
    values[0]["value"], values[1]["value"] = 60, 80
    assert invoke("POST", "/v1/sync", batch(generation, values))[1] == 200
    result, status, _ = invoke("GET", "/v1/summaries?metric=heart_rate&from=2026-10-09T00:00:00Z&to=2026-10-10T00:00:00Z&timezone=Asia%2FTokyo&bucket=day", token=False)
    assert status == 200
    assert result["summary"] == {"count": 2, "min": 60, "max": 80, "average": 70}
    assert len(result["buckets"]) == 1
    assert "Private device" not in json.dumps(result)

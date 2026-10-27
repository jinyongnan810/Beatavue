"""Live data must stay ephemeral, ordered, authenticated and generation fenced."""
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
from pydantic import ValidationError
import main
from models import LiveUpdate
from realtime import Realtime
from test_api import repo, invoke


def payload(generation=None, updating=True):
    now = datetime.now(timezone.utc)
    return {"generation": generation or str(uuid4()), "session_id": str(uuid4()),
            "started_at": (now - timedelta(minutes=1)).isoformat(), "sent_at": now.isoformat(),
            "updating": updating, "heart_rate": 72 if updating else None,
            "measured_at": now.isoformat() if updating else None}


class MemoryRealtime(Realtime):
    def __init__(self):
        self.value = None

    def _replace(self, transform):
        self.value = transform(self.value)


@pytest.fixture
def live(monkeypatch):
    live = MemoryRealtime()
    monkeypatch.setattr(main, "realtime", lambda: live)
    return live


def test_live_authentication_precedes_all_database_access(monkeypatch):
    monkeypatch.setattr(main, "realtime", lambda: pytest.fail("Unauthorized database access"))
    monkeypatch.setattr(main, "repository", lambda: pytest.fail("Unauthorized Firestore access"))
    for path in ("/v1/live", "/v1/live/clear"):
        assert invoke("POST", path, payload(), token=False)[1] == 401


def test_live_only_writes_realtime_and_stop_clears_value(repo, live):
    generation = repo.begin_import(uuid4())["generation"]
    before = dict(repo.db.values)
    update = payload(generation)
    assert invoke("POST", "/v1/live", update)[1] == 200
    assert live.value["heart_rate"] == 72 and live.value["updating"] is True
    assert repo.db.values == before
    stop = {**update, "sent_at": datetime.now(timezone.utc).isoformat(),
            "updating": False, "heart_rate": None, "measured_at": None}
    assert invoke("POST", "/v1/live", stop)[1] == 200
    assert live.value["heart_rate"] is None and live.value["updating"] is False


def test_old_events_and_old_workouts_cannot_overwrite_latest(live):
    older = payload()
    newest = {**older, "sent_at": (datetime.now(timezone.utc) + timedelta(seconds=1)).isoformat(), "heart_rate": 85}
    live.update(LiveUpdate.model_validate(newest))
    live.update(LiveUpdate.model_validate(older))
    assert live.value["heart_rate"] == 85
    old_workout = {**newest, "started_at": (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat(), "heart_rate": 60}
    live.update(LiveUpdate.model_validate(old_workout))
    assert live.value["heart_rate"] == 85


def test_stale_generation_rejected_and_deletion_race_clears_live(repo, live, monkeypatch):
    generation = repo.begin_import(uuid4())["generation"]
    assert invoke("POST", "/v1/live", payload())[1] == 409
    states = iter([{"generation": generation, "enabled": True}, {"generation": generation, "enabled": False}])
    monkeypatch.setattr(repo, "status", lambda: next(states))
    assert invoke("POST", "/v1/live", payload(generation))[1] == 409
    assert live.value is None


def test_generation_scoped_clear_cannot_clear_new_publication(live):
    update = payload()
    live.update(LiveUpdate.model_validate(update))
    live.clear(str(uuid4()))
    assert live.value is not None
    live.clear(update["generation"])
    assert live.value is None


def test_public_projection_hides_metadata_stale_readings_and_deleted_data(live):
    update = payload()
    live.update(LiveUpdate.model_validate(update))
    state = {"enabled": True, "generation": update["generation"]}
    now = datetime.now(timezone.utc)
    view = live.public(live.value, state, now)
    assert view["heart_rate"] == 72 and view["updating"] is True
    assert set(view) == {"heart_rate", "updating", "measured_at", "updated_at"}
    for state_override, stamp in [(state, now + timedelta(seconds=31)), ({**state, "enabled": False}, now),
                                  ({**state, "generation": str(uuid4())}, now)]:
        view = live.public(live.value, state_override, stamp)
        assert view["heart_rate"] is None and view["updating"] is False


@pytest.mark.parametrize("changes", [{"heart_rate": float("nan")}, {"heart_rate": -1}, {"heart_rate": 401},
                                       {"measured_at": None}, {"updating": "true"},
                                       {"sent_at": "2020-01-01T00:00:00Z"}, {"sent_at": "2026-10-13T00:00:00"}])
def test_invalid_live_readings_rejected(changes):
    with pytest.raises(ValidationError):
        LiveUpdate.model_validate({**payload(), **changes})


def test_compare_and_swap_retries_contention_with_the_new_etag(monkeypatch):
    import realtime as module
    class Reply:
        status_code = 200
        headers = {"ETag": '"new-etag"'}
        def json(self):
            return None
        def raise_for_status(self):
            assert self.status_code == 200
    class Session:
        def __enter__(self):
            return self
        def __exit__(self, *args):
            pass
        def get(self, url, **kwargs):
            assert kwargs["headers"] == {"X-Firebase-ETag": "true"}
            return Reply()
        def put(self, url, **kwargs):
            assert kwargs["headers"] == {"if-match": '"new-etag"', "Content-Type": "application/json"}
            import json
            writes.append(json.loads(kwargs["data"]))
            reply = Reply()
            if len(writes) == 1:
                reply.status_code = 412
            return reply
    writes = []
    monkeypatch.setattr(module, "AuthorizedSession", lambda credentials: Session())
    live = object.__new__(Realtime)
    live.url, live.credentials = "https://example.test/live.json", None
    live.update(LiveUpdate.model_validate(payload()))
    assert len(writes) == 2
    assert writes[-1]["updated_at"] == {".sv": "timestamp"}


def test_chronological_order_handles_fractional_seconds_and_other_generations(live):
    update = payload()
    whole = datetime.now(timezone.utc).replace(microsecond=0)
    update["sent_at"] = whole.isoformat()
    update["measured_at"] = whole.isoformat()
    live.update(LiveUpdate.model_validate(update))
    later = {**update, "generation": str(uuid4()), "heart_rate": 86,
             "sent_at": (whole + timedelta(milliseconds=500)).isoformat()}
    live.update(LiveUpdate.model_validate(later))
    live.update(LiveUpdate.model_validate(update))
    assert live.value["heart_rate"] == 86


def test_public_stream_has_cors_no_cache_and_only_public_events(repo, live, monkeypatch):
    from flask import Flask, request
    monkeypatch.setattr(live, "events", lambda status: iter(['event: live\ndata: {"updating": false}\n\n']))
    with Flask(__name__).test_request_context('/v1/live', headers={'Origin': main.WEB_ORIGIN}):
        response = main.api(request)
        assert response.status_code == 200
        assert response.headers['Access-Control-Allow-Origin'] == main.WEB_ORIGIN
        assert response.headers['Cache-Control'] == 'no-store'
        assert response.mimetype == 'text/event-stream'
        assert 'generation' not in response.get_data(as_text=True)


def test_clear_sends_explicit_json_null_with_compare_and_swap(monkeypatch):
    import realtime as module
    from unittest.mock import MagicMock
    generation = str(uuid4())
    http = MagicMock()
    http.__enter__.return_value = http
    http.get.return_value.json.return_value = {"generation": generation}
    http.get.return_value.headers = {"ETag": '"current"'}
    http.put.return_value.status_code = 200
    monkeypatch.setattr(module, "AuthorizedSession", lambda credentials: http)
    live = object.__new__(Realtime)
    live.url, live.credentials = 'https://example.test/live.json', None
    live.clear(generation)
    assert http.put.call_args.kwargs['data'] == 'null'
    assert http.put.call_args.kwargs['headers']['if-match'] == '"current"'

"""Public API admission must happen before data access."""
import pytest
from flask import Flask, make_response, request
import main
import security
from unittest.mock import MagicMock
from test_api import repo


def call(method="GET", path="/v1/live", headers=None):
    with Flask(__name__).test_request_context(path, method=method, headers=headers or {}):
        return make_response(main.api(request))


@pytest.mark.parametrize("path", sorted(main.PUBLIC_PATHS))
def test_foreign_origins_rejected_before_database_access(monkeypatch, path):
    monkeypatch.setattr(main, "repository", lambda: pytest.fail("Database accessed"))
    result = call(path=path, headers={"Origin": "https://evil.example"})
    assert result.status_code == 403
    assert "Access-Control-Allow-Origin" not in result.headers


def test_app_check_preflight_is_exact_and_does_not_touch_database(monkeypatch):
    monkeypatch.setattr(main, "repository", lambda: pytest.fail("Database accessed"))
    headers = {"Origin": main.WEB_ORIGIN, "Access-Control-Request-Method": "GET",
               "Access-Control-Request-Headers": "X-Firebase-AppCheck"}
    result = call("OPTIONS", headers=headers)
    assert result.status_code == 204
    assert result.headers["Access-Control-Allow-Origin"] == main.WEB_ORIGIN
    assert result.headers["Vary"] == "Origin"
    for override in ({"Origin": "null"}, {"Access-Control-Request-Method": "POST"},
                     {"Access-Control-Request-Headers": "Authorization"}):
        assert call("OPTIONS", headers={**headers, **override}).status_code == 403


@pytest.fixture
def configured(monkeypatch):
    monkeypatch.setenv("APP_CHECK_APP_ID", "1:256425564793:web:test")
    monkeypatch.setenv("FIREBASE_PROJECT_NUMBER", "256425564793")
    monkeypatch.setattr(security, "firebase_app", lambda: None)
    monkeypatch.setattr(main, "repository", lambda: pytest.fail("Database accessed"))


@pytest.mark.parametrize("path", sorted(main.PUBLIC_PATHS))
def test_missing_attestation_rejected_even_without_origin(configured, path):
    assert call(path=path).status_code == 401


def test_owner_bearer_does_not_bypass_public_attestation(configured, monkeypatch):
    monkeypatch.setenv("UPLOAD_TOKEN", "x" * 40)
    assert call(headers={"Authorization": "Bearer " + "x" * 40}).status_code == 401


def test_oversized_token_rejected_without_verification(configured, monkeypatch):
    monkeypatch.setattr(security.app_check, "verify_token", lambda *a, **kw: pytest.fail("Verifier called"))
    assert call(headers={"X-Firebase-AppCheck": "x" * 4097}).status_code == 401


@pytest.mark.parametrize("failure", ["invalid", "expired", "wrong-project"])
def test_invalid_tokens_fail_before_admission(configured, monkeypatch, failure):
    monkeypatch.setattr(security.app_check, "verify_token", MagicMock(side_effect=ValueError(failure)))
    monkeypatch.setattr(main, "admission", lambda: pytest.fail("Limiter accessed"))
    result = call(headers={"Origin": main.WEB_ORIGIN, "X-Firebase-AppCheck": "bad-token"})
    assert result.status_code == 401
    assert result.headers["Access-Control-Allow-Origin"] == main.WEB_ORIGIN


@pytest.mark.parametrize("claims", [
    {"app_id": "another-app", "iss": "https://firebaseappcheck.googleapis.com/256425564793"},
    {"app_id": "1:256425564793:web:test", "iss": "https://firebaseappcheck.googleapis.com/other"},
])
def test_other_app_or_issuer_rejected(configured, monkeypatch, claims):
    monkeypatch.setattr(security.app_check, "verify_token", lambda *args, **kwargs: claims)
    assert call(headers={"X-Firebase-AppCheck": "token"}).status_code == 401


def test_missing_server_config_fails_closed(monkeypatch):
    monkeypatch.delenv("APP_CHECK_APP_ID", raising=False)
    monkeypatch.setattr(main, "repository", lambda: pytest.fail("Database accessed"))
    assert call().status_code == 503


def test_verifier_outage_fails_closed(configured, monkeypatch):
    monkeypatch.setattr(security.app_check, "verify_token", MagicMock(side_effect=RuntimeError("offline")))
    assert call(headers={"X-Firebase-AppCheck": "token"}).status_code == 503


def test_rate_rejection_has_retry_and_cors_before_health_data(configured, monkeypatch):
    monkeypatch.setattr(main, "verify", lambda request: "client")
    limiter = MagicMock()
    limiter.reserve.side_effect = security.AdmissionLimited(55)
    monkeypatch.setattr(main, "admission", lambda: limiter)
    result = call(headers={"Origin": main.WEB_ORIGIN})
    assert result.status_code == 429
    assert result.headers["Retry-After"] == "55"
    assert result.headers["Access-Control-Allow-Origin"] == main.WEB_ORIGIN


def test_stream_releases_once_on_completion_or_disconnect(repo, monkeypatch):
    limiter = main.admission()
    live = MagicMock()
    live.events.return_value = iter(["event: live\ndata: {}\n\n"])
    monkeypatch.setattr(main, "realtime", lambda: live)
    result = call()
    assert result.status_code == 200
    result.get_data()
    result.close()
    limiter.release.assert_called_once()


def test_distributed_admission_windows_leases_and_recovery(repo, monkeypatch):
    # Uses the same transactional memory adapter as the real repository tests.
    limiter = security.Admission(repo.db)
    clock = [1000.0]
    monkeypatch.setattr(security.time, "time", lambda: clock[0])
    first = limiter.reserve("client", True)
    second = limiter.reserve("client", True)
    with pytest.raises(security.AdmissionLimited):
        limiter.reserve("client", True)
    limiter.release(first)
    limiter.reserve("client", True)
    clock[0] += security.LEASE_SECONDS + 1
    limiter.reserve("client", True)  # Crashed streams expire.
    limiter.release(second)  # A delayed release cannot remove newer reservations.
    for _ in range(security.REQUESTS_PER_MINUTE - 1):
        limiter.reserve("client")
    with pytest.raises(security.AdmissionLimited):
        limiter.reserve("client")
    clock[0] += 60
    limiter.reserve("client")


def test_global_stream_cap_applies_across_tokens(repo):
    limiter = security.Admission(repo.db)
    reservations = [limiter.reserve(str(i), True) for i in range(security.STREAMS_TOTAL)]
    with pytest.raises(security.AdmissionLimited):
        limiter.reserve("new-client", True)
    limiter.release(reservations[0])
    limiter.reserve("new-client", True)


def test_real_sdk_verifies_signature_expiry_and_project(configured, monkeypatch):
    import time
    import jwt
    from cryptography.hazmat.primitives.asymmetric import rsa
    from google.auth.credentials import AnonymousCredentials
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    app = MagicMock(project_id="256425564793", options={})
    app.credential.get_credential.return_value = AnonymousCredentials()
    service = security.app_check._AppCheckService(app)
    service._jwks_client = MagicMock()
    service._jwks_client.get_signing_key_from_jwt.return_value.key = key.public_key()
    monkeypatch.setattr(security.app_check, "verify_token", lambda token, **kwargs: service.verify_token(token))
    claims = {"sub": "1:256425564793:web:test", "aud": ["projects/256425564793"],
              "iss": "https://firebaseappcheck.googleapis.com/256425564793",
              "iat": int(time.time()) - 10, "exp": int(time.time()) + 3600}
    def verify(payload, signing_key=key):
        token = jwt.encode(payload, signing_key, algorithm="RS256", headers={"kid": "test"})
        with Flask(__name__).test_request_context(headers={"X-Firebase-AppCheck": token}):
            return security.verify(request)
    assert len(verify(claims)) == 64
    for override in ({"aud": ["projects/other"]}, {"exp": 1}, {"sub": "another-app"},
                     {"iss": "https://firebaseappcheck.googleapis.com/other"}):
        with pytest.raises(security.InvalidAttestation):
            verify({**claims, **override})
    with pytest.raises(security.InvalidAttestation):
        verify(claims, rsa.generate_private_key(public_exponent=65537, key_size=2048))

"""Public API admission must happen before data access."""
import pytest
from flask import Flask, make_response, request
import main


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

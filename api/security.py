"""App attestation and shared admission limits; no client IP headers are trusted."""
import hashlib
import os
import time
from datetime import datetime, timezone
from functools import lru_cache
from threading import Lock
from uuid import uuid4

import firebase_admin
from firebase_admin import app_check
from google.cloud import firestore
from jwt import PyJWKClientError, PyJWKClientConnectionError

REQUESTS_PER_MINUTE = 120
STREAMS_PER_TOKEN = 2
STREAMS_TOTAL = 10
LEASE_SECONDS = 55  # Stream duration is 40 seconds; dead instances recover automatically.
_APP_LOCK = Lock()


class InvalidAttestation(Exception):
    pass


class AdmissionLimited(Exception):
    def __init__(self, retry_after):
        self.retry_after = max(1, int(retry_after))


@lru_cache
def firebase_app():
    # App Check JWT audiences and issuers use the numeric project number.
    # lru_cache alone allows concurrent initialization on a cold instance.
    with _APP_LOCK:
        try:
            return firebase_admin.get_app("beatavue-app-check")
        except ValueError:
            return firebase_admin.initialize_app(
                options={"projectId": os.environ["FIREBASE_PROJECT_NUMBER"]}, name="beatavue-app-check")


def verify(request):
    # No bypass flag: missing configuration fails closed as a service error.
    expected_app = os.environ.get("APP_CHECK_APP_ID")
    if not expected_app:
        raise RuntimeError("App Check app ID is not configured")
    token = request.headers.get("X-Firebase-AppCheck", "")
    if not token or len(token) > 4096:
        raise InvalidAttestation()
    try:
        claims = app_check.verify_token(token, app=firebase_app())
    except PyJWKClientConnectionError as error:
        raise RuntimeError("Signing keys unavailable") from error
    except (ValueError, PyJWKClientError) as error:
        raise InvalidAttestation() from error
    if (claims.get("app_id") != expected_app or
            claims.get("iss") != "https://firebaseappcheck.googleapis.com/" + os.environ["FIREBASE_PROJECT_NUMBER"]):
        raise InvalidAttestation()
    return hashlib.sha256(token.encode()).hexdigest()


@lru_cache
def admission():
    return Admission(firestore.Client())


class Admission:
    def __init__(self, db):
        self.db = db

    def reserve(self, client, streaming=False):
        now = time.time()
        minute = int(now // 60)
        lease = uuid4().hex
        ref = self.db.collection("api_clients").document(client)
        shared = self.db.collection("api_limits").document("streams")

        @firestore.transactional
        def commit(tx):
            state = ref.get(transaction=tx).to_dict() or {}
            global_state = (shared.get(transaction=tx).to_dict() or {}) if streaming else {}
            count = state.get("count", 0) if state.get("minute") == minute else 0
            leases = {k: v for k, v in state.get("leases", {}).items() if v > now}
            global_leases = {k: v for k, v in global_state.get("leases", {}).items() if v > now}
            if count >= REQUESTS_PER_MINUTE:
                raise AdmissionLimited(60 - now % 60 + 1)
            if streaming:
                if len(leases) >= STREAMS_PER_TOKEN or len(global_leases) >= STREAMS_TOTAL:
                    raise AdmissionLimited(LEASE_SECONDS)
                leases[lease] = global_leases[lease] = now + LEASE_SECONDS
            tx.set(ref, {"minute": minute, "count": count + 1, "leases": leases,
                         "expires_at": datetime.fromtimestamp(now + 86400, timezone.utc)})
            if streaming:
                tx.set(shared, {"leases": global_leases})
        commit(self.db.transaction())
        return (client, lease) if streaming else None

    def release(self, reservation):
        client, lease = reservation
        refs = [self.db.collection("api_clients").document(client),
                self.db.collection("api_limits").document("streams")]

        @firestore.transactional
        def commit(tx):
            states = [ref.get(transaction=tx).to_dict() or {} for ref in refs]
            for ref, state in zip(refs, states):
                if lease in state.get("leases", {}):
                    del state["leases"][lease]
                    tx.set(ref, state)
        commit(self.db.transaction())

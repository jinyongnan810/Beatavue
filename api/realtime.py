"""A single current reading in RTDB, with compare-and-swap and public SSE projection."""
import json
import os
import time
from datetime import datetime, timezone
from queue import Empty, Queue
from threading import Event, Thread

import google.auth
from google.auth.transport.requests import AuthorizedSession
from repository import Conflict


class Realtime:
    def __init__(self):
        self.url = os.environ["REALTIME_DATABASE_URL"].rstrip("/") + "/live.json"
        self.credentials, _ = google.auth.default(scopes=[
            "https://www.googleapis.com/auth/firebase.database",
            "https://www.googleapis.com/auth/userinfo.email",
        ])

    def _replace(self, transform):
        # A separate session per operation avoids sharing requests.Session across threads.
        with AuthorizedSession(self.credentials) as http:
            for _ in range(5):
                current = http.get(self.url, headers={"X-Firebase-ETag": "true"}, timeout=5)
                current.raise_for_status()
                old = current.json()
                value = transform(old)
                if value == old:
                    return
                result = http.put(self.url, data=json.dumps(value),
                                  headers={"if-match": current.headers["ETag"],
                                           "Content-Type": "application/json"}, timeout=5)
                if result.status_code != 412:
                    result.raise_for_status()
                    return
        raise Conflict("Live update contention; send the latest state again")

    def update(self, update):
        value = update.model_dump(mode="json")
        value["updated_at"] = {".sv": "timestamp"}

        def replace(old):
            if old:
                # Session start orders different workouts; sent_at orders each session's states.
                def order(record):
                    return tuple(datetime.fromisoformat(record[key].replace("Z", "+00:00"))
                                 for key in ("started_at", "sent_at"))
                if order(old) >= order(value):
                    return old
            return value
        self._replace(replace)

    def clear(self, generation):
        self._replace(lambda old: None if old and old.get("generation") == generation else old)

    @staticmethod
    def public(value, state, now=None):
        now = now or datetime.now(timezone.utc)
        if not value or not state.get("enabled") or value.get("generation") != state.get("generation"):
            return {"heart_rate": None, "updating": False, "measured_at": None, "updated_at": None}
        stamp = value.get("measured_at")
        fresh = (stamp is not None and 0 <= (now - datetime.fromisoformat(stamp.replace("Z", "+00:00"))).total_seconds() <= 30)
        active = value.get("updating") is True and fresh
        return {"heart_rate": value.get("heart_rate") if active else None, "updating": active,
                "measured_at": stamp if active else None, "updated_at": value.get("updated_at")}

    def events(self, publication_state):
        # Bound each browser connection below the function deadline. The fetch client reconnects.
        # The reader runs independently so an idle upstream cannot delay pings or the deadline.
        queue = Queue(maxsize=1)
        stopped = Event()

        def offer(value):
            try:
                queue.get_nowait()
            except Empty:
                pass
            queue.put_nowait(value)

        def read():
            try:
                with AuthorizedSession(self.credentials) as http:
                    with http.get(self.url, headers={"Accept": "text/event-stream"},
                                  stream=True, timeout=(5, 45)) as upstream:
                        upstream.raise_for_status()
                        event, data = "", []
                        for line in upstream.iter_lines(chunk_size=1, decode_unicode=True):
                            if stopped.is_set():
                                return
                            if not line:
                                if event == "put" and data:
                                    message = json.loads("\n".join(data))
                                    if message["path"] != "/":
                                        raise ValueError("Unexpected partial live update")
                                    offer(("live", message["data"]))
                                elif event in ("cancel", "auth_revoked"):
                                    raise ValueError("Upstream unavailable")
                                event, data = "", []
                            elif line.startswith("event:"):
                                event = line[6:].strip()
                            elif line.startswith("data:"):
                                data.append(line[5:].strip())
                if not stopped.is_set():
                    offer(("unavailable", None))
            except Exception:
                if not stopped.is_set():
                    offer(("unavailable", None))

        thread = Thread(target=read, daemon=True)
        thread.start()
        deadline = time.monotonic() + 40
        value, previous = None, None
        state, state_at = {}, 0
        try:
            yield "retry: 1000\n\n"
            while time.monotonic() < deadline:
                try:
                    event, value = queue.get(timeout=1)
                    if event == "unavailable":
                        yield "event: unavailable\ndata: {}\n\n"
                        return
                except Empty:
                    event = None
                if time.monotonic() - state_at >= 5 or event == "live":
                    state = publication_state()
                    state_at = time.monotonic()
                if event == "live" or previous is not None:
                    projected = self.public(value, state)
                    if projected != previous:
                        yield "event: live\ndata: " + json.dumps(projected) + "\n\n"
                        previous = projected
                yield ": heartbeat\n\n"
            # Clients reconnect deliberately without briefly displaying an offline state.
            yield "event: reconnect\ndata: {}\n\n"
        except Exception:
            yield "event: unavailable\ndata: {}\n\n"
        finally:
            stopped.set()

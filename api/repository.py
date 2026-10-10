"""Firestore is the authority for generation fences, receipts, and tombstones."""
import hashlib
from datetime import datetime, timezone

from google.cloud import firestore
from google.cloud.firestore_v1.base_query import FieldFilter


class Conflict(Exception):
    pass


class RateLimited(Exception):
    pass


# Hash the sample UUID so document IDs do not expose it in public cursors.
def document_id(uuid):
    # Cursor document IDs cannot disclose the original HealthKit UUID.
    return hashlib.sha256(str(uuid).lower().encode()).hexdigest()


class Repository:
    # Connect to Firestore and select the single server-owned dataset.
    def __init__(self, client=None):
        self.db = client or firestore.Client()
        self.owner = self.db.collection("datasets").document("owner")

    # Read the current publication state, generation, and cleanup status.
    def status(self):
        return self.owner.get().to_dict() or {}

    # Locate the sample collection belonging to a publication generation.
    def samples(self, generation):
        return self.owner.collection("generations").document(str(generation)).collection("samples")

    # Start or reuse an import while rejecting cleanup and retired generations.
    def begin_import(self, import_id):
        generation = str(import_id)
        marker = self.owner.collection("generations").document(generation)

        # Atomically activate the import and record its generation marker.
        @firestore.transactional
        def commit(tx):
            state = self.owner.get(transaction=tx).to_dict() or {}
            prior = marker.get(transaction=tx).to_dict() or {}
            if state.get("cleanup_pending"):
                raise Conflict("Deletion is still in progress")
            if state.get("enabled"):
                return {"generation": state["generation"]}
            # Old import requests cannot re-enable a previously deleted generation.
            if state.get("generation") == generation or prior.get("retired"):
                raise Conflict("This import was deleted; start a new import")
            tx.set(self.owner, {"generation": generation, "enabled": True,
                                "last_ingestion": None, "cleanup_pending": False})
            tx.set(marker, {"retired": False})
            return {"generation": generation}

        return commit(self.db.transaction())

    # Apply a generation-scoped batch with a durable receipt for safe retries.
    def sync(self, batch, digest):
        generation = str(batch.generation)
        receipt = self.owner.collection("generations").document(generation).collection("batches").document(str(batch.batch_id))

        # Atomically validate the batch, apply operations, and save its acknowledgment.
        @firestore.transactional
        def commit(tx):
            state = self.owner.get(transaction=tx).to_dict() or {}
            if not state.get("enabled") or state.get("generation") != generation:
                raise Conflict("Import is disabled or generation is stale")
            previous = receipt.get(transaction=tx).to_dict()
            if previous:
                if previous["digest"] != digest:
                    raise Conflict("Batch ID already used for a different payload")
                return previous["ack"]
            refs = [self.samples(generation).document(document_id(op.uuid)) for op in batch.operations]
            existing = [ref.get(transaction=tx).to_dict() or {} for ref in refs]
            now = datetime.now(timezone.utc)
            for op, ref, old in zip(batch.operations, refs, existing):
                if op.kind == "delete":
                    tx.set(ref, {"deleted": True, "deleted_at": now})
                elif not old.get("deleted"):
                    value = op.sample.model_dump(mode="python")
                    value["uuid"] = str(op.uuid)
                    value.update(deleted=False, ingested_at=now, schema_version=1)
                    tx.set(ref, value)
            ack = {"batch_id": str(batch.batch_id), "generation": generation,
                   "acknowledged": len(batch.operations), "ingested_at": now.isoformat()}
            tx.set(receipt, {"digest": digest, "ack": ack})
            tx.update(self.owner, {"last_ingestion": now})
            return ack

        return commit(self.db.transaction())

    # Fence the generation and reuse the deletion ID across repeated requests.
    def begin_delete(self, request):
        generation = str(request.generation)
        deletion_id = str(request.deletion_id)

        # Atomically hide the dataset and mark its generation as retired.
        @firestore.transactional
        def commit(tx):
            state = self.owner.get(transaction=tx).to_dict() or {}
            if state.get("deletion_id") == deletion_id:
                if state.get("generation") != generation:
                    raise Conflict("Deletion ID reused for a different generation")
                return state
            if state.get("generation") != generation:
                raise Conflict("Generation is stale")
            if state.get("cleanup_pending"):
                raise Conflict("Another deletion is in progress")
            state.update(enabled=False, cleanup_pending=True, deletion_id=deletion_id, last_ingestion=None)
            tx.set(self.owner, state)
            tx.set(self.owner.collection("generations").document(generation), {"retired": True})
            return state

        return commit(self.db.transaction())

    # Reserve request and sample-read capacity from the shared minute allowance.
    def reserve_public_reads(self, maximum_reads):
        """Shared demo-wide allowance; it cannot be bypassed by changing an IP header."""
        ref = self.db.collection("api_limits").document("public")
        minute = int(datetime.now(timezone.utc).timestamp()) // 60

        # Atomically reset or debit the current minute allowance without exceeding limits.
        @firestore.transactional
        def reserve(tx):
            budget = ref.get(transaction=tx).to_dict() or {}
            if budget.get("minute") != minute:
                budget = {"minute": minute, "requests": 0, "reserved_reads": 0}
            if budget["requests"] >= 60 or budget["reserved_reads"] + maximum_reads > 100000:
                raise RateLimited()
            budget["requests"] += 1
            budget["reserved_reads"] += maximum_reads
            tx.set(ref, budget)

        reserve(self.db.transaction())

    # Delete at most 200 samples or receipts, then finish cleanup when empty.
    def cleanup_chunk(self, generation):
        state = self.status()
        if state.get("generation") != generation or state.get("enabled") or not state.get("cleanup_pending"):
            return True
        base = self.owner.collection("generations").document(generation)
        for collection in ("samples", "batches"):
            docs = list(base.collection(collection).limit(200).stream())
            if docs:
                batch = self.db.batch()
                for doc in docs:
                    batch.delete(doc.reference)
                batch.commit()
                return False

        # Clear pending cleanup only if the same generation is still disabled.
        @firestore.transactional
        def finish(tx):
            current = self.owner.get(transaction=tx).to_dict() or {}
            if current.get("generation") == generation and not current.get("enabled"):
                tx.update(self.owner, {"cleanup_pending": False})
        finish(self.db.transaction())
        return True

    # Fetch a bounded page of visible samples ordered by timestamp and document ID.
    def query(self, state, metric, start, end, limit, after=None):
        if not state.get("enabled"):
            return []
        query = (self.samples(state["generation"])
                 .where(filter=FieldFilter("deleted", "==", False))
                 .where(filter=FieldFilter("metric", "==", metric))
                 .where(filter=FieldFilter("start", ">=", start))
                 .where(filter=FieldFilter("start", "<", end))
                 .order_by("start").order_by("__name__"))
        if after:
            query = query.start_after({"start": after[0], "__name__": self.samples(state["generation"]).document(after[1])})
        return list(query.limit(limit).stream())

"""Versioned wire contract. No HealthKit data is included in validation errors."""
from datetime import datetime, timezone
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


class Sample(Model):
    uuid: UUID
    metric: Literal["heart_rate", "hrv_sdnn"]
    value: float = Field(gt=0)
    unit: Literal["bpm", "ms"]
    start: datetime
    end: datetime
    source_name: str = Field(max_length=256)
    source_identifier: str = Field(max_length=256)
    source_version: str | None = Field(default=None, max_length=128)
    device_name: str | None = Field(default=None, max_length=256)
    device_model: str | None = Field(default=None, max_length=256)

    # Require timezone information and normalize sample timestamps to UTC.
    @field_validator("start", "end")
    @classmethod
    def utc(cls, value):
        if value.tzinfo is None:
            raise ValueError("Timezone required")
        return value.astimezone(timezone.utc)

    # Ensure the unit matches the metric and timestamps are ordered.
    @model_validator(mode="after")
    def consistent(self):
        if self.unit != {"heart_rate": "bpm", "hrv_sdnn": "ms"}[self.metric]:
            raise ValueError("Metric/unit mismatch")
        if self.end < self.start:
            raise ValueError("Invalid timestamp order")
        return self


class Operation(Model):
    kind: Literal["upsert", "delete"]
    uuid: UUID
    sample: Sample | None = None

    # Require matching sample data for additions and no sample data for deletions.
    @model_validator(mode="after")
    def consistent(self):
        if self.kind == "upsert" and (self.sample is None or self.sample.uuid != self.uuid):
            raise ValueError("Sample and operation UUID must match")
        if self.kind == "delete" and self.sample is not None:
            raise ValueError("Deletion must not include sample data")
        return self


class SyncBatch(Model):
    schema_version: Literal[1]
    generation: UUID
    batch_id: UUID
    operations: list[Operation] = Field(min_length=1, max_length=100)

    # Reject multiple operations for the same sample UUID in one batch.
    @model_validator(mode="after")
    def unique(self):
        ids = [op.uuid for op in self.operations]
        if len(set(ids)) != len(ids):
            raise ValueError("One operation per UUID per batch")
        return self


class ImportRequest(Model):
    # Also the generation ID. Repeating this request never creates another generation.
    import_id: UUID


class DeleteRequest(Model):
    deletion_id: UUID
    generation: UUID

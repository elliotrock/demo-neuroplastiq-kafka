from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any


@dataclass(frozen=True)
class ActivePeriod:
    mode: str = "rolling"
    lookback: str | None = "24h"
    start: str | None = None
    end: str | None = None


@dataclass(frozen=True)
class Schedule:
    active_period: ActivePeriod = field(default_factory=ActivePeriod)
    frequency_period: str = "1h"


@dataclass(frozen=True)
class RuntimeSettings:
    source_mode: str = "db"
    worker_url_template: str = (
        "http://neuroplastiq-graphql-worker-{worker_id}.neuroplastiq.svc.cluster.local:8000"
    )
    seed_endpoint: str | None = None


@dataclass(frozen=True)
class Step:
    name: str
    action: str
    depends_on: list[str] = field(default_factory=list)
    config_name: str | None = None
    config_file: str | None = None
    workers: list[int] = field(default_factory=list)
    job_prefix: str | None = None
    method: str = "POST"
    endpoint: str | None = None
    payload: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class Plan:
    plan_name: str
    enabled: bool = True
    schedule: Schedule = field(default_factory=Schedule)
    runtime: RuntimeSettings = field(default_factory=RuntimeSettings)
    steps: list[Step] = field(default_factory=list)


@dataclass(frozen=True)
class ResolvedActiveWindow:
    start: datetime
    end: datetime


@dataclass(frozen=True)
class StepResult:
    step_name: str
    action: str
    status: str
    detail: str
    targets: list[str] = field(default_factory=list)
    payload: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class PlanRunResult:
    plan_name: str
    run_id: str
    dry_run: bool
    started_at: datetime
    active_window: ResolvedActiveWindow
    steps: list[StepResult]


def parse_duration(value: str) -> timedelta:
    if not value:
        raise ValueError("duration cannot be empty")
    suffix = value[-1]
    amount = int(value[:-1])
    if suffix == "m":
        return timedelta(minutes=amount)
    if suffix == "h":
        return timedelta(hours=amount)
    if suffix == "d":
        return timedelta(days=amount)
    raise ValueError(f"unsupported duration suffix: {value}")


def parse_iso8601(value: str) -> datetime:
    normalized = value.replace("Z", "+00:00")
    return datetime.fromisoformat(normalized)


def resolve_active_window(active_period: ActivePeriod, now: datetime | None = None) -> ResolvedActiveWindow:
    current = now or datetime.now(timezone.utc)
    if active_period.mode == "rolling":
        lookback = parse_duration(active_period.lookback or "24h")
        return ResolvedActiveWindow(start=current - lookback, end=current)
    if active_period.mode == "fixed":
        if not active_period.start or not active_period.end:
            raise ValueError("fixed active_period requires start and end")
        return ResolvedActiveWindow(
            start=parse_iso8601(active_period.start),
            end=parse_iso8601(active_period.end),
        )
    raise ValueError(f"unsupported active_period mode: {active_period.mode}")

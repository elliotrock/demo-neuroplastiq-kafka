from __future__ import annotations

from pathlib import Path
from typing import Any

from .models import ActivePeriod, Plan, RuntimeSettings, Schedule, Step

try:
    import yaml
except ModuleNotFoundError:  # pragma: no cover - compile-safe fallback
    yaml = None


class PlanLoader:
    def __init__(self, plans_root: Path | None = None) -> None:
        self.plans_root = plans_root or Path(__file__).resolve().parent / "plans"

    def list_plan_names(self) -> list[str]:
        if not self.plans_root.exists():
            return []
        return sorted(path.stem for path in self.plans_root.glob("*.yaml"))

    def load(self, plan_name: str) -> Plan:
        if yaml is None:
            raise RuntimeError("PyYAML is required to load control-plane plans")
        plan_path = self.plans_root / f"{plan_name}.yaml"
        if not plan_path.exists():
            raise FileNotFoundError(f"plan not found: {plan_path}")
        raw = yaml.safe_load(plan_path.read_text()) or {}
        return self._build_plan(raw)

    def _build_plan(self, raw: dict[str, Any]) -> Plan:
        schedule_raw = raw.get("schedule", {}) or {}
        active_period_raw = schedule_raw.get("active_period", {}) or {}
        runtime_raw = raw.get("runtime", {}) or {}
        steps_raw = raw.get("steps", []) or []

        schedule = Schedule(
            active_period=ActivePeriod(
                mode=active_period_raw.get("mode", "rolling"),
                lookback=active_period_raw.get("lookback", "24h"),
                start=active_period_raw.get("start"),
                end=active_period_raw.get("end"),
            ),
            frequency_period=schedule_raw.get("frequency_period", "1h"),
        )
        runtime = RuntimeSettings(
            source_mode=runtime_raw.get("source_mode", "db"),
            worker_url_template=runtime_raw.get(
                "worker_url_template",
                RuntimeSettings().worker_url_template,
            ),
            seed_endpoint=runtime_raw.get("seed_endpoint"),
        )
        steps = [
            Step(
                name=step["name"],
                action=step["action"],
                depends_on=list(step.get("depends_on", []) or []),
                config_name=step.get("config_name"),
                config_file=step.get("config_file"),
                workers=list(step.get("workers", []) or []),
                job_prefix=step.get("job_prefix"),
                method=step.get("method", "POST"),
                endpoint=step.get("endpoint"),
                payload=dict(step.get("payload", {}) or {}),
            )
            for step in steps_raw
        ]
        return Plan(
            plan_name=raw["plan_name"],
            enabled=bool(raw.get("enabled", True)),
            schedule=schedule,
            runtime=runtime,
            steps=steps,
        )

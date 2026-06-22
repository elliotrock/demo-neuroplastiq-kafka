from __future__ import annotations

import json
import uuid
from abc import ABC, abstractmethod
from collections import defaultdict, deque
from datetime import datetime, timezone
from typing import Any
from urllib import error, parse, request

from .loader import PlanLoader
from .models import Plan, PlanRunResult, ResolvedActiveWindow, Step, StepResult, resolve_active_window


class SeedRuntimeConfigAdapter(ABC):
    @abstractmethod
    def seed(self, step: Step, plan: Plan, active_window: ResolvedActiveWindow, dry_run: bool) -> StepResult:
        raise NotImplementedError


class UnsupportedSeedRuntimeConfigAdapter(SeedRuntimeConfigAdapter):
    def seed(self, step: Step, plan: Plan, active_window: ResolvedActiveWindow, dry_run: bool) -> StepResult:
        if dry_run:
            return StepResult(
                step_name=step.name,
                action=step.action,
                status="planned",
                detail="seed_runtime_config planned only; adapter not required in dry-run mode",
                payload=_seed_payload(step, plan, active_window),
            )
        return StepResult(
            step_name=step.name,
            action=step.action,
            status="blocked",
            detail="seed_runtime_config adapter is not configured in this repo",
            payload=_seed_payload(step, plan, active_window),
        )


class ControlPlaneExecutor:
    def __init__(
        self,
        loader: PlanLoader | None = None,
        seed_adapter: SeedRuntimeConfigAdapter | None = None,
        timeout_seconds: int = 30,
    ) -> None:
        self.loader = loader or PlanLoader()
        self.seed_adapter = seed_adapter or UnsupportedSeedRuntimeConfigAdapter()
        self.timeout_seconds = timeout_seconds

    def list_plans(self) -> list[str]:
        return self.loader.list_plan_names()

    def get_plan(self, plan_name: str) -> Plan:
        return self.loader.load(plan_name)

    def run_plan(self, plan_name: str, dry_run: bool = True) -> PlanRunResult:
        plan = self.get_plan(plan_name)
        active_window = resolve_active_window(plan.schedule.active_period)
        ordered_steps = self._order_steps(plan)
        results: list[StepResult] = []

        for step in ordered_steps:
            result = self._run_step(step, plan, active_window, dry_run=dry_run)
            results.append(result)
            if result.status in {"failed", "blocked"} and not dry_run:
                break

        return PlanRunResult(
            plan_name=plan.plan_name,
            run_id=str(uuid.uuid4()),
            dry_run=dry_run,
            started_at=datetime.now(timezone.utc),
            active_window=active_window,
            steps=results,
        )

    def refresh_plan(self, plan_name: str) -> dict[str, Any]:
        plan = self.get_plan(plan_name)
        ordered_steps = self._order_steps(plan)
        return {
            "plan_name": plan.plan_name,
            "enabled": plan.enabled,
            "frequency_period": plan.schedule.frequency_period,
            "step_order": [step.name for step in ordered_steps],
        }

    def _order_steps(self, plan: Plan) -> list[Step]:
        by_name = {step.name: step for step in plan.steps}
        indegree: dict[str, int] = {step.name: 0 for step in plan.steps}
        edges: dict[str, list[str]] = defaultdict(list)

        previous_name: str | None = None
        for step in plan.steps:
            deps = list(step.depends_on)
            if not deps and previous_name:
                deps = [previous_name]
            for dependency in deps:
                if dependency not in by_name:
                    raise ValueError(f"step '{step.name}' depends on unknown step '{dependency}'")
                edges[dependency].append(step.name)
                indegree[step.name] += 1
            previous_name = step.name

        queue = deque([name for name, degree in indegree.items() if degree == 0])
        ordered: list[Step] = []
        while queue:
            name = queue.popleft()
            ordered.append(by_name[name])
            for child in edges[name]:
                indegree[child] -= 1
                if indegree[child] == 0:
                    queue.append(child)
        if len(ordered) != len(plan.steps):
            raise ValueError(f"plan '{plan.plan_name}' contains cyclic dependencies")
        return ordered

    def _run_step(
        self,
        step: Step,
        plan: Plan,
        active_window: ResolvedActiveWindow,
        dry_run: bool,
    ) -> StepResult:
        if step.action == "seed_runtime_config":
            return self.seed_adapter.seed(step, plan, active_window, dry_run)
        if step.action == "refresh_workers":
            return self._run_refresh_workers(step, plan, dry_run)
        if step.action == "trigger_workers":
            return self._run_trigger_workers(step, plan, dry_run)
        return StepResult(
            step_name=step.name,
            action=step.action,
            status="blocked",
            detail=f"unsupported action: {step.action}",
        )

    def _run_refresh_workers(self, step: Step, plan: Plan, dry_run: bool) -> StepResult:
        targets = [
            self._build_worker_refresh_url(plan, worker_id, step.config_name or "")
            for worker_id in step.workers
        ]
        if dry_run:
            return StepResult(
                step_name=step.name,
                action=step.action,
                status="planned",
                detail="refresh_workers planned",
                targets=targets,
            )
        return self._perform_http_calls(step, targets)

    def _run_trigger_workers(self, step: Step, plan: Plan, dry_run: bool) -> StepResult:
        targets = [self._build_worker_trigger_url(plan, worker_id) for worker_id in step.workers]
        if dry_run:
            return StepResult(
                step_name=step.name,
                action=step.action,
                status="planned",
                detail="trigger_workers planned",
                targets=targets,
                payload={"job_prefix": step.job_prefix or step.config_name},
            )
        return self._perform_http_calls(step, targets)

    def _perform_http_calls(self, step: Step, targets: list[str]) -> StepResult:
        failures: list[str] = []
        for target in targets:
            try:
                req = request.Request(target, method=step.method.upper())
                if step.payload:
                    req.add_header("Content-Type", "application/json")
                    req.data = json.dumps(step.payload).encode("utf-8")
                with request.urlopen(req, timeout=self.timeout_seconds) as response:
                    if response.status >= 400:
                        failures.append(f"{target} -> HTTP {response.status}")
            except error.URLError as exc:
                failures.append(f"{target} -> {exc}")
        status = "ok" if not failures else "failed"
        detail = "all worker calls succeeded" if not failures else "; ".join(failures)
        return StepResult(
            step_name=step.name,
            action=step.action,
            status=status,
            detail=detail,
            targets=targets,
            payload=step.payload,
        )

    @staticmethod
    def _build_worker_refresh_url(plan: Plan, worker_id: int, config_name: str) -> str:
        base = plan.runtime.worker_url_template.format(worker_id=worker_id).rstrip("/")
        query = parse.urlencode(
            {"source_mode": plan.runtime.source_mode, "config_name": config_name}
        )
        return f"{base}/admin/config/refresh/graphql-source?{query}"

    @staticmethod
    def _build_worker_trigger_url(plan: Plan, worker_id: int) -> str:
        base = plan.runtime.worker_url_template.format(worker_id=worker_id).rstrip("/")
        return f"{base}/connector"


def _seed_payload(step: Step, plan: Plan, active_window: ResolvedActiveWindow) -> dict[str, Any]:
    return {
        "config_name": step.config_name,
        "config_file": step.config_file,
        "source_mode": plan.runtime.source_mode,
        "active_window": {
            "start": active_window.start.isoformat(),
            "end": active_window.end.isoformat(),
        },
    }

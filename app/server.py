from __future__ import annotations

from dataclasses import asdict

from fastapi import FastAPI, HTTPException, Query

from core.control_plane import ControlPlaneExecutor

app = FastAPI(title="Bookibet Control Plane")
executor = ControlPlaneExecutor()


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/admin/control-plane/plans")
def list_plans() -> dict[str, list[str]]:
    return {"plans": executor.list_plans()}


@app.get("/admin/control-plane/plans/{plan_name}")
def get_plan(plan_name: str) -> dict[str, object]:
    try:
        plan = executor.get_plan(plan_name)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return asdict(plan)


@app.post("/admin/control-plane/plans/{plan_name}/refresh")
def refresh_plan(plan_name: str) -> dict[str, object]:
    try:
        return executor.refresh_plan(plan_name)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/admin/control-plane/plans/{plan_name}/run")
def run_plan(plan_name: str, dry_run: bool = Query(True)) -> dict[str, object]:
    try:
        result = executor.run_plan(plan_name=plan_name, dry_run=dry_run)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return asdict(result)

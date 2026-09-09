"""Budget routes — stubs only.

TODO: implement CRUD against budgets / budget_entries. Explicitly NOT
implementing budget total/balance calculation logic here — see the TODO
in budget_entries usage once that's built.
"""

from fastapi import APIRouter, status

router = APIRouter(prefix="/budgets", tags=["budgets"])


@router.get("/club/{club_id}", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def list_club_budgets(club_id: str):
    return {"detail": "not implemented"}


@router.post("", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def create_budget():
    return {"detail": "not implemented"}


@router.post("/{budget_id}/entries", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def add_budget_entry(budget_id: str):
    return {"detail": "not implemented"}

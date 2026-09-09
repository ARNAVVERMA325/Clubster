"""Event routes — stubs only.

TODO: implement CRUD against the events table, and wire slot suggestion /
clash detection to backend.core.scheduler once an event is created.
"""

from fastapi import APIRouter, status

router = APIRouter(prefix="/events", tags=["events"])


@router.get("", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def list_events():
    return {"detail": "not implemented"}


@router.post("", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def create_event():
    return {"detail": "not implemented"}


@router.get("/{event_id}", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def get_event(event_id: str):
    return {"detail": "not implemented"}

"""Club routes — stubs only. TODO: implement CRUD against the clubs /
club_memberships tables."""

from fastapi import APIRouter, status

router = APIRouter(prefix="/clubs", tags=["clubs"])


@router.get("", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def list_clubs():
    return {"detail": "not implemented"}


@router.post("", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def create_club():
    return {"detail": "not implemented"}


@router.get("/{club_id}", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def get_club(club_id: str):
    return {"detail": "not implemented"}

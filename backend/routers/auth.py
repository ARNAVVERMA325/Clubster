"""Auth routes — stubs only. TODO: implement against Supabase Auth."""

from fastapi import APIRouter, status

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/signup", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def signup():
    return {"detail": "not implemented"}


@router.post("/login", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def login():
    return {"detail": "not implemented"}


@router.post("/logout", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def logout():
    return {"detail": "not implemented"}

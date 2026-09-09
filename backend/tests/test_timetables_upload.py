import anthropic
from fastapi.testclient import TestClient

import core.config as core_config
import routers.timetables as timetables
from main import app
from routers.timetables import ParsedSlot, ParsedTimetable
from tests.fakes import FakeSupabaseClient

client = TestClient(app)


# ============================================================
# Fakes
# ============================================================


class FakeAnthropicResponse:
    def __init__(self, parsed_output, stop_reason="end_turn"):
        self.parsed_output = parsed_output
        self.stop_reason = stop_reason


class FakeMessages:
    def __init__(self, behavior):
        self._behavior = behavior

    def parse(self, **kwargs):
        if callable(self._behavior):
            return self._behavior(**kwargs)
        return self._behavior


class FakeAnthropicClient:
    def __init__(self, behavior):
        self.messages = FakeMessages(behavior)


# ============================================================
# Tests
# ============================================================


def test_upload_text_paste_success(monkeypatch):
    parsed = ParsedTimetable(
        course="Physics Hons",
        year=1,
        section="B",
        slots=[
            ParsedSlot(day_of_week=1, start_time="09:00", end_time="10:00", subject="Mechanics"),
        ],
    )
    fake_anthropic = FakeAnthropicClient(FakeAnthropicResponse(parsed_output=parsed))
    fake_supabase = FakeSupabaseClient(existing_rows={})

    monkeypatch.setattr(timetables, "get_anthropic_client", lambda: fake_anthropic)
    monkeypatch.setattr(core_config, "get_supabase_client", lambda: fake_supabase)

    response = client.post(
        "/api/timetables/upload",
        data={"college_id": "college-1", "text": "Mon 9-10 Mechanics"},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "success"
    assert body["sections_created"] == 1
    assert body["slots_inserted"] == 1
    assert body["course"] == "Physics Hons"
    assert body["year"] == 1
    assert body["section"] == "B"
    assert len(body["parsed_slots"]) == 1
    assert body["source_json_id"]

    assert len(fake_supabase.inserted["sections"]) == 1
    assert fake_supabase.inserted["sections"][0]["course"] == "Physics Hons"
    assert fake_supabase.inserted["sections"][0]["section_name"] == "B"

    inserted_slot = fake_supabase.inserted["timetable_slots"][0]
    # Claude's day_of_week convention (0=Sun..6=Sat) must be converted to
    # the stored convention (0=Mon..6=Sun) — Monday (1) becomes 0.
    assert inserted_slot["day_of_week"] == 0
    assert inserted_slot["start_time"] == "09:00"
    assert inserted_slot["source_json_id"] == body["source_json_id"]


def test_upload_reuses_existing_section(monkeypatch):
    parsed = ParsedTimetable(course="Physics Hons", year=1, section="B", slots=[])
    fake_anthropic = FakeAnthropicClient(FakeAnthropicResponse(parsed_output=parsed))
    fake_supabase = FakeSupabaseClient(
        existing_rows={
            "sections": [
                {
                    "id": "existing-section-id",
                    "college_id": "college-1",
                    "course": "Physics Hons",
                    "section_name": "B",
                    "year": 1,
                }
            ]
        }
    )

    monkeypatch.setattr(timetables, "get_anthropic_client", lambda: fake_anthropic)
    monkeypatch.setattr(core_config, "get_supabase_client", lambda: fake_supabase)

    response = client.post(
        "/api/timetables/upload",
        data={"college_id": "college-1", "text": "Mon 9-10 Mechanics"},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["sections_created"] == 0
    assert body["slots_inserted"] == 0
    assert fake_supabase.inserted["sections"] == []


def test_upload_requires_file_or_text():
    response = client.post("/api/timetables/upload", data={"college_id": "college-1"})

    assert response.status_code == 400


def test_upload_returns_400_when_model_returns_no_structured_output(monkeypatch):
    fake_anthropic = FakeAnthropicClient(FakeAnthropicResponse(parsed_output=None))
    monkeypatch.setattr(timetables, "get_anthropic_client", lambda: fake_anthropic)

    response = client.post(
        "/api/timetables/upload",
        data={"college_id": "college-1", "text": "unreadable scrawl"},
    )

    assert response.status_code == 400
    assert "invalid timetable JSON" in response.json()["detail"]["error"]


def test_upload_returns_400_on_refusal(monkeypatch):
    fake_anthropic = FakeAnthropicClient(FakeAnthropicResponse(parsed_output=None, stop_reason="refusal"))
    monkeypatch.setattr(timetables, "get_anthropic_client", lambda: fake_anthropic)

    response = client.post(
        "/api/timetables/upload",
        data={"college_id": "college-1", "text": "some timetable text"},
    )

    assert response.status_code == 400


def test_upload_returns_502_on_anthropic_api_error(monkeypatch):
    def raise_error(**_kwargs):
        raise anthropic.APIConnectionError(request=None)

    fake_anthropic = FakeAnthropicClient(raise_error)
    monkeypatch.setattr(timetables, "get_anthropic_client", lambda: fake_anthropic)

    response = client.post(
        "/api/timetables/upload",
        data={"college_id": "college-1", "text": "some timetable text"},
    )

    assert response.status_code == 502

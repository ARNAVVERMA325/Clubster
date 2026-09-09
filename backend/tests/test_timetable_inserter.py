import core.config as core_config
from core.timetable_inserter import insert_timetable_into_db
from tests.fakes import FakeSupabaseClient

PARSED_JSON = {
    "course": "Physics Hons",
    "year": 1,
    "section": "B",
    "slots": [
        {"day_of_week": 1, "start_time": "09:00", "end_time": "10:00", "subject": "Mechanics"},
        {"day_of_week": 0, "start_time": "11:00", "end_time": "12:00", "subject": None},
    ],
}


def test_creates_new_section_and_inserts_slots(monkeypatch):
    fake_supabase = FakeSupabaseClient(existing_rows={})
    monkeypatch.setattr(core_config, "get_supabase_client", lambda: fake_supabase)

    result = insert_timetable_into_db(
        PARSED_JSON, college_id="college-1", uploaded_by_user_id="user-1"
    )

    assert result["sections_created"] == 1
    assert result["slots_inserted"] == 2
    assert result["section_id"] == fake_supabase.inserted["sections"][0]["id"]
    assert result["source_json_id"]

    section_row = fake_supabase.inserted["sections"][0]
    assert section_row["college_id"] == "college-1"
    assert section_row["course"] == "Physics Hons"
    assert section_row["section_name"] == "B"
    assert section_row["year"] == 1

    for slot_row in fake_supabase.inserted["timetable_slots"]:
        assert slot_row["uploaded_by"] == "user-1"
        assert slot_row["source_json_id"] == result["source_json_id"]


def test_day_of_week_is_converted_from_sunday_zero_to_monday_zero(monkeypatch):
    fake_supabase = FakeSupabaseClient(existing_rows={})
    monkeypatch.setattr(core_config, "get_supabase_client", lambda: fake_supabase)

    insert_timetable_into_db(PARSED_JSON, college_id="college-1", uploaded_by_user_id="user-1")

    by_start_time = {row["start_time"]: row["day_of_week"] for row in fake_supabase.inserted["timetable_slots"]}
    # Monday (1 in the parser's Sunday=0 convention) -> 0 (Python's Monday=0)
    assert by_start_time["09:00"] == 0
    # Sunday (0 in the parser's convention) -> 6 (Python's Sunday=6)
    assert by_start_time["11:00"] == 6


def test_reuses_existing_section_by_college_course_year_section(monkeypatch):
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
    monkeypatch.setattr(core_config, "get_supabase_client", lambda: fake_supabase)

    result = insert_timetable_into_db(
        PARSED_JSON, college_id="college-1", uploaded_by_user_id="user-1"
    )

    assert result["sections_created"] == 0
    assert result["section_id"] == "existing-section-id"
    assert fake_supabase.inserted["sections"] == []


def test_no_slots_inserts_nothing(monkeypatch):
    fake_supabase = FakeSupabaseClient(existing_rows={})
    monkeypatch.setattr(core_config, "get_supabase_client", lambda: fake_supabase)

    empty_json = {**PARSED_JSON, "slots": []}
    result = insert_timetable_into_db(empty_json, college_id="college-1", uploaded_by_user_id="user-1")

    assert result["slots_inserted"] == 0
    assert fake_supabase.inserted["timetable_slots"] == []

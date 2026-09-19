# Clubster

Clubster is a club/society event scheduling and management platform for
colleges — timetable-aware event slot suggestions, venue/audience clash
detection, attendance, and budget tracking for student clubs.

This repository is currently **scaffolding**: project structure,
connections between the pieces, and stubs. Business logic beyond the
scheduling algorithm (see below) is intentionally left as `TODO`s.

## Tech stack

- **Frontend:** Flutter (targeting web + Android to start)
- **Backend:** FastAPI (Python)
- **Database / Auth / Storage:** Supabase (Postgres)
- **Hosting:** Render (backend, free tier), Supabase (free tier)

## Repository structure

```
/frontend   Flutter app (lib/, pubspec.yaml — Supabase SDK wired, nav shell + placeholder screens)
/backend    FastAPI app (main.py, /routers, /models, /schemas, /core)
/database   schema.sql — Supabase/Postgres migration
```

## Getting started

### Backend

```bash
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp ../.env.example .env   # fill in your Supabase values
uvicorn main:app --reload --port 8000
```

`ANTHROPIC_API_KEY` is only needed for `POST /api/timetables/upload`
(AI-powered parsing). Everything else, including `POST
/api/timetables/confirm` (see below), works without it.

All routes are mounted under `/api` (e.g. `POST /api/timetables/upload`),
except `/health`.

Run tests:

```bash
cd backend
pytest
```

### Database

Apply `database/schema.sql` to your Supabase project via the SQL editor,
or:

```bash
psql "$DATABASE_URL" -f database/schema.sql
```

This includes a grant letting the anon/authenticated roles read
`colleges` — without it, the app's college picker fails with
`permission denied for table colleges` even with a correct URL/key,
since creating a table doesn't by itself expose it to Supabase's public
API. (It's a blanket grant appropriate for scaffolding only — replace it
with proper RLS policies before production.)

Then, via the Table Editor, add at least one row to `colleges` — nothing
in the app creates colleges yet, so skipping this leaves the timetable
screens' College dropdown empty and unable to proceed.

### Frontend

The Flutter SDK isn't available in the environment this scaffold was
generated in, so `lib/`, `pubspec.yaml`, and a minimal `web/index.html`
were hand-authored rather than produced by `flutter create`. Once you
have the Flutter SDK installed:

```bash
cd frontend
flutter create .   # safely fills in the android/ios/web platform runners
flutter pub get
flutter run \
  --dart-define=SUPABASE_URL=... \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=... \
  --dart-define=API_BASE_URL=http://localhost:8000/api
```

`API_BASE_URL` points the app at the FastAPI backend above (defaults to
`http://localhost:8000/api` if omitted).

Run tests:

```bash
cd frontend
flutter test
```

## What's implemented vs. stubbed

- `backend/core/scheduler.py` — the event slot suggestion + clash
  detection algorithm is fully implemented, with unit tests in
  `backend/tests/test_scheduler.py`.
- `POST /api/timetables/upload` (`dry_run=true`) parses an uploaded
  timetable (image, PDF, or pasted text) via the Claude API and returns
  a preview without writing to the database; `POST
  /api/timetables/confirm` then inserts the previously-parsed JSON via
  `backend/core/timetable_inserter.py` — no second Claude call. (Calling
  `/upload` with `dry_run=false`, the default, parses and inserts in one
  step.) Tests in `backend/tests/test_timetables_upload.py` and
  `backend/tests/test_timetable_inserter.py` (mocked — no real Claude
  API calls or database).
- `frontend/lib/screens/admin/timetable_upload_screen.dart` — the admin
  UI for the AI-parsing flow above, designed as three numbered steps
  (details -> source -> review), with a grouped-by-day preview, inline
  validation, and a lightweight "Edit" affordance to correct details
  without leaving the screen. **Needs an Anthropic API key.**
- `frontend/lib/screens/admin/timetable_manual_entry_screen.dart` — a
  free, no-AI alternative: type in day/time/subject rows by hand and post
  straight to `/api/timetables/confirm` (skipping the Claude call
  entirely).
- `frontend/lib/screens/admin/timetable_json_import_screen.dart` —
  another free, no-AI-key alternative: shows the exact prompt to paste
  into an AI chatbot the admin already has access to (ChatGPT, Gemini,
  Claude.ai, ...) alongside their timetable photo, then imports the JSON
  it replies with. The AI call happens entirely outside this app (free,
  in that tool's own chat), so this screen never calls any AI itself —
  it just validates the JSON client-side (same rules the backend
  enforces: valid times, `end_time` after `start_time`, etc.) and posts
  to `/api/timetables/confirm` like the manual-entry screen does.
  All three timetable screens share day-grouping, the college picker,
  and error handling via
  `frontend/lib/screens/admin/timetable_common.dart`, and are wired in
  from the Admin tab (`admin_screen.dart`). `flutter analyze` is clean,
  `flutter build web` compiles, and the `frontend/test/*_test.dart` files
  (22 tests total, including a pure-Dart suite for the JSON validator)
  cover rendering, client-side validation, and navigation for all three
  screens (mocking nothing but the network — Supabase is intentionally
  left uninitialized in tests, which exercises the same error-handling
  path a real load failure would hit). Still not run interactively in a
  browser/device, so real device rendering, the native file-picker
  dialog, and the actual Claude/Supabase round-trip are unverified.
- Everything else (auth, clubs, events, the rest of timetables,
  attendance, budgets routers; budget total/balance calculations; other
  frontend screens) is stubbed — routes return "not implemented", and
  `TODO` comments mark where real logic goes.

## License

Clubster is licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0).

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
cp ../.env.example .env   # fill in your Supabase + Anthropic values
uvicorn main:app --reload --port 8000
```

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
  UI for the flow above: fill in details, upload/paste a timetable,
  review the parsed table, then confirm. Wired in from the Admin tab.
  **Not compiled/run** — this scaffold was built in an environment
  without the Flutter SDK, so it's only had a careful manual read-through,
  not `flutter analyze`/`flutter run`.
- Everything else (auth, clubs, events, the rest of timetables,
  attendance, budgets routers; budget total/balance calculations; other
  frontend screens) is stubbed — routes return "not implemented", and
  `TODO` comments mark where real logic goes.

## License

Clubster is licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0).

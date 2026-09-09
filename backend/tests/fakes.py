"""Shared test doubles for Supabase-backed code."""


class FakeResult:
    def __init__(self, data):
        self.data = data


class FakeQuery:
    def __init__(self, table_name, existing_rows, inserted_store):
        self.table_name = table_name
        self.existing_rows = existing_rows
        self.inserted_store = inserted_store
        self._filters = {}
        self._insert_payload = None

    def select(self, *_args, **_kwargs):
        return self

    def eq(self, field, value):
        self._filters[field] = value
        return self

    def limit(self, _n):
        return self

    def insert(self, payload):
        self._insert_payload = payload
        return self

    def execute(self):
        if self._insert_payload is not None:
            rows = self._insert_payload if isinstance(self._insert_payload, list) else [self._insert_payload]
            created = []
            for row in rows:
                row = dict(row)
                row.setdefault("id", f"generated-{len(self.inserted_store[self.table_name]) + 1}")
                self.inserted_store[self.table_name].append(row)
                created.append(row)
            return FakeResult(created)

        matches = [
            row
            for row in self.existing_rows.get(self.table_name, [])
            if all(row.get(k) == v for k, v in self._filters.items())
        ]
        return FakeResult(matches)


class FakeSupabaseClient:
    def __init__(self, existing_rows=None):
        self.existing_rows = existing_rows or {}
        self.inserted = {"sections": [], "timetable_slots": []}

    def table(self, name):
        return FakeQuery(name, self.existing_rows, self.inserted)

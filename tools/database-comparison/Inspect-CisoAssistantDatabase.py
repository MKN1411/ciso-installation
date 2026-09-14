#!/usr/bin/env python3
"""Read-only SQLite inventory for CISO Assistant databases.

The script intentionally uses SQLite URI mode=ro and PRAGMA query_only=ON.
It emits one JSON document to stdout and never changes the database.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from typing import Any

M365_KEYWORDS = (
    "m365",
    "microsoft 365",
    "office 365",
    "entra",
    "intune",
    "defender",
    "exchange",
    "sharepoint",
    "onedrive",
    "teams",
    "purview",
    "azure",
)

CATEGORY_PATTERNS = {
    "asset": ("asset",),
    "evidence": ("evidence",),
    "risk": ("risk",),
    "assessment": ("assessment", "audit"),
    "perimeter": ("perimeter",),
    "folder": ("folder",),
    "control": ("control",),
    "requirement": ("requirement",),
    "incident": ("incident",),
    "supplier": ("supplier", "thirdparty", "third_party"),
    "user": ("user",),
}

INTERNAL_PREFIXES = (
    "sqlite_",
    "django_",
    "auth_",
    "authtoken_",
    "sessions_",
)

LIKELY_DATE_COLUMNS = (
    "updated_at",
    "modified_at",
    "last_modified",
    "created_at",
    "date_updated",
    "date_created",
    "applied",
)


def quote_identifier(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def safe_value(value: Any) -> Any:
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, bytes):
        return f"<bytes:{len(value)}>"
    text = str(value)
    if len(text) > 400:
        return text[:397] + "..."
    return text


def is_text_column(declared_type: str) -> bool:
    normalized = (declared_type or "").upper()
    if not normalized:
        return True
    return any(token in normalized for token in ("CHAR", "CLOB", "TEXT", "JSON"))


def categories_for_table(table_name: str) -> list[str]:
    lower = table_name.lower()
    result: list[str] = []
    for category, patterns in CATEGORY_PATTERNS.items():
        if any(pattern in lower for pattern in patterns):
            result.append(category)
    return result


def get_columns(connection: sqlite3.Connection, table_name: str) -> list[dict[str, Any]]:
    cursor = connection.execute(f"PRAGMA table_info({quote_identifier(table_name)})")
    return [
        {
            "cid": row[0],
            "name": row[1],
            "type": row[2] or "",
            "notnull": bool(row[3]),
            "default": safe_value(row[4]),
            "pk": bool(row[5]),
        }
        for row in cursor.fetchall()
    ]


def get_latest_timestamp(
    connection: sqlite3.Connection, table_name: str, columns: list[dict[str, Any]]
) -> dict[str, Any] | None:
    column_names = {column["name"] for column in columns}
    candidates = [name for name in LIKELY_DATE_COLUMNS if name in column_names]
    for column_name in candidates:
        try:
            row = connection.execute(
                f"SELECT MAX({quote_identifier(column_name)}) FROM {quote_identifier(table_name)}"
            ).fetchone()
            if row and row[0] is not None:
                return {"column": column_name, "value": safe_value(row[0])}
        except sqlite3.Error:
            continue
    return None


def get_keyword_matches(
    connection: sqlite3.Connection,
    table_name: str,
    columns: list[dict[str, Any]],
    sample_limit: int,
) -> tuple[int, list[dict[str, Any]]]:
    text_columns = [
        column["name"]
        for column in columns
        if is_text_column(column.get("type", ""))
    ]
    if not text_columns:
        return 0, []

    clauses: list[str] = []
    params: list[str] = []
    for column_name in text_columns:
        column_sql = f"LOWER(CAST({quote_identifier(column_name)} AS TEXT))"
        for keyword in M365_KEYWORDS:
            clauses.append(f"{column_sql} LIKE ?")
            params.append(f"%{keyword.lower()}%")

    where_sql = " OR ".join(clauses)
    try:
        count = connection.execute(
            f"SELECT COUNT(*) FROM {quote_identifier(table_name)} WHERE {where_sql}", params
        ).fetchone()[0]
    except sqlite3.Error:
        return 0, []

    samples: list[dict[str, Any]] = []
    if count and sample_limit > 0:
        try:
            cursor = connection.execute(
                f"SELECT * FROM {quote_identifier(table_name)} WHERE {where_sql} LIMIT ?",
                [*params, sample_limit],
            )
            column_names = [description[0] for description in cursor.description or []]
            for row in cursor.fetchall():
                samples.append(
                    {
                        name: safe_value(value)
                        for name, value in zip(column_names, row, strict=False)
                    }
                )
        except sqlite3.Error:
            pass
    return int(count), samples


def inspect_database(database_path: str, sample_limit: int) -> dict[str, Any]:
    if not os.path.isfile(database_path):
        raise FileNotFoundError(database_path)

    absolute_path = os.path.abspath(database_path)
    uri = f"file:{absolute_path}?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=5)
    connection.execute("PRAGMA query_only=ON")

    try:
        pragma_user_version = connection.execute("PRAGMA user_version").fetchone()[0]
        pragma_journal_mode = connection.execute("PRAGMA journal_mode").fetchone()[0]
        table_rows = connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        ).fetchall()

        tables: list[dict[str, Any]] = []
        category_counts = {category: 0 for category in CATEGORY_PATTERNS}
        category_m365_matches = {category: 0 for category in CATEGORY_PATTERNS}
        total_rows = 0
        business_rows = 0
        key_business_rows = 0
        total_m365_matches = 0

        for (table_name,) in table_rows:
            quoted_table = quote_identifier(table_name)
            try:
                row_count = int(connection.execute(f"SELECT COUNT(*) FROM {quoted_table}").fetchone()[0])
            except sqlite3.Error as exc:
                tables.append(
                    {
                        "name": table_name,
                        "error": str(exc),
                        "row_count": None,
                        "categories": categories_for_table(table_name),
                    }
                )
                continue

            columns = get_columns(connection, table_name)
            categories = categories_for_table(table_name)
            is_internal = table_name.startswith(INTERNAL_PREFIXES)
            latest = get_latest_timestamp(connection, table_name, columns)

            m365_count = 0
            samples: list[dict[str, Any]] = []
            if row_count > 0 and not table_name.startswith("sqlite_"):
                m365_count, samples = get_keyword_matches(
                    connection, table_name, columns, sample_limit if categories else 0
                )

            total_rows += row_count
            total_m365_matches += m365_count
            if not is_internal:
                business_rows += row_count
            if categories:
                key_business_rows += row_count
                for category in categories:
                    category_counts[category] += row_count
                    category_m365_matches[category] += m365_count

            table_result: dict[str, Any] = {
                "name": table_name,
                "row_count": row_count,
                "is_internal": is_internal,
                "categories": categories,
                "column_count": len(columns),
                "latest_timestamp": latest,
                "m365_keyword_matches": m365_count,
            }
            if samples:
                table_result["m365_samples"] = samples
            tables.append(table_result)

        migrations: dict[str, Any] = {"count": 0, "latest": []}
        if any(item["name"] == "django_migrations" for item in tables):
            try:
                migrations["count"] = int(
                    connection.execute("SELECT COUNT(*) FROM django_migrations").fetchone()[0]
                )
                cursor = connection.execute(
                    "SELECT app, name, applied FROM django_migrations ORDER BY applied DESC LIMIT 10"
                )
                migrations["latest"] = [
                    {"app": row[0], "name": row[1], "applied": safe_value(row[2])}
                    for row in cursor.fetchall()
                ]
            except sqlite3.Error as exc:
                migrations["error"] = str(exc)

        return {
            "database_path": absolute_path,
            "sqlite": {
                "version": sqlite3.sqlite_version,
                "user_version": pragma_user_version,
                "journal_mode": pragma_journal_mode,
            },
            "summary": {
                "table_count": len(tables),
                "total_rows": total_rows,
                "business_rows": business_rows,
                "key_business_rows": key_business_rows,
                "m365_keyword_matches": total_m365_matches,
                "category_rows": category_counts,
                "category_m365_matches": category_m365_matches,
            },
            "migrations": migrations,
            "tables": tables,
        }
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Read-only CISO Assistant SQLite inventory")
    parser.add_argument("database", help="Path to ciso-assistant.sqlite3")
    parser.add_argument("--sample-limit", type=int, default=3)
    args = parser.parse_args()

    try:
        result = inspect_database(args.database, max(0, args.sample_limit))
    except Exception as exc:  # noqa: BLE001 - diagnostic tool must serialize failures
        json.dump(
            {
                "status": "error",
                "error_type": type(exc).__name__,
                "error": str(exc),
            },
            sys.stdout,
            ensure_ascii=False,
        )
        sys.stdout.write("\n")
        return 1

    json.dump({"status": "ok", **result}, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

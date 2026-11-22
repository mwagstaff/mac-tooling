"""Read the current UTC calendar month's organization API costs for the Dock."""
from datetime import datetime, timezone
from decimal import Decimal
from http.client import HTTPSConnection
import json
import os
from pathlib import Path
import shlex
import sys
from urllib.parse import urlencode


def billing_key():
    name = "OPENAI_API_KEY_ORGANISATION_ADMIN_KEY"
    if os.environ.get(name):
        return os.environ[name]
    cache_dir = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    cache = Path(os.environ.get("BW_ENV_CACHE_FILE") or cache_dir / "server-tooling/bitwarden-env")
    prefix = f"export {name}="
    with cache.open() as entries:
        for entry in entries:
            if entry.startswith(prefix):
                key, = shlex.split(entry[len(prefix):])
                if key:
                    return key
    raise ValueError("Billing key unavailable")


def monthly_spend():
    now = datetime.now(timezone.utc)
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    query = {"start_time": int(start.timestamp()), "end_time": int(now.timestamp()),
             "bucket_width": "1d", "limit": 31}
    total = Decimal(0)
    headers = {"Authorization": "Bearer " + billing_key()}
    conn = HTTPSConnection("api.openai.com", timeout=15)
    seen = set()
    try:
        while True:
            conn.request("GET", "/v1/organization/costs?" + urlencode(query), headers=headers)
            response = conn.getresponse()
            if response.status != 200:
                raise ValueError(f"Costs API returned HTTP {response.status}")
            page = json.load(response, parse_float=Decimal)
            for bucket in page["data"]:
                for row in bucket["results"]:
                    amount = row["amount"]
                    if amount["currency"].lower() != "usd":
                        raise ValueError("Unexpected currency")
                    total += Decimal(amount["value"])
            if not page["has_more"]:
                break
            cursor = page["next_page"]
            if not cursor or cursor in seen:
                raise ValueError("Invalid pagination")
            seen.add(cursor)
            query["page"] = cursor
    finally:
        conn.close()
    return {"month": now.strftime("%Y-%m"), "usd": str(total)}


if __name__ == "__main__":
    try:
        print(json.dumps(monthly_spend()))
    except Exception as error:
        # Limit diagnostics to the failure type; never log credentials or response bodies.
        print(f"Monthly API spend unavailable ({type(error).__name__})", file=sys.stderr)
        sys.exit(1)

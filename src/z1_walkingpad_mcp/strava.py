"""Strava upload pipeline — sessions -> Strava -> Apple Health.

Why: HealthKit writes are impossible on macOS, but the Strava iOS app
syncs activities to Apple Health natively. So treadmill_stop uploads a
Walk activity here, and the iPhone does the rest automatically.

Setup (one time):
  1. Create a free API app at https://www.strava.com/settings/api
     (any name/website; callback domain: localhost)
  2. Run: python -m z1_walkingpad_mcp.strava auth --client-id ID --client-secret SECRET
     and follow the prompts (opens an approval link, paste back the code)

Tokens live in ~/.z1-walkingpad/strava.json and refresh automatically.

Run standalone to test: python -m z1_walkingpad_mcp.strava test
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API_BASE = "https://www.strava.com/api/v3"
TOKEN_URL = "https://www.strava.com/oauth/token"
AUTH_URL = "https://www.strava.com/oauth/authorize"

CONFIG_FILE = Path.home() / ".z1-walkingpad" / "strava.json"


class StravaError(RuntimeError):
    pass


def configured() -> bool:
    return CONFIG_FILE.exists()


def _load() -> dict:
    try:
        return json.loads(CONFIG_FILE.read_text())
    except (OSError, json.JSONDecodeError) as e:
        raise StravaError(f"cannot read {CONFIG_FILE}: {e}") from e


def _save(cfg: dict) -> None:
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2))
    CONFIG_FILE.chmod(0o600)


def _post_form(url: str, fields: dict, bearer: str | None = None) -> dict:
    data = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(url, data=data)
    if bearer:
        req.add_header("Authorization", f"Bearer {bearer}")
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")[:500]
        raise StravaError(f"Strava {url} -> HTTP {e.code}: {body}") from e
    except (urllib.error.URLError, TimeoutError) as e:
        raise StravaError(f"Strava request failed: {e}") from e


def _access_token(cfg: dict) -> str:
    """Return a valid access token, refreshing (and persisting) if expired."""
    if cfg.get("expires_at", 0) - 60 > time.time():
        return cfg["access_token"]
    resp = _post_form(
        TOKEN_URL,
        {
            "client_id": cfg["client_id"],
            "client_secret": cfg["client_secret"],
            "grant_type": "refresh_token",
            "refresh_token": cfg["refresh_token"],
        },
    )
    cfg.update(
        access_token=resp["access_token"],
        refresh_token=resp["refresh_token"],  # Strava rotates refresh tokens
        expires_at=resp["expires_at"],
    )
    _save(cfg)
    return cfg["access_token"]


def upload_walk(summary: dict, ended_at: int) -> int:
    """Upload a finished session as a Walk activity. Returns the activity ID."""
    duration_s = int(summary.get("duration_s") or 0)
    if duration_s <= 0:
        raise StravaError("session has no duration — nothing to upload")
    cfg = _load()
    token = _access_token(cfg)
    start_local = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(ended_at - duration_s))
    kcal = summary.get("calories_kcal")
    steps = summary.get("steps")
    avg = summary.get("avg_speed_kmh")
    desc_parts = [
        "WalkingPad Z1 session (auto-uploaded by z1-walkingpad-mcp)",
        f"avg {avg} km/h" if avg else None,
        f"{steps} steps" if steps else None,
        f"~{kcal} kcal (MET estimate)" if kcal else None,
    ]
    resp = _post_form(
        f"{API_BASE}/activities",
        {
            "name": time.strftime("WalkingPad walk %H:%M", time.localtime(ended_at)),
            "sport_type": "Walk",
            "start_date_local": start_local,
            "elapsed_time": duration_s,
            "distance": int(summary.get("distance_m") or 0),
            "trainer": 1,
            "description": " · ".join(p for p in desc_parts if p),
        },
        bearer=token,
    )
    return int(resp["id"])


def _auth(client_id: str, client_secret: str) -> None:
    params = urllib.parse.urlencode(
        {
            "client_id": client_id,
            "redirect_uri": "http://localhost",
            "response_type": "code",
            "approval_prompt": "auto",
            "scope": "activity:write",
        }
    )
    print("Open this URL, approve, and you'll be redirected to a dead localhost page:")
    print(f"\n  {AUTH_URL}?{params}\n")
    print("Copy the 'code' parameter from the redirect URL's query string.")
    code = input("code: ").strip()
    if not code:
        raise StravaError("no code given")
    resp = _post_form(
        TOKEN_URL,
        {
            "client_id": client_id,
            "client_secret": client_secret,
            "code": code,
            "grant_type": "authorization_code",
        },
    )
    _save(
        {
            "client_id": client_id,
            "client_secret": client_secret,
            "access_token": resp["access_token"],
            "refresh_token": resp["refresh_token"],
            "expires_at": resp["expires_at"],
            "athlete": resp.get("athlete", {}).get("username")
            or resp.get("athlete", {}).get("firstname"),
        }
    )
    print(f"saved to {CONFIG_FILE} (chmod 600)")


def main() -> int:
    parser = argparse.ArgumentParser(prog="z1-strava", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p_auth = sub.add_parser("auth", help="one-time OAuth setup")
    p_auth.add_argument("--client-id", required=True)
    p_auth.add_argument("--client-secret", required=True)
    sub.add_parser("test", help="upload a 1-minute test walk")
    args = parser.parse_args()
    try:
        if args.command == "auth":
            _auth(args.client_id, args.client_secret)
        else:
            now = int(time.time())
            activity_id = upload_walk(
                {"duration_s": 60, "distance_m": 40, "steps": 100, "calories_kcal": 4.0, "avg_speed_kmh": 2.4},
                now,
            )
            print(f"uploaded test activity: https://www.strava.com/activities/{activity_id}")
            print("(delete it from Strava after checking it lands in Apple Health)")
        return 0
    except StravaError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

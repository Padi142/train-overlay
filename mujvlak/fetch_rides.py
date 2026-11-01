#!/usr/bin/env python3
"""
Můj vlak (My Train) — ride-history fetcher
==========================================

Fetches your previous rides (purchased tickets) from the ČD "Můj vlak" app
back-ends, reconstructed from the decompiled APK (see openapi.yaml).

Two back-ends are supported (--backend):

  ipws  (default — WORKS)
      CHAPS IPWS e-shop service (ipws.cdis.cz) — the app's e-shop/ticket
      backend. Login = your ČD e-shop e-mail + password. Flow: anonymous
      CreateSession -> Login1 -> GetTickets (full sync => empty lists).
      The server gates on the sAppID GUID: the OLD app id {1532A12E-…}
      (decompiled v2.16.1) is rejected with `10000 Neautorizovaný přístup.`,
      the current v32 app id {A6AB5B3E-…} is accepted.

  mapphone
      ČD MapPhone service (mapphone.cd.cz). The account UserName is your
      IN-Karta card number and the 'PIN' is your ČD e-shop password; the
      account only exists if you activated an IN-Karta/VIK in the app
      (otherwise: ACCOUNT_DOES_NOT_EXIST). History = product sync.

Wire format highlights
----------------------
MapPhone (all JSON, PascalCase fields, every response has "Status"):
    POST {base}/bindAccount    {UserName, DeviceID, PushDeviceID, PIN, DeviceInfo}
    POST {base}/syncProducts   {UserName, DeviceID, Timestamp, Tags, QRVersion}
    Dates are yyyyMMddHHmm ("yyyyMMdd" for EndOfValidity), Timestamp yyyyMMddHHmmss.
IPWS:
    POST {base}/<Command> with {"iLang":0[, "sSessionID": …], …}; session comes
    from IP.svc/CreateSession; errors arrive as HTTP 500 + {"ExceptionType",
    "Message": "<code> <text>"} (the app treats 500 as a valid response).

Requirements:  pip install requests
Usage:
    python fetch_rides.py -u you@example.com -p "your-eshop-password"
    python fetch_rides.py -u you@example.com -p "your-eshop-password" -f csv -o rides.csv
    python fetch_rides.py -b ipws -u you@example.com -p 'password' --debug
    python fetch_rides.py -b ipws -u you@example.com -p secret --raw
Credentials may also come from MUJVLAK_EMAIL / MUJVLAK_PASSWORD (env) or an
interactive prompt.
"""

import argparse
import getpass
import json
import os
import sys
import uuid
from datetime import datetime

import requests

# Ensure Czech text from the server renders correctly on Windows consoles
if sys.stdout and sys.stdout.encoding and sys.stdout.encoding.lower() not in ("utf-8", "utf8"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

# ---------------------------------------------------------------------------
# Defaults — production servers & app identity (from CommonDb.java / IpwsUtils.java)
# ---------------------------------------------------------------------------
MAPPHONE_BASE = "https://mapphone.cd.cz/MapPhoneServerWS.svc/"
IPWS_BASE = "https://ipws.cdis.cz/IP.svc/"
# The server only accepts the CURRENT (v32) app GUID — the old one from the
# decompiled v2.16.1 build ({1532A12E-0D17-4B83-A9BB-8827EAD33F26}) is rejected
# with "10000 Neautorizovaný přístup." by a server-side client filter.
DEFAULT_APP_ID = "{A6AB5B3E-8A7E-4E84-9DC8-801561CE886F}"  # IPWS v32 app GUID
APP_VERSION_NAME = "2.19.0"
LANGS = {"cs": 0, "en": 1, "de": 2, "sk": 3, "pl": 4}      # from IpwsCommon$IpwsParam

TIMEOUT = 30
# Headers as sent by the app (MapPhone: Retrofit/OkHttp; IPWS: OkHttp via WsUtils)
HEADERS = {"Accept": "application/json",
           "Content-Type": "application/json; charset=utf-8",
           "User-Agent": "okhttp/5.1.0"}

DEVICE_ID_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".mujvlak_device_id")


class IpwsError(RuntimeError):
    """Server-side error, Message = '<numeric code> <text>'."""


class MapPhoneError(RuntimeError):
    """MapPhone business error (non-OK Status)."""


def get_device_id() -> str:
    """Stable device GUID, like the app generates on first start."""
    if os.path.exists(DEVICE_ID_FILE):
        with open(DEVICE_ID_FILE, encoding="ascii") as f:
            dev = f.read().strip()
            if dev:
                return dev
    import uuid
    dev = str(uuid.uuid4())
    with open(DEVICE_ID_FILE, "w", encoding="ascii") as f:
        f.write(dev)
    return dev


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------
def http_post(url: str, payload: dict, timeout: int, verify: bool, debug: bool) -> dict:
    """POST JSON. HTTP 200 and 500 are both returned to the caller as parsed JSON
    (the IPWS server signals business errors via HTTP 500 + an ExceptionType body —
    the app also accepts 500, see IpwsCommon$IpwsParam.isResponseCodeAcceptable)."""
    import requests
    resp = requests.post(url, json=payload, headers=HEADERS, timeout=timeout,
                         verify=verify)
    if debug:
        print("--- DEBUG ---", file=sys.stderr)
        print(f"POST {url}", file=sys.stderr)
        print(f"body: {json.dumps(payload, ensure_ascii=False)}", file=sys.stderr)
        print(f"HTTP {resp.status_code}", file=sys.stderr)
        print(f"resp: {resp.text[:1500]}", file=sys.stderr)
        print("--- end ---", file=sys.stderr)
    if resp.status_code not in (200, 500):
        resp.raise_for_status()
    return resp.json()


def parse_dt(s: str | None):
    """IPWS datetimes are ISO-8601 strings (IpwsUtils.convertJSONToDateTime)."""
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def parse_mptimestamp(s: str | None):
    """MapPhone timestamps: yyyyMMddHHmmss or yyyyMMddHHmm."""
    if not s:
        return None
    for fmt in ("%Y%m%d%H%M%S", "%Y%m%d%H%M"):
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            continue
    return None


# ---------------------------------------------------------------------------
# Back-end A: MapPhone  (works, recommended)
# ---------------------------------------------------------------------------
def mp_login(base: str, username: str, pin: str, device_id: str,
             timeout: int, verify: bool, debug: bool) -> dict:
    """bindAccount — binds this 'device' to the account (the app's login)."""
    d = mp_post(base, "bindAccount", {
        "UserName": username,
        "DeviceID": device_id,
        "PushDeviceID": None,
        "PIN": pin,
        "DeviceInfo": "Python fetch_rides",
    }, timeout, verify, debug)
    status = d.get("Status", "UNKNOWN")
    if status not in ("OK", "TANDEM_BOUND", "TANDEM_CREATED_AND_BOUND"):
        raise MapPhoneError(f"bindAccount failed: {status}")
    print(f"[+] bound to account {username} (Status={status})")
    return d


def mp_fetch_products(base: str, username: str, device_id: str,
                      timeout: int, verify: bool, debug: bool) -> dict:
    """syncProducts with Timestamp=null → full history of purchased products."""
    return mp_post(base, "syncProducts", {
        "UserName": username,
        "DeviceID": device_id,
        "Timestamp": None,       # null => return everything
        "Tags": [],
        "QRVersion": 1,
    }, timeout, verify, debug)


def mp_print_rides(sync: dict) -> None:
    products = sync.get("Products") or []
    # sort by validity start
    def key(p):
        return p.get("ValidFrom") or ""
    products.sort(key=key)

    if not products:
        print("[-] no tickets/products found for this account")
        return

    print(f"\n=== previous rides / tickets ({len(products)}) "
          f"— server sync cursor: {sync.get('Timestamp')!r} ===\n")

    for p in products:
        vf = parse_mptimestamp(p.get("ValidFrom"))
        vt = parse_mptimestamp(p.get("ValidTo"))
        vf_s = vf.strftime("%Y-%m-%d %H:%M") if vf else (p.get("ValidFrom") or "?")
        vt_s = vt.strftime("%Y-%m-%d %H:%M") if vt else (p.get("ValidTo") or "")
        desc = p.get("Description") or ""
        ptype = p.get("ProductType") or ""
        status = p.get("Status") or ""
        pid = p.get("ProductID") or ""

        print(f"{vf_s}  →  {vt_s}")
        extras = [x for x in (desc, ptype, f"status={status}" if status else "",
                              f"id={pid}" if pid else "") if x]
        if extras:
            print("         " + " | ".join(str(x) for x in extras))
        print()


def mp_to_csv(sync: dict) -> str:
    import csv, io
    rows = []
    for p in sync.get("Products") or []:
        vf = parse_mptimestamp(p.get("ValidFrom"))
        vt = parse_mptimestamp(p.get("ValidTo"))
        rows.append({
            "valid_from": vf.isoformat() if vf else (p.get("ValidFrom") or ""),
            "valid_to": vt.isoformat() if vt else (p.get("ValidTo") or ""),
            "description": p.get("Description") or "",
            "product_type": p.get("ProductType") or "",
            "status": p.get("Status") or "",
            "product_id": p.get("ProductID") or "",
            "is_transmitted": p.get("IsTransmitted") or "",
        })
    out = io.StringIO()
    fields = ["valid_from", "valid_to", "description", "product_type", "status",
              "product_id", "is_transmitted"]
    writer = csv.DictWriter(out, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)
    return out.getvalue()


# ---------------------------------------------------------------------------
# Back-end B: IPWS  (currently blocked for non-app clients — see docstring)
# ---------------------------------------------------------------------------
def ipws_call(base: str, command: str, payload: dict, session_id: str | None,
              timeout: int, verify: bool, debug: bool) -> dict:
    body = {"iLang": 0}
    if session_id:
        body["sSessionID"] = session_id
    body.update(payload)
    envelope = http_post((base if base.endswith("/") else base + "/") + command, body, timeout, verify, debug)
    if "ExceptionType" in envelope and "Message" in envelope:
        raise IpwsError(envelope["Message"])
    return envelope.get("d") or {}


def build_user_desc(lang: str = "cs") -> str:
    """Device fingerprint in the exact 11-field format of IpwsUtils.getUserDesc():
        appVersionCode|sdkVersion|deviceModel|androidId^serial|installId|lang|country|dpi|width|height|versionName
    On SDK>=29 androidId/serial are omitted but '^' is always appended."""
    import platform
    import uuid as _uuid
    install_id = str(_uuid.UUID(int=_uuid.getnode()))
    return "|".join([
        "352", "34", platform.node() or "SM-S918B", "^", install_id,
        lang, "CZ", "440", "1080", "2400", APP_VERSION_NAME,
    ])


def ipws_login(base: str, email: str, password: str, app_id: str, user_desc: str,
               login_cmd: str, timeout: int, verify: bool, debug: bool) -> tuple[str, dict]:
    notif = {"iNotificationMask": 0, "iInitialAdvance": 0, "iChangeAdvance": 0,
             "iDelayLimit": 0, "iGetOffAdvance": 0}

    if login_cmd == "Login1":
        anon = ipws_call(base, "CreateSession", {
            "sAppID": app_id, "sUserDesc": user_desc, "sUser": "", "sPwd": "",
            "iTokenType": 1, "oRegisterNotificationsSettings": notif,
        }, None, timeout, verify, debug)
        session_id = anon.get("sSessionID")
        if not session_id:
            raise IpwsError("could not establish an anonymous session")
        d = ipws_call(base, "Login1", {"sUserDesc": user_desc, "sUser": email, "sPwd": password},
                      session_id, timeout, verify, debug)
    else:
        d = ipws_call(base, "CreateSession", {
            "sAppID": app_id, "sUserDesc": user_desc, "sUser": email, "sPwd": password,
            "iTokenType": 1, "oRegisterNotificationsSettings": notif,
        }, None, timeout, verify, debug)
        session_id = d.get("sSessionID")

    err = d.get("iLoginErr", 0)
    if err != 0:
        raise IpwsError(f"login failed: iLoginErr={err} {d.get('sLoginErr', '')}".strip())
    if not session_id and not d.get("sSessionID"):
        raise IpwsError("login succeeded but no session id was returned")
    session_id = session_id or d.get("sSessionID")

    print(f"[+] logged in as {email} (session {session_id[:8]}…)")
    return session_id, d.get("oLoginInfo") or {}


def ipws_fetch_tickets(base: str, session_id: str, trans_code_last: str | None,
                       known: list[str], timeout: int, verify: bool, debug: bool) -> dict:
    sync_param = {
        "sTransCodeLast": trans_code_last,
        "asTransCodes": known or [],
        "asRetTransCodes": [],
        "asLiftagoCodes": [],
        "asHasCompensationTransCodes": [],
        "asLastChange": [],
    }
    return ipws_call(base, "GetTickets", {"oSynchronizeParam": sync_param},
                     session_id, timeout, verify, debug)


def ipws_print_rides(history: dict) -> None:
    records = []
    for bucket_name in ("aoCreated", "aoRestored", "aoUpdated", "aoUser"):
        for t in history.get(bucket_name) or []:
            t["_bucket"] = bucket_name[2:].lower()
            records.append(t)
    records.sort(key=lambda t: t.get("dtDate") or "")

    if not records:
        print("[-] no tickets found for this account")
        return

    print(f"\n=== previous rides / tickets ({len(records)}) "
          f"— server trans-code cursor: {history.get('sTransCodeLast')!r} ===\n")

    for t in records:
        date = (t.get("dtDate") or "")[:10]
        frm = (t.get("oFrom") or {}).get("sStationName", "?")
        to = (t.get("oTo") or {}).get("sStationName", "?")
        extras = [x for x in (t.get("sDesc"), t.get("sDocName") or t.get("sProductCategory"),
                              f"trans-code {t.get('sTransCode')}" if t.get("sTransCode") else "")
                  if x]
        print(f"{date}  {frm} → {to}")
        if extras:
            print("         " + " | ".join(str(x) for x in extras))
        for leg_field in ("aoThere", "aoBack"):
            for leg in t.get(leg_field) or []:
                lf = (leg.get("oFrom") or {}).get("sStationName", "?")
                lt = (leg.get("oTo") or {}).get("sStationName", "?")
                dep = parse_dt((leg.get("oFrom") or {}).get("dtTime"))
                arr = parse_dt((leg.get("oTo") or {}).get("dtTime"))
                train = " ".join(x for x in (leg.get("sTrainType"), leg.get("sTrainNum")) if x) \
                    or leg.get("sTrainName") or "?"
                dep_s = dep.strftime("%H:%M") if dep else "  :  "
                arr_s = arr.strftime("%H:%M") if arr else "  :  "
                print(f"           {leg_field[2:]:>5}: {train:<10} {dep_s} {lf} → {lt} {arr_s}")
        print()


def ipws_to_csv(history: dict) -> str:
    import csv, io
    rows = []
    for t in (history.get("aoCreated") or []) + (history.get("aoRestored") or []) + \
             (history.get("aoUpdated") or []) + (history.get("aoUser") or []):
        dep = parse_dt((t.get("oFrom") or {}).get("dtTime"))
        arr = parse_dt((t.get("oTo") or {}).get("dtTime"))
        rows.append({
            "date": (t.get("dtDate") or "")[:10],
            "from": (t.get("oFrom") or {}).get("sStationName", ""),
            "to": (t.get("oTo") or {}).get("sStationName", ""),
            "departure": dep.isoformat() if dep else "",
            "arrival": arr.isoformat() if arr else "",
            "ticket": t.get("sDesc") or "",
            "doc_name": t.get("sDocName") or "",
            "product_category": t.get("sProductCategory") or "",
            "trans_code": t.get("sTransCode") or "",
            "persons": t.get("iNumPersons") or "",
        })
    out = io.StringIO()
    writer = csv.DictWriter(out, fieldnames=["date", "from", "to", "departure", "arrival",
                                             "ticket", "doc_name", "product_category",
                                             "trans_code", "persons"])
    writer.writeheader()
    writer.writerows(rows)
    return out.getvalue()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parse_args(argv: list[str]) -> "argparse.Namespace":
    p = argparse.ArgumentParser(
        prog="fetch_rides.py",
        description="Fetch your previous rides (ticket history) from the ČD Můj vlak "
                    "IPWS e-shop backend using your ČD e-shop e-mail + password "
                    "(the same credentials as the app's login screen). "
                    "Alternatively -b mapphone uses an IN-Karta card number + "
                    "password for the separate MapPhone backend (only exists if "
                    "you activated an IN-Karta in the app). Credentials come from "
                    "flags, env (MUJVLAK_EMAIL / MUJVLAK_PASSWORD) or a prompt.",
        epilog="example:  python fetch_rides.py -u you@example.com -p \"eshop-password\"",
    )
    p.add_argument("-u", "--user", metavar="USER",
                   default=os.environ.get("MUJVLAK_EMAIL"),
                   help="mapphone: IN-Karta card number (the account UserName) / "
                        "ipws: e-shop e-mail (env: MUJVLAK_EMAIL); prompted if missing")
    p.add_argument("-p", "--password", metavar="PWD",
                   default=os.environ.get("MUJVLAK_PASSWORD") or os.environ.get("MUJVLAK_PIN"),
                   help="your ČD e-shop account password — used by BOTH backends "
                        "(for mapphone the app stores it as the account 'PIN') "
                        "(env: MUJVLAK_PASSWORD or MUJVLAK_PIN); prompted if missing")
    p.add_argument("-b", "--backend", choices=("mapphone", "ipws"), default="ipws",
                   help="which back-end to use (default: ipws — e-mail + password; "
                        "mapphone needs an IN-Karta card number)")
    p.add_argument("-s", "--server", metavar="URL", default=None,
                   help="override base URL (default: MapPhone/IPWS production server)")
    p.add_argument("--app-id", metavar="GUID", default=DEFAULT_APP_ID,
                   help=f"IPWS only — sAppID (default: {DEFAULT_APP_ID})")
    p.add_argument("--user-desc", metavar="DESC", default=None,
                   help="IPWS only — sUserDesc fingerprint; default: auto-generated")
    p.add_argument("--login-cmd", choices=("CreateSession", "Login1"), default="Login1",
                   help="IPWS login strategy (default: Login1 — anonymous session "
                        "then explicit login, as the app does)")
    p.add_argument("-l", "--lang", choices=sorted(LANGS), default="cs",
                   help="IPWS content language (default: cs)")
    p.add_argument("-t", "--timeout", type=int, default=30, metavar="SEC",
                   help="request timeout in seconds (default: 30)")
    p.add_argument("--trans-code-last", metavar="CODE", default=None,
                   help="ipws delta sync: cursor trans-code")
    p.add_argument("-k", "--known-trans-codes", metavar="CODE", nargs="*", default=[],
                   help="ipws delta sync: already-known trans-codes")
    p.add_argument("-r", "--raw", action="store_true",
                   help="dump the raw JSON response instead of the formatted list")
    p.add_argument("-f", "--format", choices=("table", "json", "csv"), default="table",
                   help="output format (default: table)")
    p.add_argument("-o", "--output", metavar="FILE",
                   help="write result to a file instead of stdout")
    p.add_argument("-q", "--quiet", action="store_true",
                   help="suppress progress messages ([+] lines)")
    p.add_argument("-d", "--debug", action="store_true",
                   help="print full HTTP requests/responses to stderr")
    p.add_argument("--insecure", action="store_true",
                   help="disable TLS certificate verification (test servers)")
    p.add_argument("--new-device", action="store_true",
                   help="mapphone: generate a fresh device GUID instead of the saved one")

    args = p.parse_args(argv)

    # Interactive fallbacks so the script works bare:  python fetch_rides.py
    try:
        if not args.user:
            args.user = input("E-mail (ipws) / IN-Karta number (mapphone): ").strip()
        if args.password is None:
            prompt = "Password (ČD e-shop)"
            args.password = getpass.getpass(f"{prompt}: ")
    except (EOFError, KeyboardInterrupt):
        print("\n[!] aborted — supply credentials with -u/-p or environment variables",
              file=sys.stderr)
        sys.exit(2)

    if not args.user or not args.password:
        p.error("both user (card number / e-mail) and password are required")

    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    verify = not args.insecure
    debug = args.debug

    try:
        if args.backend == "mapphone":
            base = args.server or MAPPHONE_BASE
            device_id = get_device_id()
            if not args.quiet:
                print(f"[*] device id: {device_id}")
            mp_login(base, args.user, args.password, device_id,
                     args.timeout, verify, debug)
            history = mp_fetch_products(base, args.user, device_id,
                                        args.timeout, verify, debug)
        else:
            base = args.server or IPWS_BASE
            user_desc = args.user_desc or build_user_desc(args.lang)
            if not args.quiet:
                print(f"[*] sUserDesc: {user_desc}")
            session_id, login_info = ipws_login(base, args.user, args.password,
                                                args.app_id, user_desc,
                                                args.login_cmd, args.timeout,
                                                verify, debug)
            if login_info and not args.quiet:
                name = " ".join(x for x in (login_info.get("sFirstName"),
                                            login_info.get("sSurname")) if x)
                if name:
                    print(f"[+] account: {login_info.get('sEmail', args.user)} ({name.strip()})")
            history = ipws_fetch_tickets(base, session_id, args.trans_code_last,
                                         args.known_trans_codes, args.timeout,
                                         verify, debug)

        # ---------------- output ----------------
        if args.raw or args.format == "json":
            text = json.dumps(history, indent=2, ensure_ascii=False)
        elif args.format == "csv":
            text = mp_to_csv(history) if args.backend == "mapphone" else ipws_to_csv(history)
        else:
            text = None
            if args.backend == "mapphone":
                mp_print_rides(history)
            else:
                ipws_print_rides(history)

        if text is not None:
            if args.output:
                with open(args.output, "w", encoding="utf-8") as f:
                    f.write(text)
                if not args.quiet:
                    print(f"[+] written to {args.output}")
            else:
                print(text)
        return 0

    except (IpwsError, MapPhoneError) as e:
        print(f"[!] server error: {e}", file=sys.stderr)
    except requests.HTTPError as e:
        print(f"[!] HTTP {e.response.status_code}: {e.response.text[:300]}", file=sys.stderr)
    except requests.RequestException as e:
        print(f"[!] connection problem: {e}", file=sys.stderr)
    return 1


def mp_post(base: str, command: str, payload: dict, timeout: int,
            verify: bool, debug: bool) -> dict:
    """MapPhone POST helper (HTTP 200 with a Status field; no 500-error envelope)."""
    url = (base if base.endswith("/") else base + "/") + command
    return http_post(url, payload, timeout, verify, debug)


if __name__ == "__main__":
    sys.exit(main())

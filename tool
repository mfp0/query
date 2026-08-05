#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dbtool.py - CLI tool for querying an Oracle database through SQLcl (sql.exe).

Built as a tool for an LLM agent (Roo Code): an alternative to clicking around in
SQL Developer, except the model composes and runs the queries. Python STANDARD
LIBRARY ONLY, no Oracle drivers. The only channel to the database is SQLcl run via
subprocess; the SQL script is fed on stdin and the result comes back as JSON.

Output is ALWAYS a single JSON object on stdout (including on error):
    success: {"ok": true,  "columns": [...], "rows": [[...]], "row_count": n, "truncated": bool}
    error:   {"ok": false, "error": "...", "ora_code": "ORA-12514", "hint": "..."}
Exit codes: 0 = success, 1 = SQL/DB error, 2 = usage error, 3 = timeout.

Configuration lives in `config.ini` next to this script. It is created
automatically on first run (a template to fill in). Environments are defined as
sections [dev]/[prod]/... each with host/port/service/user/pwd. Environment
selection order:
    --env <name>  >  DBTOOL_ENV env var  >  [DEFAULT] env
The variables ORA_USER / ORA_PWD / ORA_DSN override values from config (if set).

EXAMPLES (for the agent):
    python dbtool.py ping
    python dbtool.py tables --like "EMP%"
    python dbtool.py describe EMPLOYEES
    python dbtool.py query "SELECT employee_id, last_name FROM employees"
    python dbtool.py query "SELECT * FROM emp WHERE deptno = :dno" --bind dno=10
    python dbtool.py query --file big_report.sql --bind dno=10
    python dbtool.py --env prod query "SELECT sysdate FROM dual" --format tsv
"""

import argparse
import configparser
import json
import os
import re
import subprocess
import sys

# -- Defaults (customize mainly via config.ini, not here) ---------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(SCRIPT_DIR, "config.ini")
DEFAULT_LIMIT = 200
DEFAULT_TIMEOUT = 60
PWD_PLACEHOLDER = "CHANGE_ME"
# SQLcl path detected on this machine - overridable in config or via SQLCL_PATH.
DEFAULT_SQLCL = r"C:\Users\mpolo\.vscode\extensions\oracle.sql-developer-26.2.0-win32-x64\dbtools\sqlcl\bin\sql.exe"

# Map the most common Oracle errors to a short hint for the model.
ORA_HINTS = {
    "ORA-12514": "Listener does not know this service - check 'service' in config.ini (for XE usually XEPDB1).",
    "ORA-12541": "No listener - check host/port and whether the database is up.",
    "ORA-12505": "Listener does not know this SID/service - check 'service' in config.ini.",
    "ORA-01017": "Invalid username/password - fix user/pwd in the environment section of config.ini.",
    "ORA-28000": "Account is locked - unlock the user in the database.",
    "ORA-00942": "Table/view does not exist or no privilege - check the name and schema.",
    "ORA-00904": "Invalid column name - check the column names in your query.",
    "ORA-00933": "SQL command not properly ended - check the syntax.",
    "ORA-01031": "Insufficient privileges for this operation.",
}

CONFIG_TEMPLATE = """\
; config.ini - configuration for dbtool.py
; Environment selection: --env <name>  >  DBTOOL_ENV env var  >  [DEFAULT] env below.
; The variables ORA_USER / ORA_PWD / ORA_DSN override section values (if set).

[DEFAULT]
; Default environment when --env is not given:
env = dev
; Path to sql.exe (SQLcl). Leave empty to use SQLCL_PATH or auto-detection:
sqlcl_path =
; Default row limit and timeout (seconds) - can be overridden per environment or by flags:
limit = 200
timeout = 60
; JDBC driver: thin = pure JDBC, no Oracle client (recommended, always works),
; thick = OCI, requires an installed Oracle client on PATH. Keep thin.
driver = thin

[dev]
host = localhost
port = 1521
service = XEPDB1
user = system
pwd = CHANGE_ME

; Example of a second environment - uncomment and fill in.
; Per-environment overrides (timeout/limit/driver/sqlcl_path) are allowed too.
;[prod]
;host = prod-db.company.local
;port = 1521
;service = ORCLPDB1
;user = report
;pwd = CHANGE_ME
;timeout = 120
;limit = 500
"""


# -- Error carrier with an exit code ------------------------------------------
class ToolError(Exception):
    def __init__(self, message, exit_code=1, ora_code=None, hint=None):
        super().__init__(message)
        self.message = message
        self.exit_code = exit_code
        self.ora_code = ora_code
        self.hint = hint


def mask_pwd(text, pwd):
    """Mask the password in any text that could reach an echo/error message."""
    if pwd and text:
        return text.replace(pwd, "****")
    return text


# -- Configuration ------------------------------------------------------------
def ensure_config():
    """Create the config.ini template on first run and stop the program."""
    if os.path.exists(CONFIG_PATH):
        return
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        f.write(CONFIG_TEMPLATE)
    raise ToolError(
        "Created a config template: {} - fill in host/port/service/user/pwd for "
        "your environment and run again.".format(CONFIG_PATH),
        exit_code=2,
        hint="Default environment is [dev]. Change the pwd field ({}).".format(PWD_PLACEHOLDER),
    )


def load_connection(env_name):
    """Collect connection parameters from config.ini (+ ORA_* env overrides)."""
    cfg = configparser.ConfigParser()
    cfg.read(CONFIG_PATH, encoding="utf-8")

    env = env_name or os.environ.get("DBTOOL_ENV") or cfg["DEFAULT"].get("env", "dev")
    if env not in cfg:
        available = [s for s in cfg.sections()] or ["(none)"]
        raise ToolError(
            "No section [{}] in config.ini. Available environments: {}".format(
                env, ", ".join(available)
            ),
            exit_code=2,
        )

    sec = cfg[env]
    host = sec.get("host", "localhost")
    port = sec.get("port", "1521")
    service = sec.get("service", "")
    user = os.environ.get("ORA_USER") or sec.get("user", "")
    pwd = os.environ.get("ORA_PWD") or sec.get("pwd", "")

    dsn = os.environ.get("ORA_DSN") or "//{}:{}/{}".format(host, port, service)

    if not user or not pwd or (not os.environ.get("ORA_DSN") and not service):
        raise ToolError(
            "Incomplete configuration for environment [{}] - user, pwd and service "
            "(or ORA_DSN) are required. Fill in config.ini.".format(env),
            exit_code=2,
        )
    if pwd == PWD_PLACEHOLDER:
        raise ToolError(
            "Password in config.ini for [{}] is still the placeholder '{}' - set a real one.".format(
                env, PWD_PLACEHOLDER
            ),
            exit_code=2,
        )

    # SQLcl path resolution: config > SQLCL_PATH > auto-detection.
    # These fields are read from the environment section (sec), which inherits
    # values from [DEFAULT] - so they can be overridden per environment.
    sqlcl = (
        sec.get("sqlcl_path", "").strip()
        or os.environ.get("SQLCL_PATH", "").strip()
        or DEFAULT_SQLCL
    )
    if not os.path.isfile(sqlcl):
        raise ToolError(
            "sql.exe not found: {}. Set 'sqlcl_path' in config.ini or the "
            "SQLCL_PATH variable.".format(sqlcl),
            exit_code=2,
        )

    limit = int(sec.get("limit", str(DEFAULT_LIMIT)))
    timeout = int(sec.get("timeout", str(DEFAULT_TIMEOUT)))
    driver = sec.get("driver", "thin").strip().lower() or "thin"

    return {
        "user": user,
        "pwd": pwd,
        "dsn": dsn,
        "driver": driver,
        "sqlcl": sqlcl,
        "env": env,
        "limit": limit,
        "timeout": timeout,
    }


# -- Running SQLcl ------------------------------------------------------------
def build_script(body_statements, binds=None, for_write=False):
    """Assemble a complete SQLcl script. Every statement MUST end with a
    semicolon, otherwise SQLcl waits for more input and the process hangs -
    we enforce that here. In write mode we skip JSON formatting and keep SQLcl
    feedback on, because DDL/DML returns no result set - only a status line."""
    lines = []
    if not for_write:
        # Read path: JSON output, no feedback noise.
        lines += ["SET SQLFORMAT JSON"]
    # Feedback stays OFF for the header (so the ALTER SESSION lines below don't
    # echo "Session altered."); the write path turns it back on just before the
    # user statement to capture "Table created." etc.
    lines += [
        "SET FEEDBACK OFF",
        "SET ENCODING UTF-8",
        "SET PAGESIZE 0",
        # English Oracle error messages regardless of the server locale.
        "ALTER SESSION SET NLS_LANGUAGE = 'AMERICAN';",
        # CRITICAL: with a comma-decimal locale the number 3.14 serializes as
        # "3,14" and breaks the JSON. Force a dot decimal separator. Dates and
        # timestamps go to ISO - unambiguous and convenient for the model.
        # (Set after NLS_LANGUAGE, which would otherwise reset these.)
        "ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';",
        "ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS';",
        "ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF';",
        "ALTER SESSION SET NLS_TIMESTAMP_TZ_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF TZR';",
    ]
    # Write path: enable feedback now, after the silent ALTER SESSION block, so
    # only the user's statement produces a status line ("Table created.").
    if for_write:
        lines.append("SET FEEDBACK ON")

    # Binds as SQLcl variables (:name) - values are assigned in a PL/SQL block,
    # never concatenated into the query text.
    if binds:
        for name, value in binds.items():
            lines.append("VARIABLE {} VARCHAR2(4000)".format(name))
            # q'{...}' - alternative quoting, minimizes trouble with apostrophes.
            safe = value.replace("}", "")  # delimiter is '}', drop collisions
            lines.append("BEGIN :{} := q'{{{}}}'; END;".format(name, safe))
            lines.append("/")

    for stmt in body_statements:
        s = stmt.strip()
        if not s.endswith(";"):
            s += ";"
        lines.append(s)

    lines.append("EXIT;")
    return "\n".join(lines) + "\n"


def run_sqlcl(conn, script):
    """Run sql.exe, feed the script on stdin, return (stdout, stderr)."""
    # Driver forcing: for thin we build an explicit jdbc:oracle:thin:@... URL.
    # In this SQLcl the @//host form maps to OCI (thick) and needs an Oracle
    # client, which is absent - thin (pure JDBC) connects without a client.
    dsn = conn["dsn"]
    if dsn.startswith("jdbc:"):
        connect_id = dsn
    elif conn.get("driver", "thin") == "thin":
        connect_id = "jdbc:oracle:thin:@" + dsn
    else:
        connect_id = dsn  # thick/OCI - the user has an Oracle client on PATH
    # The password goes in argv (deliberate choice - internal tool). In any
    # echo/error it is masked by mask_pwd.
    conn_arg = "{}/{}@{}".format(conn["user"], conn["pwd"], connect_id)
    cmd = [conn["sqlcl"], "-S", conn_arg]
    try:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except FileNotFoundError:
        raise ToolError(
            "Cannot start sql.exe: {}".format(conn["sqlcl"]), exit_code=2
        )

    try:
        stdout, stderr = proc.communicate(input=script, timeout=conn["timeout"])
    except subprocess.TimeoutExpired:
        # sql.exe starts java.exe as a child process - a plain proc.kill()
        # would leave an orphan grinding away at the query. Kill the whole tree.
        _kill_tree(proc)
        raise ToolError(
            "Timeout after {}s - SQLcl process killed.".format(conn["timeout"]),
            exit_code=3,
            hint="Narrow the query or increase 'timeout' in config.ini.",
        )
    return stdout or "", stderr or ""


def _kill_tree(proc):
    """Kill the SQLcl process together with its child java.exe (Windows: taskkill /T)."""
    if sys.platform == "win32":
        subprocess.run(
            ["taskkill", "/F", "/T", "/PID", str(proc.pid)],
            capture_output=True,
        )
    else:
        proc.kill()
    try:
        proc.wait(timeout=5)
    except Exception:
        pass


def extract_ora_error(text):
    """Find an ORA-##### code in text (SQLcl banner/error)."""
    m = re.search(r"(ORA-\d{5})", text or "")
    if m:
        code = m.group(1)
        # Grab the line carrying the message, if present.
        line = ""
        for l in text.splitlines():
            if code in l:
                line = l.strip()
                break
        return code, line
    return None, None


def parse_json_output(stdout, conn):
    """Parse SQLcl output. SQLcl may print a banner/warnings before the JSON, so
    we cut from the first '{' to the last '}' instead of assuming clean stdout."""
    # First check whether this is an Oracle error (then there is no valid JSON).
    ora_code, ora_line = extract_ora_error(stdout)

    start = stdout.find("{")
    end = stdout.rfind("}")
    if start == -1 or end == -1 or end < start:
        if ora_code:
            raise ToolError(
                mask_pwd(ora_line or ora_code, conn["pwd"]),
                exit_code=1,
                ora_code=ora_code,
                hint=ORA_HINTS.get(ora_code),
            )
        raise ToolError(
            "No JSON found in SQLcl output: {}".format(
                mask_pwd(stdout.strip()[:400], conn["pwd"]) or "(empty)"
            ),
            exit_code=1,
        )

    blob = stdout[start : end + 1]
    try:
        data = json.loads(blob)
    except json.JSONDecodeError as e:
        if ora_code:
            raise ToolError(
                mask_pwd(ora_line or ora_code, conn["pwd"]),
                exit_code=1,
                ora_code=ora_code,
                hint=ORA_HINTS.get(ora_code),
            )
        raise ToolError("Failed to parse JSON: {}".format(e), exit_code=1)

    return data


def rows_from_data(data):
    """Extract (columns, rows) from results[0]. Column names come from the
    metadata results[0].columns (present even for 0 rows); values come from
    items - item keys are lowercased, so we map them case-insensitively."""
    results = data.get("results") or []
    if not results:
        return [], []
    res = results[0]
    col_meta = res.get("columns") or []
    items = res.get("items") or []

    if col_meta:
        columns = [c.get("name") for c in col_meta]
        rows = []
        for it in items:
            low = {k.lower(): v for k, v in it.items()}
            rows.append([low.get(name.lower()) for name in columns])
        return columns, rows

    # Fallback in case SQLcl did not provide column metadata.
    if not items:
        return [], []
    columns = list(items[0].keys())
    rows = [[row.get(c) for c in columns] for row in items]
    return columns, rows


# -- Read-only guard + auto-limit ---------------------------------------------
def strip_sql_comments(sql):
    """Remove -- and /* */ comments for inspection (not for execution)."""
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.DOTALL)
    sql = re.sub(r"--[^\n]*", " ", sql)
    return sql


def strip_string_literals(sql):
    """Replace string literals with '' so a semicolon/ROWNUM inside data does not
    fool the guards. Handles 'plain', ''doubled'' and q'[...]' / q'{...}' / q'(...)'."""
    sql = re.sub(r"q'\[.*?\]'", "''", sql, flags=re.DOTALL)
    sql = re.sub(r"q'\{.*?\}'", "''", sql, flags=re.DOTALL)
    sql = re.sub(r"q'\(.*?\)'", "''", sql, flags=re.DOTALL)
    sql = re.sub(r"q'<.*?>'", "''", sql, flags=re.DOTALL)
    sql = re.sub(r"'(?:''|[^'])*'", "''", sql)
    return sql


def enforce_readonly(sql):
    """Reject anything that is not SELECT/WITH and block multiple statements."""
    clean = strip_sql_comments(sql).strip()
    if not clean:
        raise ToolError("Empty query.", exit_code=2)

    first = clean.split(None, 1)[0].upper()
    if first not in ("SELECT", "WITH"):
        raise ToolError(
            "Read-only mode: only SELECT/WITH allowed (got '{}'). "
            "For writes: --allow-write --yes.".format(first),
            exit_code=2,
        )

    # Block multiple statements: a semicolon in the middle (not the trailing one)
    # is suspicious. Literals are stripped so a semicolon inside data (e.g.
    # SELECT ';' ...) does not produce a false positive.
    body = strip_string_literals(clean).rstrip(";").strip()
    if ";" in body:
        raise ToolError(
            "Multiple SQL statements in one call detected - not allowed.",
            exit_code=2,
        )


def has_own_limit(sql):
    """Does the query already limit the number of rows itself?"""
    u = strip_string_literals(strip_sql_comments(sql)).upper()
    return bool(
        re.search(r"\bFETCH\s+(FIRST|NEXT)\b", u)
        or re.search(r"\bROWNUM\b", u)
        or re.search(r"\bOFFSET\b", u)
    )


def apply_limit(sql, limit):
    """Append FETCH FIRST n ROWS ONLY when the query has no limit of its own."""
    body = sql.strip().rstrip(";").rstrip()
    return "{} FETCH FIRST {} ROWS ONLY".format(body, limit)


# -- Output formatting --------------------------------------------------------
def emit_success(columns, rows, truncated, fmt):
    if fmt == "tsv":
        # TSV: first row is the header. Compact for large result sets.
        out = ["\t".join(columns)]
        for r in rows:
            out.append("\t".join("" if v is None else str(v) for v in r))
        sys.stdout.write("\n".join(out) + "\n")
    else:
        payload = {
            "ok": True,
            "columns": columns,
            "rows": rows,
            "row_count": len(rows),
            "truncated": truncated,
        }
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")


def emit_error(err):
    payload = {"ok": False, "error": err.message}
    if err.ora_code:
        payload["ora_code"] = err.ora_code
    if err.hint:
        payload["hint"] = err.hint
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")


# -- Subcommands --------------------------------------------------------------
def run_query_sql(conn, sql, fmt, limit, applied_limit):
    script = build_script([sql], binds=conn.get("_binds"))
    stdout, stderr = run_sqlcl(conn, script)
    data = parse_json_output(stdout, conn)
    columns, rows = rows_from_data(data)
    # truncated: only when we imposed the limit and hit it exactly.
    truncated = applied_limit and len(rows) >= limit
    emit_success(columns, rows, truncated, fmt)


def run_write_sql(conn, sql):
    """Write path (--allow-write): DDL/DML returns no JSON result set, only a
    status line. Report success unless SQLcl emitted an ORA- error."""
    script = build_script([sql], binds=conn.get("_binds"), for_write=True)
    stdout, stderr = run_sqlcl(conn, script)
    ora_code, ora_line = extract_ora_error(stdout + "\n" + stderr)
    if ora_code:
        raise ToolError(
            mask_pwd(ora_line or ora_code, conn["pwd"]),
            exit_code=1,
            ora_code=ora_code,
            hint=ORA_HINTS.get(ora_code),
        )
    # Any other error text (no ORA code) is still a failure.
    combined = (stdout + "\n" + stderr)
    if re.search(r"\b(Error|SP2-\d+)\b", combined):
        raise ToolError(mask_pwd(combined.strip()[:400], conn["pwd"]), exit_code=1)
    message = " ".join(l.strip() for l in stdout.splitlines() if l.strip())
    payload = {"ok": True, "write": True, "message": message or "Statement executed."}
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")


def cmd_ping(conn, args):
    sql = (
        "SELECT (SELECT banner FROM v$version WHERE ROWNUM = 1) AS banner, "
        "SYS_CONTEXT('USERENV','DB_NAME') AS db_name, "
        "SYS_CONTEXT('USERENV','SERVICE_NAME') AS service, "
        "USER AS current_user FROM dual"
    )
    script = build_script([sql])
    stdout, stderr = run_sqlcl(conn, script)
    data = parse_json_output(stdout, conn)
    columns, rows = rows_from_data(data)
    emit_success(columns, rows, False, args.format)


def read_query_sql(args):
    """Resolve the SQL text for `query`: either the positional argument or the
    contents of --file. Reading from a file avoids having the model retype long
    (1000+ line) queries, which is a frequent source of transcription errors."""
    if args.file:
        if args.sql:
            raise ToolError(
                "Pass the SQL either as an argument or with --file, not both.",
                exit_code=2,
            )
        if not os.path.isfile(args.file):
            raise ToolError("SQL file not found: {}".format(args.file), exit_code=2)
        try:
            # utf-8-sig transparently strips a BOM (common on Windows-saved .sql).
            with open(args.file, "r", encoding="utf-8-sig") as f:
                sql = f.read()
        except OSError as e:
            raise ToolError(
                "Cannot read SQL file {}: {}".format(args.file, e), exit_code=2
            )
        if not sql.strip():
            raise ToolError("SQL file is empty: {}".format(args.file), exit_code=2)
        return sql
    if not args.sql:
        raise ToolError(
            "Provide the SQL as an argument or with --file PATH.", exit_code=2
        )
    return args.sql


def cmd_query(conn, args):
    sql = read_query_sql(args)
    binds = {}
    for item in args.bind or []:
        if "=" not in item:
            raise ToolError("Bad --bind format (expected name=value): {}".format(item), exit_code=2)
        name, value = item.split("=", 1)
        binds[name.strip()] = value
    conn["_binds"] = binds or None

    write_mode = args.allow_write
    if write_mode and not args.yes:
        raise ToolError("--allow-write also requires --yes.", exit_code=2)

    if write_mode:
        # DDL/DML path - no result set, no read-only guard, no auto-limit.
        if args.dry_run:
            emit_dry_run(conn, sql, for_write=True)
            return
        run_write_sql(conn, sql)
        return

    enforce_readonly(sql)

    limit = args.limit if args.limit is not None else conn["limit"]
    applied_limit = False
    if not has_own_limit(sql):
        sql = apply_limit(sql, limit)
        applied_limit = True

    if args.dry_run:
        emit_dry_run(conn, sql, for_write=False)
        return

    run_query_sql(conn, sql, args.format, limit, applied_limit)


def emit_dry_run(conn, sql, for_write):
    """Print the exact SQLcl script the tool WOULD run, without connecting to the
    DB. Use it to debug 'works in SQL Developer but not here' cases: it reveals
    whether the SQL text got mangled before reaching the tool (a classic one is a
    PowerShell double-quoted string eating a $ in a dictionary object like V$...,
    or apostrophes in literals). The script never contains the password."""
    script = build_script([sql], binds=conn.get("_binds"), for_write=for_write)
    payload = {"ok": True, "dry_run": True, "sql": sql, "script": script}
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")


def cmd_tables(conn, args):
    like = args.like or "%"
    binds = {"pat": like}
    conn["_binds"] = binds
    sql = (
        "SELECT table_name AS name, 'TABLE' AS type FROM user_tables "
        "WHERE table_name LIKE UPPER(:pat) "
        "UNION ALL "
        "SELECT view_name AS name, 'VIEW' AS type FROM user_views "
        "WHERE view_name LIKE UPPER(:pat) "
        "ORDER BY name"
    )
    run_query_sql(conn, sql, args.format, conn["limit"], False)


def cmd_describe(conn, args):
    table = args.table
    conn["_binds"] = {"tab": table}
    # COMMENTS = per-column business description from USER_COL_COMMENTS. In
    # enterprise Oracle schemas these column comments are the business docs, so
    # we surface them here to give the model context for each column.
    sql = (
        "SELECT c.column_id AS pos, c.column_name AS name, c.data_type AS type, "
        "c.data_length AS length, c.nullable AS nullable, "
        "CASE WHEN pk.column_name IS NOT NULL THEN 'Y' ELSE 'N' END AS pk, "
        "com.comments AS comments "
        "FROM user_tab_columns c "
        "LEFT JOIN ("
        "  SELECT cc.column_name FROM user_constraints uc "
        "  JOIN user_cons_columns cc ON uc.constraint_name = cc.constraint_name "
        "  WHERE uc.constraint_type = 'P' AND uc.table_name = UPPER(:tab)"
        ") pk ON pk.column_name = c.column_name "
        "LEFT JOIN user_col_comments com "
        "  ON com.table_name = c.table_name AND com.column_name = c.column_name "
        "WHERE c.table_name = UPPER(:tab) "
        "ORDER BY c.column_id"
    )
    run_query_sql(conn, sql, args.format, conn["limit"], False)


# -- argparse -----------------------------------------------------------------
def build_parser():
    p = argparse.ArgumentParser(
        prog="dbtool.py",
        description="Query Oracle through SQLcl. Output is always a single JSON "
        "object on stdout. Credentials and environments live in config.ini "
        "(sections [dev]/[prod]).",
        epilog="Binds: use :name in SQL and pass values with --bind name=value "
        "(repeatable). Read-only by default; writes need --allow-write --yes.",
    )
    p.add_argument("--env", help="Environment name from config.ini (default: [DEFAULT] env / DBTOOL_ENV).")
    p.add_argument("--format", choices=["json", "tsv"], default="json", help="Output format (default: json).")

    # The same flags on subcommands (SUPPRESS) so they also work AFTER the
    # subcommand, e.g. `dbtool.py tables --format tsv` - the natural LLM form.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--env", default=argparse.SUPPRESS, help="Same as above, but after the subcommand.")
    common.add_argument("--format", choices=["json", "tsv"], default=argparse.SUPPRESS, help="Same as above, but after the subcommand.")

    sub = p.add_subparsers(dest="command", required=True)

    sp = sub.add_parser("ping", parents=[common], help="Check the connection, return the DB version.")
    sp.set_defaults(func=cmd_ping)

    sq = sub.add_parser("query", parents=[common], help="Run a SELECT/WITH (read-only by default).")
    sq.add_argument("sql", nargs="?", help="Query text. Use :name binds instead of string concatenation. Omit when using --file.")
    sq.add_argument("--file", "-f", metavar="PATH", help="Read the SQL from a file instead of the argument (handy for long queries). Binds still come from --bind.")
    sq.add_argument("--bind", action="append", metavar="NAME=VALUE", help="Value for the :NAME bind. Repeatable.")
    sq.add_argument("--limit", type=int, help="Row limit (default: from config.ini / 200).")
    sq.add_argument("--allow-write", action="store_true", help="Allow non-SELECT (requires --yes).")
    sq.add_argument("--yes", action="store_true", help="Confirmation for --allow-write.")
    sq.add_argument("--dry-run", action="store_true", help="Print the exact SQL/script the tool would send (no DB call). Use to debug mangled SQL, e.g. shell quoting.")
    sq.set_defaults(func=cmd_query)

    st = sub.add_parser("tables", parents=[common], help="List tables and views of the current schema.")
    st.add_argument("--like", help="SQL LIKE pattern (e.g. 'EMP%%'). Default: all.")
    st.set_defaults(func=cmd_tables)

    sd = sub.add_parser("describe", parents=[common], help="Columns, types, nullability, primary key of a table.")
    sd.add_argument("table", help="Table/view name.")
    sd.set_defaults(func=cmd_describe)

    return p


def main(argv=None):
    # Force UTF-8 on output - on Windows Python writes in the console encoding
    # (e.g. cp1250) by default, which would corrupt non-ASCII characters in the
    # JSON read by the agent.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass

    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        ensure_config()
        conn = load_connection(args.env)
        args.func(conn, args)
        return 0
    except ToolError as e:
        emit_error(e)
        return e.exit_code
    except BrokenPipeError:
        return 1
    except Exception as e:  # last line of defense - always emit JSON
        emit_error(ToolError("Unexpected error: {}".format(e), exit_code=1))
        return 1


if __name__ == "__main__":
    sys.exit(main())


# -- KNOWN PITFALLS -----------------------------------------------------------
# 1. Missing semicolon = hang. SQLcl waits for the rest of a statement without
#    ';'. build_script() appends ';' automatically, but any multi-line inserts
#    of your own must include it too.
# 2. Banner before the JSON. SQLcl may print warnings/version before the JSON -
#    that is why parse_json_output cuts from the first '{' to the last '}'
#    instead of trusting "clean" stdout.
# 3. Number locale breaks JSON. With a comma-decimal locale, 3.14 serializes as
#    "3,14" (invalid JSON). We force NLS_NUMERIC_CHARACTERS='.,' in the session.
# 4. Password in argv. Deliberate choice (internal tool) - it is visible in the
#    process list for the brief life of sql.exe. We mask it in echoes/logs/errors.
# 5. Binds are VARCHAR2. All --bind values go in as VARCHAR2(4000). For numeric/
#    date comparisons Oracle does an implicit conversion; when you need a strict
#    type, cast in SQL (e.g. TO_DATE(:d,'YYYY-MM-DD')).
# 6. q'{...}' and the '}' char. Bind values are quoted with q'{...}', so a '}'
#    inside the value is dropped (delimiter collision). Rare, but worth knowing.
# 7. FETCH FIRST vs ROWNUM. Auto-limit appends FETCH FIRST n ROWS ONLY at the
#    end. If the query already uses ROWNUM/OFFSET/FETCH, no limit is added.
# 8. Current schema. tables/describe look at USER_* (the current user's schema
#    from config). To see other schemas, log in as that schema or query
#    ALL_TAB_COLUMNS with an OWNER filter.
# 9. Timeout kills the tree. sql.exe spawns java.exe; on timeout we taskkill /T
#    the whole tree so no orphaned query keeps running.
# 10. Shell mangles inline SQL. The shell rewrites the query BEFORE argparse sees
#     it. In PowerShell a double-quoted "$name" is interpolated, so v$version ->
#     v (spurious ORA-00942). Single quotes stop $ but break on '...' literals.
#     Use --file for non-trivial SQL (bypasses shell quoting); use query --dry-run
#     to print the exact text the tool received without hitting the DB.

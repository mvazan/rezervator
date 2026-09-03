#!/usr/bin/env python3
"""Import kuželky matches from the JM "Obsazenost kuželen" workbook.

Reads the alley-occupancy calendar (sheet "Kalendář vše", or "Kalendář
JM+Zlín" when the full one is missing): one row per alley, one column per
date, each cell holding one or more matches as

    18:30 JM divize
    Brno IV – Dubňany
    16:30 KP2 Sever A
    Brno IV B – Husovice E

Every match in OUR alley's row (--alley, "Brno IV Sokol") is a home match:
it blocks the alley (cancelled reservations exactly as when entered in the
app; the úklid before a match is left to the admin — --prep 0 unless told
otherwise). In every other row a match is taken only when one of
OUR teams (--teams) plays in it, and it is imported as "venkovní zápas" —
listed in the day header, blocks nothing.

Match length differs per competition (KP2 is the shortest, KP1 medium,
divize and the leagues the longest) and the sheet has no end times, so
it is read off the double-match cells: when two matches share a cell, the
gap between their start times is how long the first one lasts. The most
common gap per competition over every alley in the sheet is used; gaps
longer than --max-gap are idle time (a morning and an evening match), not
a duration, and a competition with no usable observation gets --duration.
`--length "KP1 Sever=240"` pins a competition by hand.

The output is a SQL file that runs as the alley's admin (RLS, triggers and
cancellations as in the app). Re-running is safe: every row carries an
import_key (date + teams) and is never inserted twice; matches edited in
the app keep their edits.

Temporary tool for the 2026/27 workbook — the federation format changes
later and the import will then be built into the app.

    python3 tool/import_matches.py ~/Downloads/Obsazenost-kuzelen-2026-27.xlsx
    python3 tool/import_matches.py ... --apply          # writes to PROD
    python3 tool/import_matches.py ... --apply --local  # on the local stack

A prod run first prints a read-only preflight (which alley and admin the
import resolves to, how many matches are already imported, how many live
reservations could be cancelled) and asks for confirmation; --yes skips the
question for an unattended run.
"""
import argparse
import datetime as dt
import re
import subprocess
import sys
import zipfile
from collections import Counter
from typing import Dict, List, Optional, Tuple
from xml.etree import ElementTree as ET

NS = {'m': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
M = '{%s}' % NS['m']
REL = '{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id'

WEEKDAYS = ['po', 'út', 'st', 'čt', 'pá', 'so', 'ne']
LOCAL_DB_URL = 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'
TIME_LINE = re.compile(r'^\s*(\d{1,2}:\d{2}|\?{2,})\s+(.+?)\s*$')
TEAMS_LINE = re.compile(r'^\s*(.+?)\s+[–-]\s+(.+?)\s*$')
DATE_HEAD = re.compile(r'^\s*(\d{1,2})\.(\d{1,2})\.\s*$')


# --- workbook -------------------------------------------------------------

def load_workbook(path: str) -> Dict[str, Dict[Tuple[int, int], str]]:
    """Sheet name -> {(row, col): text} for every non-empty cell (stdlib only)."""
    z = zipfile.ZipFile(path)
    shared: List[str] = []
    if 'xl/sharedStrings.xml' in z.namelist():
        root = ET.fromstring(z.read('xl/sharedStrings.xml'))
        for si in root.findall('m:si', NS):
            shared.append(''.join(t.text or '' for t in si.iter(M + 't')))
    rels = ET.fromstring(z.read('xl/_rels/workbook.xml.rels'))
    target_of = {r.attrib['Id']: r.attrib['Target'] for r in rels}
    sheets: Dict[str, Dict[Tuple[int, int], str]] = {}
    wb = ET.fromstring(z.read('xl/workbook.xml'))
    for s in wb.find('m:sheets', NS):
        target = target_of[s.attrib[REL]]
        member = target[1:] if target.startswith('/') else 'xl/' + target
        root = ET.fromstring(z.read(member))
        cells: Dict[Tuple[int, int], str] = {}
        for c in root.iter(M + 'c'):
            kind = c.attrib.get('t')
            v = c.find('m:v', NS)
            if kind == 's' and v is not None:
                val = shared[int(v.text)]
            elif kind == 'inlineStr':
                val = ''.join(t.text or '' for t in c.iter(M + 't'))
            elif v is not None:
                val = v.text or ''
            else:
                val = ''
            if val.strip():
                cells[cell_ref(c.attrib['r'])] = val
        sheets[s.attrib['name']] = cells
    return sheets


def cell_ref(ref: str) -> Tuple[int, int]:
    m = re.match(r'([A-Z]+)(\d+)', ref)
    col = 0
    for ch in m.group(1):
        col = col * 26 + ord(ch) - 64
    return int(m.group(2)), col


# --- parsing --------------------------------------------------------------

class Match:
    def __init__(self, alley, date, weekday, time, competition, home, away):
        self.alley = alley
        self.date = date            # dt.date
        self.weekday = weekday      # sheet's weekday label
        self.time = time            # 'HH:MM' or None (unknown)
        self.competition = competition
        self.home = home
        self.away = away
        self.is_away = False        # set by classify()
        self.duration = 0           # minutes, set by assign_durations()
        self.warnings: List[str] = []

    @property
    def label(self) -> str:
        return '%s – %s' % (self.home, self.away)

    @property
    def import_key(self) -> str:
        return 'xlsx:%s:%s' % (self.date.isoformat(), self.label)


def season_date(dd: int, mm: int, season: int) -> dt.date:
    """'dd.mm.' in a season running Jul→Jun: autumn = season, spring = +1."""
    return dt.date(season if mm >= 7 else season + 1, mm, dd)


def minutes(hhmm: str) -> int:
    h, mi = map(int, hhmm.split(':'))
    return h * 60 + mi


def parse_calendar(cells, season: int, warnings: List[str],
                   gaps: Dict[str, List[int]]) -> List[Match]:
    """Matches of every alley; [gaps] collects, per competition, how long a
    match lasted when another one followed it in the same cell."""
    rows: Dict[int, Dict[int, str]] = {}
    for (r, c), v in cells.items():
        rows.setdefault(r, {})[c] = v
    dates: Dict[int, dt.date] = {}
    for c, v in rows.get(2, {}).items():
        m = DATE_HEAD.match(v)
        if m:
            dates[c] = season_date(int(m.group(1)), int(m.group(2)), season)
    weekday_of = rows.get(3, {})
    matches: List[Match] = []
    for r in sorted(rows):
        if r < 4 or 1 not in rows[r]:
            continue
        alley = rows[r][1].strip()
        for c, text in sorted(rows[r].items()):
            if c == 1 or c not in dates:
                continue
            date = dates[c]
            label = weekday_of.get(c, '').strip().lower()
            if label in WEEKDAYS and WEEKDAYS.index(label) != date.weekday():
                warnings.append('%s %s: sheet says %s but %s is a %s — wrong --season?'
                                % (alley, date, label, date, WEEKDAYS[date.weekday()]))
            header: Optional[Tuple[Optional[str], str]] = None
            last_match: Optional[Match] = None
            for line in text.splitlines():
                if not line.strip():
                    continue
                tm = TIME_LINE.match(line)
                if tm and not TEAMS_LINE.match(line):
                    if header is not None:
                        warnings.append('%s %s: header without teams: %r' % (alley, date, header))
                    time = None if tm.group(1).startswith('?') else tm.group(1).zfill(5)
                    header = (time, tm.group(2).strip())
                    if last_match is not None and last_match.time and time:
                        gap = minutes(time) - minutes(last_match.time)
                        if gap > 0:
                            gaps.setdefault(last_match.competition, []).append(gap)
                    continue
                teams = TEAMS_LINE.match(line)
                if teams:
                    if header is None:
                        warnings.append('%s %s: teams without a time line: %r' % (alley, date, line))
                        header = (None, '')
                    last_match = Match(alley, date, label, header[0], header[1],
                                       teams.group(1).strip(), teams.group(2).strip())
                    matches.append(last_match)
                    header = None
                    continue
                warnings.append('%s %s: unrecognised line %r' % (alley, date, line))
            if header is not None:
                warnings.append('%s %s: header without teams: %r' % (alley, date, header))
    return matches


def parse_flat_list(cells) -> Counter:
    """(alley, date, time) counter from the hidden 'Utkání – vše' sheet — a
    second, independently laid-out copy of the calendar to cross-check."""
    rows: Dict[int, Dict[int, str]] = {}
    for (r, c), v in cells.items():
        rows.setdefault(r, {})[c] = v
    counter: Counter = Counter()
    for r, row in rows.items():
        if r < 4 or 8 not in row or not row.get(2, '').isdigit():
            continue
        date = dt.date(1899, 12, 30) + dt.timedelta(days=int(row[2]))
        time = row.get(4, '').strip()
        time = None if time.startswith('?') else time.zfill(5)
        counter[(row[1].strip(), date, time, row[7].strip(), row[8].strip())] += 1
    return counter


def ours(name: str, teams: List[str]) -> bool:
    low = name.lower()
    return any(t.lower() in low for t in teams)


def classify(matches: List[Match], alley: str, teams: List[str]) -> List[Match]:
    picked: List[Match] = []
    for m in matches:
        if m.alley == alley:
            m.is_away = False
            if not ours(m.home, teams):
                m.warnings.append('cizí zápas na naší kuželně (blokuje dráhy, kontroluj)')
            picked.append(m)
        elif ours(m.home, teams) or ours(m.away, teams):
            m.is_away = True
            if ours(m.home, teams):
                m.warnings.append('náš tým jako domácí na cizí kuželně — bráno jako venkovní')
            picked.append(m)
    picked.sort(key=lambda x: (x.date, x.time or '', x.alley, x.label))
    return picked


def mode_gap(seen: List[int], max_gap: int) -> Optional[Tuple[int, int]]:
    """(most common gap up to max_gap — ties go to the longer one, usable
    observations) or None."""
    usable = [g for g in seen if g <= max_gap]
    if not usable:
        return None
    best = max(Counter(usable).items(), key=lambda kv: (kv[1], kv[0]))
    return best[0], len(usable)


def assign_durations(matches: List[Match], gaps: Dict[str, List[int]],
                     fallback: int, max_gap: int,
                     overrides: Dict[str, int]) -> Dict[str, int]:
    """--length override → most common observed gap of the competition →
    default; returns {competition: minutes} for the report."""
    chosen: Dict[str, int] = {}
    for m in matches:
        if m.competition not in chosen:
            observed = mode_gap(gaps.get(m.competition, []), max_gap)
            chosen[m.competition] = overrides.get(
                m.competition, observed[0] if observed else fallback)
        m.duration = chosen[m.competition]
    return chosen


def histogram(seen: List[int], max_gap: int) -> Tuple[str, str]:
    counts = Counter(seen)
    used = ', '.join('%d×%s' % (c, fmt_minutes(g)) for g, c in sorted(counts.items()) if g <= max_gap)
    idle = ', '.join('%d×%s' % (c, fmt_minutes(g)) for g, c in sorted(counts.items()) if g > max_gap)
    return used, idle


# --- output ---------------------------------------------------------------

def add_minutes(hhmm: str, minutes: int) -> Tuple[str, bool]:
    h, mi = map(int, hhmm.split(':'))
    total = h * 60 + mi + minutes
    if total >= 24 * 60:
        return '23:59', True
    return '%02d:%02d' % divmod(total, 60), False


def fmt_minutes(mins: int) -> str:
    return '%d:%02d h' % divmod(mins, 60)


def sql_str(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def tenant_lookup(tenant: str, tenant_id: Optional[str]) -> Tuple[str, str]:
    """(SQL selecting the alley's id, human label) — by id when given (the
    alley can be renamed), else by exact name."""
    if tenant_id:
        return ("(select id::text from tenants where id = %s)" % sql_str(tenant_id),
                'kuželna id %s' % tenant_id)
    return ("(select id::text from tenants where name = %s)" % sql_str(tenant),
            'kuželna „%s“' % tenant)


def preflight_sql(tenant: str, tenant_id: Optional[str],
                  import_keys: List[str]) -> str:
    """Read-only: what the import would write into, and what it may disturb."""
    lookup, _ = tenant_lookup(tenant, tenant_id)
    keys = ', '.join(sql_str(k) for k in import_keys)
    return '\n'.join([
        "with t as (select %s::uuid as id)" % lookup,
        "select",
        "  coalesce((select name from tenants where id = (select id from t)),",
        "           '!! NENALEZENO !!') as kuzelna,",
        "  coalesce((select display_name from profiles"
        "     where tenant_id = (select id from t) and role = 'admin'"
        "       and status = 'approved' and not placeholder"
        "     order by created_at limit 1), '!! ŽÁDNÝ SPRÁVCE !!') as zapise_jako,",
        "  (select count(*) from priority_slot_types"
        "     where tenant_id = (select id from t) and is_match and builtin)"
        "     as typ_zapas,",
        "  (select count(*) from priority_slots"
        "     where tenant_id = (select id from t) and import_key in (%s))" % keys,
        "     as jiz_naimportovano,",
        "  (select count(*) from reservations r"
        "     where r.tenant_id = (select id from t) and r.cancelled_at is null"
        "       and r.date >= current_date) as zive_rezervace;",
        '',
    ])


def build_sql(matches: List[Match], tenant: str, tenant_id: Optional[str],
              prep: int, source: str) -> str:
    values = []
    for m in matches:
        end, clamped = add_minutes(m.time, m.duration)
        values.append('  (%s, %s, %s, %s, %s, %d, %s, %s, %s)' % (
            sql_str(m.date.isoformat()), sql_str(m.time), sql_str(end),
            sql_str(m.home), sql_str(m.away), 0 if m.is_away else prep,
            sql_str(m.competition), 'true' if m.is_away else 'false',
            sql_str(m.import_key)))
    home = sum(1 for m in matches if not m.is_away)
    return '\n'.join([
        '-- Generated by tool/import_matches.py from %s on %s: %d home + %d away matches.'
        % (source, dt.date.today().isoformat(), home, len(matches) - home),
        "-- Runs as the alley's admin (RLS and cancelled reservations as in the app).",
        '-- Safe to re-run: rows are keyed by import_key and never inserted twice.',
        'begin;',
        "select set_config('import.tenant', coalesce(%s, ''), true);"
        % tenant_lookup(tenant, tenant_id)[0],
        "select set_config('import.admin', coalesce((select id::text from profiles where tenant_id = nullif(current_setting('import.tenant'), '')::uuid and role = 'admin' and status = 'approved' and not placeholder order by created_at limit 1), ''), true);",
        "select set_config('import.type', coalesce((select id::text from priority_slot_types where tenant_id = nullif(current_setting('import.tenant'), '')::uuid and is_match and builtin), ''), true);",
        'do $$ begin',
        "  if current_setting('import.tenant') = '' then raise exception 'kuželna %s nenalezena', %s; end if;"
        % ('%', sql_str(tenant_lookup(tenant, tenant_id)[1])),
        "  if current_setting('import.admin') = '' then raise exception 'no approved admin in the tenant'; end if;",
        "  if current_setting('import.type') = '' then raise exception 'builtin match type missing'; end if;",
        'end $$;',
        '-- From here on exactly what the app does when the admin saves a match.',
        'set local role authenticated;',
        "select set_config('request.jwt.claims', json_build_object('sub', current_setting('import.admin'), 'role', 'authenticated')::text, true);",
        'insert into priority_slots',
        '  (date, starts_at, ends_at, type_id, home_team, away_team, prep_minutes, description, is_away, created_by, import_key)',
        "select v.date::date, v.starts_at::time, v.ends_at::time, current_setting('import.type')::uuid,",
        "       v.home_team, v.away_team, v.prep_minutes, v.description, v.is_away,",
        "       current_setting('import.admin')::uuid, v.import_key",
        'from (values',
        ',\n'.join(values),
        ') as v(date, starts_at, ends_at, home_team, away_team, prep_minutes, description, is_away, import_key)',
        'on conflict (tenant_id, import_key) do nothing',
        "returning date, starts_at, case when is_away then 'venku' else 'doma' end as kde, home_team || ' – ' || away_team as zapas;",
        'commit;',
        '',
    ])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('workbook')
    ap.add_argument('--tenant', default='TJ Sokol Brno IV', help='tenants.name in the database')
    ap.add_argument('--tenant-id', help="the alley's uuid — beats --tenant (a renamed alley still matches)")
    ap.add_argument('--alley', default='Brno IV Sokol', help="our alley's row label in the sheet")
    ap.add_argument('--teams', nargs='+', default=['Husovice', 'Veverky', 'Devítka', 'Brno IV'],
                    help='substrings identifying our teams')
    ap.add_argument('--season', type=int, help='autumn year of the season (default: from the file name)')
    ap.add_argument('--duration', type=int, default=180,
                    help='match length in minutes for competitions without a usable double-match observation')
    ap.add_argument('--max-gap', type=int, default=270,
                    help='longest plausible match in minutes; a bigger gap between two matches in a cell is idle time')
    ap.add_argument('--length', action='append', default=[], metavar='SOUTĚŽ=MIN',
                    help='pin a competition\'s match length by hand, e.g. --length "KP1 Sever=240" (repeatable)')
    ap.add_argument('--prep', type=int, default=0,
                    help='úklid před zápasem in minutes for home matches (default 0: the admin adds it in the app)')
    ap.add_argument('--out', default='build/import_matches.sql')
    ap.add_argument('--apply', action='store_true', help='run the SQL — against PROD unless --local')
    ap.add_argument('--yes', action='store_true', help='with --apply: skip the confirmation question')
    ap.add_argument('--local', action='store_true', help='with --apply: the local stack (psql) instead of prod')
    args = ap.parse_args()

    season = args.season
    if season is None:
        m = re.search(r'(20\d\d)', args.workbook)
        today = dt.date.today()
        season = int(m.group(1)) if m else (today.year if today.month >= 7 else today.year - 1)

    sheets = load_workbook(args.workbook)
    calendar = next((n for n in ('Kalendář vše', 'Kalendář JM+Zlín') if n in sheets), None)
    if calendar is None:
        print('no calendar sheet found; sheets:', ', '.join(sheets), file=sys.stderr)
        return 2
    overrides: Dict[str, int] = {}
    for item in args.length:
        name, _, mins = item.rpartition('=')
        if not name or not mins.isdigit():
            print('--length expects SOUTĚŽ=MINUTES, got %r' % item, file=sys.stderr)
            return 2
        overrides[name.strip()] = int(mins)

    warnings: List[str] = []
    gaps: Dict[str, List[int]] = {}
    all_matches = parse_calendar(sheets[calendar], season, warnings, gaps)
    if not any(m.alley == args.alley for m in all_matches):
        print('alley %r not found in %s; rows: %s' % (
            args.alley, calendar, ', '.join(sorted({m.alley for m in all_matches}))), file=sys.stderr)
        return 2
    matches = classify(all_matches, args.alley, args.teams)
    durations = assign_durations(matches, gaps, args.duration, args.max_gap, overrides)

    # Cross-check with the hidden flat list, laid out independently.
    if 'Utkání – vše' in sheets:
        flat = parse_flat_list(sheets['Utkání – vše'])
        flat_ours = Counter({k: n for k, n in flat.items()
                             if k[0] == args.alley or ours(k[3], args.teams) or ours(k[4], args.teams)})
        grid = Counter((m.alley, m.date, m.time) for m in matches)
        flat_slots = Counter((k[0], k[1], k[2]) for k, n in flat_ours.items() for _ in range(n))
        diff = (grid - flat_slots) + (flat_slots - grid)
        if diff:
            for (alley, date, time), n in sorted(diff.items(), key=lambda x: (x[0][1], x[0][0])):
                where = 'calendar only' if grid[(alley, date, time)] > flat_slots[(alley, date, time)] else 'flat list only'
                warnings.append('cross-check: %s %s %s — %s' % (alley, date, time or '??:??', where))
        else:
            print('cross-check with "Utkání – vše": OK (%d matches agree)' % len(matches))

    unknown = [m for m in matches if m.time is None]
    matches = [m for m in matches if m.time is not None]

    print('season %d/%d, sheet %r, tenant %r' % (season, season + 1, calendar, args.tenant))
    print('%d matches: %d home at %s, %d away' % (
        len(matches), sum(1 for m in matches if not m.is_away), args.alley,
        sum(1 for m in matches if m.is_away)))
    print('match length per competition from double-match cells (gaps over %s count as idle time; default %s):'
          % (fmt_minutes(args.max_gap), fmt_minutes(args.duration)))
    for comp in sorted(durations):
        used, idle = histogram(gaps.get(comp, []), args.max_gap)
        note = ('pinned by --length' if comp in overrides
                else ('observed: ' + used) if used else 'no usable observation → default')
        if idle:
            note += '; ignored as idle time: ' + idle
        print('  %-14s %s  (%s)' % (comp, fmt_minutes(durations[comp]), note))
    print()
    for m in matches:
        end, clamped = add_minutes(m.time, m.duration)
        flags = ' | '.join(m.warnings + (['end clamped to 23:59'] if clamped else []))
        print('%s %s %s–%s %-5s %-38s %-14s %s%s' % (
            WEEKDAYS[m.date.weekday()], m.date.strftime('%d.%m.%Y'), m.time, end,
            'venku' if m.is_away else 'doma', m.label, m.competition,
            '' if m.is_away is False else '@ ' + m.alley, ('  !! ' + flags) if flags else ''))
    if unknown:
        print('\nSKIPPED (time unknown in the sheet — add by hand once known):')
        for m in unknown:
            print('  %s %s %s %s @ %s' % (WEEKDAYS[m.date.weekday()], m.date, m.label, m.competition, m.alley))
    if warnings:
        print('\nWARNINGS:')
        for w in warnings:
            print('  ' + w)

    sql = build_sql(matches, args.tenant, args.tenant_id, args.prep,
                    args.workbook.split('/')[-1])
    import os
    os.makedirs(os.path.dirname(args.out) or '.', exist_ok=True)
    with open(args.out, 'w', encoding='utf-8') as f:
        f.write(sql)
    print('\nSQL written to %s' % args.out)
    if not args.apply:
        print('do PRODUKCE:  python3 %s <sešit> --apply' % sys.argv[0])
        print('   nebo SQL:  supabase db query --linked -f %s' % args.out)
        print('   lokálně:  psql %s -X -v ON_ERROR_STOP=1 -f %s' % (LOCAL_DB_URL, args.out))
        return 0

    if args.local:
        # The CLI's --local path sends the file as one prepared statement and
        # rejects a multi-statement transaction; psql handles it.
        cmd = ['psql', LOCAL_DB_URL, '-X', '-v', 'ON_ERROR_STOP=1', '-f', args.out]
        print('running: ' + ' '.join(cmd))
        return subprocess.call(cmd)

    # PROD. Say out loud what the import resolves to before writing: a wrong
    # alley name or a missing admin would otherwise only show up as an
    # exception mid-transaction, and cancelled reservations mail players.
    import os
    import tempfile
    keys = [m.import_key for m in matches]
    with tempfile.NamedTemporaryFile('w', suffix='.sql', delete=False,
                                     encoding='utf-8') as f:
        f.write(preflight_sql(args.tenant, args.tenant_id, keys))
        probe = f.name
    try:
        print('\nPRODUKCE — kontrola cíle:')
        rc = subprocess.call(['supabase', 'db', 'query', '--linked', '-f', probe])
    finally:
        os.unlink(probe)
    if rc != 0:
        print('kontrola cíle selhala — nic se nezapisovalo', file=sys.stderr)
        return rc
    print('\nZapíše se %d zápasů (%d doma, %d venku). Domácí zápasy ruší '
          'kolidující rezervace a hráčům odejde upozornění.'
          % (len(matches), sum(1 for m in matches if not m.is_away),
             sum(1 for m in matches if m.is_away)))
    if not args.yes:
        try:
            answer = input('Napiš "ano" pro zápis do produkce: ').strip().lower()
        except EOFError:
            answer = ''
        if answer != 'ano':
            print('nic se nezapisovalo')
            return 1
    cmd = ['supabase', 'db', 'query', '--linked', '-f', args.out]
    print('running: ' + ' '.join(cmd))
    return subprocess.call(cmd)


if __name__ == '__main__':
    sys.exit(main())

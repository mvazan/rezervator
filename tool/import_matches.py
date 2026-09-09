#!/usr/bin/env python3
"""Import kuželky matches from the federation's schedule (rozpis).

The schedule is a flat list — one row per match — with these columns (the
header row is found by name, its position does not matter):

    Kuželna | Datum | Den | Čas | Soutěž | Kolo | Domácí | Hosté | Rozhodčí

Both .xls (the BIFF8 workbook Excel still writes) and .xlsx are read with
the standard library alone.

Every row played at OUR alley (--alley, "Brno IV Sokol") is a home match:
it blocks the alley (cancelled reservations exactly as when entered in the
app, plus --prep minutes of úklid before it — 30 by default). Any other row
is taken only when one of OUR teams (--teams) plays in it, and becomes a
"venkovní zápas" — listed in the day header, blocks nothing; the row's
Kuželna is its venue. Match length is fixed per competition tier (the
file has no end times): KP2 = 90 min, KP1 = 150 min, dorost = 90 min,
everything else (divize, the leagues) = --duration (180 min); `--length
"KP1 Sever=240"` pins one competition by its exact name.

RECONCILE, NOT REPLACE. The schedule gets revised during the season, so
the import compares the file with what is in the database and changes
only what differs — a match the federation moved is an UPDATE of its row
(same uuid, so every follower's Google Calendar event is rewritten in
place instead of deleted and re-created). Identity is the import_key

    rozpis:<Soutěž>:<Kolo>:<Domácí> – <Hosté>

with no date in it. Rows keyed by the 2026/27 grid workbook
(`xlsx:<date>:<teams>`) are re-keyed by the first run: by competition +
pairing, then — for an opponent the federation renamed — by date + time +
venue + one team in common; a legacy row nothing pairs with is a match the
schedule dropped, and is deleted.

WHAT THE IMPORT NEVER TOUCHES: a match without an import_key (the admin
entered it by hand — a friendly, a cup tie), a match flagged hand_edited
(the admin corrected an imported row in the app; 0038 — listed as "skip",
overwritten only with --force, which also clears the flag), and every
user table: who follows which team (profiles.followed_teams,
calendar_teams, team_colors) are NAMES, so before writing the import lists
followed teams that no longer occur in the file and refuses to write while
any exist (--allow-missing-teams overrides — a team that withdrew).

    python3 tool/import_matches.py ~/Downloads/rozpis.xls            # náhled
    python3 tool/import_matches.py ~/Downloads/rozpis.xls --apply    # PROD
    python3 tool/import_matches.py ~/Downloads/rozpis.xls --apply --local

The default run parses the file, prints the matches it found, and shows
the PREVIEW: one read-only query against the database (prod, or the local
stack with --local) that lists every planned action — rekey / rename /
update (with what changes) / insert / delete / skip — plus the followed
teams missing from the file. --apply shows the same preview, asks for a
typed "ano" (--yes skips it), then runs the write as ONE transaction as
the alley's admin (RLS, triggers and cancellations as in the app): the
transaction re-computes the very same plan and executes it, so what you
approved is what happens. --no-preview just writes the SQL files.
"""
import argparse
import datetime as dt
import os
import re
import struct
import subprocess
import sys
import tempfile
import zipfile
from typing import Dict, List, Optional, Tuple
from xml.etree import ElementTree as ET

NS = {'m': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
M = '{%s}' % NS['m']
REL = '{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id'

WEEKDAYS = ['po', 'út', 'st', 'čt', 'pá', 'so', 'ne']
LOCAL_DB_URL = 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'
KEY_PREFIX = 'rozpis:'
LEGACY_PREFIX = 'xlsx:'
HEADER_COLUMNS = ('Kuželna', 'Datum', 'Čas', 'Soutěž', 'Kolo', 'Domácí', 'Hosté')
EXCEL_EPOCH = dt.datetime(1899, 12, 30)

# Fixed by competition tier (substring of the competition name, case
# insensitive) — the file has no end times. Told by hand for 2026/27.
TIER_DURATIONS = [('KP2', 90), ('KP1', 150), ('dorost', 90)]


# --- workbook: .xlsx --------------------------------------------------------

Cells = Dict[Tuple[int, int], object]


def load_workbook_xlsx(path: str) -> Dict[str, Cells]:
    """Sheet name -> {(row, col): text} for every non-empty cell."""
    z = zipfile.ZipFile(path)
    shared: List[str] = []
    if 'xl/sharedStrings.xml' in z.namelist():
        root = ET.fromstring(z.read('xl/sharedStrings.xml'))
        for si in root.findall('m:si', NS):
            shared.append(''.join(t.text or '' for t in si.iter(M + 't')))
    rels = ET.fromstring(z.read('xl/_rels/workbook.xml.rels'))
    target_of = {r.attrib['Id']: r.attrib['Target'] for r in rels}
    sheets: Dict[str, Cells] = {}
    wb = ET.fromstring(z.read('xl/workbook.xml'))
    for s in wb.find('m:sheets', NS):
        target = target_of[s.attrib[REL]]
        member = target[1:] if target.startswith('/') else 'xl/' + target
        root = ET.fromstring(z.read(member))
        cells: Cells = {}
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


# --- workbook: .xls (BIFF8 inside an OLE2 compound file) ---------------------

def _ole_stream(data: bytes, wanted: Tuple[str, ...]) -> bytes:
    """The bytes of the first directory entry named in [wanted]."""
    if data[:8] != b'\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1':
        raise ValueError('not an OLE2 file')
    ssz = 1 << struct.unpack_from('<H', data, 0x1E)[0]
    mssz = 1 << struct.unpack_from('<H', data, 0x20)[0]
    nfat = struct.unpack_from('<I', data, 0x2C)[0]
    dir_start = struct.unpack_from('<I', data, 0x30)[0]
    mini_cutoff = struct.unpack_from('<I', data, 0x38)[0]
    minifat_start = struct.unpack_from('<I', data, 0x3C)[0]
    difat_start = struct.unpack_from('<I', data, 0x44)[0]
    ndifat = struct.unpack_from('<I', data, 0x48)[0]
    per_sector = ssz // 4

    def sector(n: int) -> bytes:
        off = (n + 1) * ssz
        return data[off:off + ssz]

    difat = list(struct.unpack_from('<109I', data, 0x4C))
    s = difat_start
    for _ in range(ndifat):
        entries = struct.unpack('<%dI' % per_sector, sector(s))
        difat += entries[:-1]
        s = entries[-1]
    fat: List[int] = []
    for sid in difat[:nfat]:
        fat += struct.unpack('<%dI' % per_sector, sector(sid))

    def chain(start: int, table: List[int]) -> List[int]:
        out = []
        while start not in (0xFFFFFFFE, 0xFFFFFFFF) and start < len(table):
            out.append(start)
            start = table[start]
        return out

    def read(start: int, size: int) -> bytes:
        return b''.join(sector(s) for s in chain(start, fat))[:size]

    directory = b''.join(sector(s) for s in chain(dir_start, fat))
    entries = []
    for i in range(len(directory) // 128):
        e = directory[i * 128:(i + 1) * 128]
        name_len = struct.unpack_from('<H', e, 0x40)[0]
        entries.append((
            e[:max(name_len - 2, 0)].decode('utf-16le'), e[0x42],
            struct.unpack_from('<I', e, 0x74)[0], struct.unpack_from('<I', e, 0x78)[0]))
    root = entries[0]
    ministream = read(root[2], root[3])
    minifat: List[int] = []
    for sid in chain(minifat_start, fat):
        minifat += struct.unpack('<%dI' % per_sector, sector(sid))
    for name, kind, start, size in entries:
        if kind == 2 and name in wanted:
            if size < mini_cutoff:
                return b''.join(ministream[s * mssz:(s + 1) * mssz]
                                for s in chain(start, minifat))[:size]
            return read(start, size)
    raise ValueError('no %s stream in the workbook' % '/'.join(wanted))


def _biff_records(buf: bytes, pos: int = 0):
    while pos + 4 <= len(buf):
        rid, ln = struct.unpack_from('<HH', buf, pos)
        yield rid, buf[pos + 4:pos + 4 + ln]
        pos += 4 + ln


def _biff_string(buf: bytes, pos: int, len_bytes: int = 2) -> Tuple[str, int]:
    """A BIFF8 unicode string at [pos] → (text, position after it)."""
    if len_bytes == 2:
        n = struct.unpack_from('<H', buf, pos)[0]
    else:
        n = buf[pos]
    pos += len_bytes
    flags = buf[pos]
    pos += 1
    runs = ext = 0
    if flags & 8:
        runs = struct.unpack_from('<H', buf, pos)[0]
        pos += 2
    if flags & 4:
        ext = struct.unpack_from('<I', buf, pos)[0]
        pos += 4
    if flags & 1:
        text = buf[pos:pos + 2 * n].decode('utf-16le')
        pos += 2 * n
    else:
        text = buf[pos:pos + n].decode('latin-1')
        pos += n
    return text, pos + 4 * runs + ext


def _biff_sst(chunks: List[bytes], count: int) -> List[str]:
    """The shared-string table, whose strings may straddle CONTINUE records
    (each continued piece restarts with its own flags byte)."""
    out: List[str] = []
    ci = cp = 0

    def settle():
        nonlocal ci, cp
        while cp >= len(chunks[ci]) and ci + 1 < len(chunks):
            ci += 1
            cp = 0

    for _ in range(count):
        settle()
        n = struct.unpack_from('<H', chunks[ci], cp)[0]
        cp += 2
        settle()
        flags = chunks[ci][cp]
        cp += 1
        wide = flags & 1
        runs = ext = 0
        if flags & 8:
            settle()
            runs = struct.unpack_from('<H', chunks[ci], cp)[0]
            cp += 2
        if flags & 4:
            settle()
            ext = struct.unpack_from('<I', chunks[ci], cp)[0]
            cp += 4
        text = ''
        left = n
        while left > 0:
            settle()
            avail = len(chunks[ci]) - cp
            take = min(left, avail // (2 if wide else 1))
            if take == 0:
                ci += 1
                cp = 0
                wide = chunks[ci][cp] & 1
                cp += 1
                continue
            if wide:
                text += chunks[ci][cp:cp + 2 * take].decode('utf-16le')
                cp += 2 * take
            else:
                text += chunks[ci][cp:cp + take].decode('latin-1')
                cp += take
            left -= take
        skip = 4 * runs + ext
        while skip > 0:
            settle()
            avail = len(chunks[ci]) - cp
            if avail <= 0:
                ci += 1
                cp = 0
                continue
            step = min(skip, avail)
            cp += step
            skip -= step
        out.append(text)
    return out


def _rk_value(v: int) -> float:
    cents = v & 1
    if v & 2:
        n = v >> 2
        if v & 0x80000000:
            n -= 1 << 30
        val = float(n)
    else:
        val = struct.unpack('<d', struct.pack('<Q', (v & 0xFFFFFFFC) << 32))[0]
    return val / 100 if cents else val


def load_workbook_xls(path: str) -> Dict[str, Cells]:
    """Sheet name -> {(row, col): value} — str, float, or datetime for a
    date/time-formatted number (0-based row/col; the header search below
    does not care)."""
    with open(path, 'rb') as f:
        wb = _ole_stream(f.read(), ('Workbook', 'Book'))
    records = list(_biff_records(wb))
    sst: List[str] = []
    sheets: List[Tuple[str, int]] = []
    formats: Dict[int, str] = {}
    xf_formats: List[int] = []
    i = 0
    while i < len(records):
        rid, body = records[i]
        if rid == 0x0085:                                     # BOUNDSHEET
            sheets.append((_biff_string(body, 6, 1)[0], struct.unpack_from('<I', body, 0)[0]))
        elif rid == 0x041E:                                   # FORMAT
            formats[struct.unpack_from('<H', body, 0)[0]] = _biff_string(body, 2)[0]
        elif rid == 0x00E0:                                   # XF
            xf_formats.append(struct.unpack_from('<H', body, 2)[0])
        elif rid == 0x00FC:                                   # SST (+ CONTINUE)
            count = struct.unpack_from('<I', body, 4)[0]
            chunks = [body[8:]]
            j = i + 1
            while j < len(records) and records[j][0] == 0x003C:
                chunks.append(records[j][1])
                j += 1
            sst = _biff_sst(chunks, count)
            i = j
            continue
        i += 1

    builtin_dates = {14, 15, 16, 17, 18, 19, 20, 21, 22, 45, 46, 47}

    def is_date(xf: int) -> bool:
        if xf >= len(xf_formats):
            return False
        fmt = xf_formats[xf]
        if fmt in builtin_dates:
            return True
        text = formats.get(fmt, '')
        return any(ch in text for ch in 'dmyh') and '#' not in text

    def number(xf: int, value: float):
        return EXCEL_EPOCH + dt.timedelta(days=value) if is_date(xf) else value

    out: Dict[str, Cells] = {}
    for name, start in sheets:
        cells: Cells = {}
        for rid, body in _biff_records(wb, start):
            if rid == 0x000A:                                 # EOF
                break
            if rid == 0x00FD:                                 # LABELSST
                r, c, _, idx = struct.unpack_from('<HHHI', body, 0)
                cells[(r, c)] = sst[idx]
            elif rid == 0x0204:                               # LABEL
                r, c, _ = struct.unpack_from('<HHH', body, 0)
                cells[(r, c)] = _biff_string(body, 6)[0]
            elif rid == 0x0203:                               # NUMBER
                r, c, xf = struct.unpack_from('<HHH', body, 0)
                cells[(r, c)] = number(xf, struct.unpack_from('<d', body, 6)[0])
            elif rid == 0x027E:                               # RK
                r, c, xf, v = struct.unpack_from('<HHHI', body, 0)
                cells[(r, c)] = number(xf, _rk_value(v))
            elif rid == 0x00BD:                               # MULRK
                r, c0 = struct.unpack_from('<HH', body, 0)
                for k in range((len(body) - 6) // 6):
                    xf, v = struct.unpack_from('<HI', body, 4 + 6 * k)
                    cells[(r, c0 + k)] = number(xf, _rk_value(v))
            elif rid == 0x0006:                               # FORMULA
                r, c, xf = struct.unpack_from('<HHH', body, 0)
                result = body[6:14]
                if result[6:8] != b'\xff\xff':                # a numeric result
                    cells[(r, c)] = number(xf, struct.unpack('<d', result)[0])
        out[name] = cells
    return out


# --- rows -------------------------------------------------------------------

def read_rows(path: str) -> List[Dict[str, object]]:
    """The schedule as dicts keyed by the header texts, from the first sheet
    whose header row carries every column in HEADER_COLUMNS."""
    sheets = load_workbook_xls(path) if path.lower().endswith('.xls') else load_workbook_xlsx(path)
    for name, cells in sheets.items():
        by_row: Dict[int, Dict[int, object]] = {}
        for (r, c), v in cells.items():
            by_row.setdefault(r, {})[c] = v
        for r in sorted(by_row):
            texts = {str(v).strip(): c for c, v in by_row[r].items() if isinstance(v, str)}
            if all(h in texts for h in HEADER_COLUMNS):
                col_of = {h: texts[h] for h in HEADER_COLUMNS}
                rows = []
                for rr in sorted(by_row):
                    if rr <= r:
                        continue
                    row = {h: by_row[rr].get(c) for h, c in col_of.items()}
                    if any(v not in (None, '') for v in row.values()):
                        rows.append(row)
                return rows
    raise ValueError('no sheet with a header row of %s' % ', '.join(HEADER_COLUMNS))


def text_of(v: object) -> str:
    return '' if v is None else str(v).strip()


def date_of(v: object) -> Optional[dt.date]:
    if isinstance(v, dt.datetime):
        return v.date()
    s = text_of(v)
    m = re.match(r'^(\d{1,2})\.\s*(\d{1,2})\.\s*(\d{4})$', s)
    if m:
        return dt.date(int(m.group(3)), int(m.group(2)), int(m.group(1)))
    m = re.match(r'^(\d{4})-(\d{2})-(\d{2})', s)
    if m:
        return dt.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    if re.match(r'^\d+(\.0+)?$', s):                          # an Excel serial
        return (EXCEL_EPOCH + dt.timedelta(days=int(float(s)))).date()
    return None


def time_of(v: object) -> Optional[str]:
    """'HH:MM', or None for an unknown time ('??', empty)."""
    if isinstance(v, dt.datetime):
        return '%02d:%02d' % (v.hour, v.minute)
    if isinstance(v, float):
        minutes = round((v % 1) * 24 * 60)
        return '%02d:%02d' % divmod(minutes, 60)
    s = text_of(v)
    m = re.match(r'^(\d{1,2}):(\d{2})', s)
    if m:
        return '%02d:%s' % (int(m.group(1)), m.group(2))
    if re.match(r'^0?\.\d+$', s):                             # a fraction of a day
        minutes = round(float(s) * 24 * 60)
        return '%02d:%02d' % divmod(minutes, 60)
    return None


def int_of(v: object) -> Optional[int]:
    s = text_of(v)
    return int(float(s)) if re.match(r'^\d+(\.0+)?$', s) else None


class Match:
    def __init__(self, alley: str, date: dt.date, time: Optional[str],
                 competition: str, round_no: int, home: str, away: str):
        self.alley = alley
        self.date = date
        self.time = time            # 'HH:MM' or None (unknown)
        self.competition = competition
        self.round_no = round_no
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
        return '%s%s:%d:%s' % (KEY_PREFIX, self.competition, self.round_no, self.label)

    @property
    def legacy_key(self) -> str:
        """What the 2026/27 grid importer keyed this match by."""
        return '%s%s:%s' % (LEGACY_PREFIX, self.date.isoformat(), self.label)

    @property
    def description(self) -> str:
        """The competition and round; an away match also names the venue —
        the app has no column for it, and the calendar event (0027) shows
        it from here."""
        base = '%s · %d. kolo' % (self.competition, self.round_no)
        return '%s · %s' % (base, self.alley) if self.is_away else base


def parse_rows(rows: List[Dict[str, object]], warnings: List[str]) -> List[Match]:
    matches: List[Match] = []
    for n, row in enumerate(rows, 1):
        date = date_of(row['Datum'])
        home, away = text_of(row['Domácí']), text_of(row['Hosté'])
        competition = text_of(row['Soutěž'])
        round_no = int_of(row['Kolo'])
        if date is None or not home or not away or not competition or round_no is None:
            warnings.append('řádek %d přeskočen — chybí datum, soutěž, kolo nebo tým: %s'
                            % (n, {k: text_of(v) for k, v in row.items()}))
            continue
        matches.append(Match(text_of(row['Kuželna']), date, time_of(row['Čas']),
                             competition, round_no, home, away))
    return matches


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


def assign_durations(matches: List[Match], fallback: int,
                     overrides: Dict[str, int]) -> Dict[str, int]:
    """--length override → competition tier → fallback; returns
    {competition: minutes} for the report."""
    chosen: Dict[str, int] = {}
    for m in matches:
        if m.competition not in chosen:
            if m.competition in overrides:
                chosen[m.competition] = overrides[m.competition]
            else:
                chosen[m.competition] = next(
                    (mins for needle, mins in TIER_DURATIONS
                     if needle.lower() in m.competition.lower()), fallback)
        m.duration = chosen[m.competition]
    return chosen


# --- SQL --------------------------------------------------------------------

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


ROZPIS_COLUMNS = ('key', 'date', 'starts_at', 'ends_at', 'home', 'away', 'prep',
                  'description', 'is_away', 'competition')


def rozpis_values(matches: List[Match], prep: int) -> str:
    """The VALUES list both the preview and the write build `rozpis` from —
    one typed row per match."""
    rows = []
    for m in matches:
        end, _ = add_minutes(m.time, m.duration)
        rows.append('  (%s, %s, %s, %s, %s, %s, %d, %s, %s, %s)' % (
            sql_str(m.import_key), sql_str(m.date.isoformat()), sql_str(m.time),
            sql_str(end), sql_str(m.home), sql_str(m.away),
            0 if m.is_away else prep, sql_str(m.description),
            'true' if m.is_away else 'false', sql_str(m.competition)))
    return ',\n'.join(rows)


def rozpis_select(values: str) -> str:
    """`rozpis` as a typed relation from the VALUES list."""
    return '\n'.join([
        'select v.key, v.date::date, v.starts_at::time, v.ends_at::time, v.home, v.away,',
        '       v.prep::smallint, v.description, v.is_away::boolean, v.competition',
        'from (values',
        values,
        ') as v(%s)' % ', '.join(ROZPIS_COLUMNS),
    ])


# The plan: what the file means for the rows in the database. ONE query,
# used verbatim by the preview (rozpis = a CTE, read-only) and by the
# write (rozpis = a temp table, the plan materialised and executed), so
# the preview the admin approved is the plan that runs.
#   {tenant} — the alley's uuid expression; {force} — true/false.
PLAN_SELECT = """
with cur as (
  select id, import_key, date, starts_at, ends_at, home_team, away_team,
         prep_minutes, description, is_away, hand_edited
  from priority_slots
  where tenant_id = {tenant} and parent_id is null and import_key is not null),
-- the row already carries the file's key
exact as (
  select c.id, r.key from cur c join rozpis r on r.key = c.import_key),
-- 2026/27 grid keys (xlsx:<date>:<teams>): the same competition and pairing
legacy_exact as (
  select l.id, r.key from cur l join rozpis r
    on split_part(l.description, ' · ', 1) = r.competition
   and l.home_team = r.home and l.away_team = r.away
  where l.import_key like 'xlsx:%'
    and r.key not in (select key from exact)),
-- an opponent the federation renamed: the same slot with one team in common
legacy_rename as (
  select l.id, r.key from cur l join rozpis r
    on l.date = r.date and l.starts_at = r.starts_at and l.is_away = r.is_away
   and (l.home_team = r.home or l.away_team = r.away)
  where l.import_key like 'xlsx:%'
    and l.id not in (select id from legacy_exact)
    and r.key not in (select key from exact union select key from legacy_exact)),
pairs as (
  select id, key, 'exact' as how from exact
  union all select id, key, 'rekey' from legacy_exact
  union all select id, key, 'rename' from legacy_rename),
-- names the players follow (Moje týmy, the calendar picks, colours)
picks as (
  select unnest(p.followed_teams) as team from profiles p where p.tenant_id = {tenant}
  union all
  select t.team from calendar_teams t join profiles p on p.id = t.user_id
   where p.tenant_id = {tenant}
  union all
  select c.team from team_colors c join profiles p on p.id = c.user_id
   where p.tenant_id = {tenant}),
plan as (
  -- a file row paired with a database row
  select p.id, c.import_key as old_key, p.key as new_key, r.date, r.starts_at,
         r.home || ' – ' || r.away as zapas,
         case when c.hand_edited and not {force} then 'skip'
              when p.how <> 'exact' then p.how
              when (c.date, c.starts_at, c.ends_at, c.home_team, c.away_team,
                    c.prep_minutes, c.description, c.is_away)
                   is distinct from
                   (r.date, r.starts_at, r.ends_at, r.home, r.away,
                    r.prep, r.description, r.is_away) then 'update'
              else 'unchanged' end as action,
         concat_ws(', ',
           case when c.hand_edited then 'upraveno ručně' end,
           case when c.date <> r.date then 'datum ' || c.date || ' → ' || r.date end,
           case when c.starts_at <> r.starts_at
                then 'čas ' || to_char(c.starts_at, 'HH24:MI') || ' → ' || to_char(r.starts_at, 'HH24:MI') end,
           case when c.starts_at = r.starts_at and c.ends_at <> r.ends_at
                then 'konec ' || to_char(c.ends_at, 'HH24:MI') || ' → ' || to_char(r.ends_at, 'HH24:MI') end,
           case when (c.home_team, c.away_team) <> (r.home, r.away)
                then 'týmy ' || c.home_team || ' – ' || c.away_team end,
           case when c.is_away <> r.is_away then case when r.is_away then '→ venku' else '→ doma' end end,
           case when c.prep_minutes <> r.prep then 'úklid ' || c.prep_minutes || ' → ' || r.prep end,
           case when c.description <> r.description then 'popis „' || c.description || '“' end) as poznamka
  from pairs p join cur c on c.id = p.id join rozpis r on r.key = p.key
  union all
  -- a file row nothing in the database pairs with
  select null, null, r.key, r.date, r.starts_at, r.home || ' – ' || r.away,
         'insert', case when r.is_away then 'venku' else 'doma' end
  from rozpis r where r.key not in (select key from pairs)
  union all
  -- an imported row the file no longer has
  select c.id, c.import_key, null, c.date, c.starts_at, c.home_team || ' – ' || c.away_team,
         case when c.hand_edited and not {force} then 'skip' else 'delete' end,
         concat_ws(', ', 'v rozpise není', case when c.hand_edited then 'upraveno ručně' end)
  from cur c where c.id not in (select id from pairs)
  union all
  -- a file row or a database row paired more than once: the plan is void
  select null, null, key, null, null, key, 'CONFLICT', 'řádek souboru sedí na víc zápasů'
  from pairs group by key having count(*) > 1
  union all
  select id, null, null, null, null, id::text, 'CONFLICT', 'zápas sedí na víc řádků souboru'
  from pairs group by id having count(*) > 1
  union all
  -- a followed team the file does not know
  select null, null, null, null, null, team, 'missing-team',
         count(*) || '× sledovaný tým, v rozpise není'
  from picks where team not in (select home from rozpis union select away from rozpis)
  group by team)
select * from plan
"""

ACTION_ORDER = ['CONFLICT', 'missing-team', 'skip', 'delete', 'rename', 'rekey',
                'update', 'insert', 'unchanged']


def plan_sql(tenant_expr: str, force: bool) -> str:
    return PLAN_SELECT.format(tenant=tenant_expr, force='true' if force else 'false')


def order_clause() -> str:
    return 'array_position(array[%s]::text[], action), date, starts_at, zapas' % ', '.join(
        sql_str(a) for a in ACTION_ORDER)


def preview_sql(matches: List[Match], tenant: str, tenant_id: Optional[str],
                prep: int, force: bool) -> str:
    """Read-only: the plan, every action but 'unchanged' in full, plus a
    count per action. One statement, so it runs through `supabase db query`
    and psql alike."""
    lookup, _ = tenant_lookup(tenant, tenant_id)
    return '\n'.join([
        'with t as (select %s::uuid as id),' % lookup,
        'rozpis as (',
        rozpis_select(rozpis_values(matches, prep)),
        '),',
        'p as (',
        plan_sql('(select id from t)', force),
        ')',
        'select * from (',
        "  select action, to_char(date, 'DD.MM.YYYY') as datum, to_char(starts_at, 'HH24:MI') as cas,",
        "         zapas, poznamka",
        "  from p where action <> 'unchanged'",
        '  union all',
        "  select 'celkem ' || action, null, null, count(*) || '×', null",
        '  from p group by action',
        ') x',
        "order by (case when action like 'celkem %' then 1 else 0 end),",
        '         array_position(array[%s]::text[], replace(action, \'celkem \', \'\')), datum, cas, zapas;'
        % ', '.join(sql_str(a) for a in ACTION_ORDER),
        '',
    ])


def apply_sql(matches: List[Match], tenant: str, tenant_id: Optional[str],
              prep: int, source: str, force: bool, allow_missing: bool) -> str:
    """The write: one transaction as the alley's admin that materialises
    the same plan and executes it."""
    lookup, label = tenant_lookup(tenant, tenant_id)
    home = sum(1 for m in matches if not m.is_away)
    return '\n'.join([
        '-- Generated by tool/import_matches.py from %s on %s: %d home + %d away matches.'
        % (source, dt.date.today().isoformat(), home, len(matches) - home),
        "-- Runs as the alley's admin (RLS and cancelled reservations as in the app).",
        '-- Reconciles: rekeys / updates / inserts / deletes by import_key; never a',
        '-- match without one, never a hand-edited one%s, never a user table.'
        % (' (--force: those too)' if force else ''),
        'begin;',
        "select set_config('import.tenant', coalesce(%s, ''), true);" % lookup,
        "select set_config('import.admin', coalesce((select id::text from profiles where tenant_id = nullif(current_setting('import.tenant'), '')::uuid and role = 'admin' and status = 'approved' and not placeholder order by created_at limit 1), ''), true);",
        "select set_config('import.type', coalesce((select id::text from priority_slot_types where tenant_id = nullif(current_setting('import.tenant'), '')::uuid and is_match and builtin), ''), true);",
        'do $$ begin',
        "  if current_setting('import.tenant') = '' then raise exception 'kuželna %s nenalezena', %s; end if;"
        % ('%', sql_str(label)),
        "  if current_setting('import.admin') = '' then raise exception 'no approved admin in the tenant'; end if;",
        "  if current_setting('import.type') = '' then raise exception 'builtin match type missing'; end if;",
        'end $$;',
        '-- The file, typed, and the plan the preview showed — both built here,',
        "-- before the role switch, so the admin role can read them below.",
        'create temp table rozpis on commit drop as',
        rozpis_select(rozpis_values(matches, prep)) + ';',
        'create temp table plan on commit drop as',
        plan_sql("current_setting('import.tenant')::uuid", force) + ';',
        'grant select on rozpis, plan to authenticated;',
        'do $$ begin',
        "  if exists (select 1 from plan where action = 'CONFLICT') then",
        "    raise exception 'nejednoznačné párování — viz náhled (CONFLICT)';",
        '  end if;',
    ] + ([] if allow_missing else [
        "  if exists (select 1 from plan where action = 'missing-team') then",
        "    raise exception 'sledované týmy, které v rozpise nejsou — viz náhled; --allow-missing-teams to přebije';",
        '  end if;',
    ]) + [
        'end $$;',
        '-- From here on exactly what the app does when the admin saves a match —',
        "-- plus import.run, which keeps the hand-edit trigger (0038) quiet.",
        'set local role authenticated;',
        "select set_config('request.jwt.claims', json_build_object('sub', current_setting('import.admin'), 'role', 'authenticated')::text, true);",
        "select set_config('import.run', 'on', true);",
        '-- Paired rows take the file\'s key and columns (the key first: a renamed',
        '-- opponent or a legacy key is a change of identity, the rest a change of',
        '-- fact). Unchanged rows are not written — no needless calendar jobs.',
        'update priority_slots p',
        '   set import_key = pl.new_key, date = r.date, starts_at = r.starts_at,',
        '       ends_at = r.ends_at, home_team = r.home, away_team = r.away,',
        '       prep_minutes = r.prep, description = r.description, is_away = r.is_away'
        + (', hand_edited = false' if force else ''),
        '  from plan pl join rozpis r on r.key = pl.new_key',
        " where p.id = pl.id and pl.action in ('rekey', 'rename', 'update');",
        'insert into priority_slots',
        '  (date, starts_at, ends_at, type_id, home_team, away_team, prep_minutes, description, is_away, created_by, import_key)',
        "select r.date, r.starts_at, r.ends_at, current_setting('import.type')::uuid,",
        "       r.home, r.away, r.prep, r.description, r.is_away,",
        "       current_setting('import.admin')::uuid, r.key",
        "  from plan pl join rozpis r on r.key = pl.new_key",
        " where pl.action = 'insert';",
        "delete from priority_slots p using plan pl where p.id = pl.id and pl.action = 'delete';",
        'select action, count(*) as zapasu from plan group by action order by %s;'
        % 'array_position(array[%s]::text[], action)' % ', '.join(sql_str(a) for a in ACTION_ORDER),
        'commit;',
        '',
    ])


# --- running ----------------------------------------------------------------

def run_sql(path: str, local: bool) -> int:
    """psql on the local stack; the Supabase CLI (management API, no
    database password needed) on prod. The CLI's own --local path sends a
    file as one prepared statement and rejects a transaction, hence psql."""
    if local:
        cmd = ['psql', LOCAL_DB_URL, '-X', '-v', 'ON_ERROR_STOP=1', '-f', path]
    else:
        cmd = ['supabase', 'db', 'query', '--linked', '-f', path]
    # Flush first: with stdout piped, Python's buffered lines would otherwise
    # land AFTER psql's unbuffered output.
    print('running: ' + ' '.join(cmd), flush=True)
    return subprocess.call(cmd)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('workbook', help='the schedule: .xls or .xlsx')
    ap.add_argument('--tenant', default='TJ Sokol Brno IV', help='tenants.name in the database')
    ap.add_argument('--tenant-id', help="the alley's uuid — beats --tenant (a renamed alley still matches)")
    ap.add_argument('--alley', default='Brno IV Sokol', help="our alley's name in the Kuželna column")
    ap.add_argument('--teams', nargs='+', default=['Husovice', 'Veverky', 'Devítka', 'Brno IV'],
                    help='substrings identifying our teams')
    ap.add_argument('--duration', type=int, default=180,
                    help='match length in minutes outside the KP1/KP2/dorost tiers (divize, the leagues)')
    ap.add_argument('--length', action='append', default=[], metavar='SOUTĚŽ=MIN',
                    help='pin a competition\'s match length by hand, e.g. --length "KP1 Sever=240" (repeatable)')
    ap.add_argument('--prep', type=int, default=30,
                    help='úklid před zápasem in minutes for home matches')
    ap.add_argument('--out', default='build/import_matches.sql', help='where the write SQL goes')
    ap.add_argument('--no-preview', action='store_true', help='only parse and write the SQL files')
    ap.add_argument('--apply', action='store_true', help='run the write — against PROD unless --local')
    ap.add_argument('--yes', action='store_true', help='with --apply: skip the confirmation question')
    ap.add_argument('--local', action='store_true', help='preview/apply on the local stack (psql) instead of prod')
    ap.add_argument('--force', action='store_true',
                    help='overwrite hand-edited matches too (and clear their flag)')
    ap.add_argument('--allow-missing-teams', action='store_true',
                    help='write even when a followed team does not occur in the file')
    args = ap.parse_args()

    overrides: Dict[str, int] = {}
    for item in args.length:
        name, _, mins = item.rpartition('=')
        if not name or not mins.isdigit():
            print('--length expects SOUTĚŽ=MINUTES, got %r' % item, file=sys.stderr)
            return 2
        overrides[name.strip()] = int(mins)

    warnings: List[str] = []
    rows = read_rows(args.workbook)
    all_matches = parse_rows(rows, warnings)
    if not any(m.alley == args.alley for m in all_matches):
        print('alley %r not found in the Kuželna column; values: %s' % (
            args.alley, ', '.join(sorted({m.alley for m in all_matches}))), file=sys.stderr)
        return 2
    matches = classify(all_matches, args.alley, args.teams)
    durations = assign_durations(matches, args.duration, overrides)
    unknown = [m for m in matches if m.time is None]
    matches = [m for m in matches if m.time is not None]

    print('%d rows in the file, tenant %r' % (len(rows), args.tenant))
    print('%d matches: %d home at %s, %d away' % (
        len(matches), sum(1 for m in matches if not m.is_away), args.alley,
        sum(1 for m in matches if m.is_away)))
    print('match length per competition (fallback for divize/ligy %s):'
          % fmt_minutes(args.duration))
    for comp in sorted(durations):
        note = ('pinned by --length' if comp in overrides
                else 'tier' if any(n.lower() in comp.lower() for n, _ in TIER_DURATIONS)
                else 'fallback (divize/liga)')
        print('  %-14s %s  (%s)' % (comp, fmt_minutes(durations[comp]), note))
    print()
    for m in matches:
        end, clamped = add_minutes(m.time, m.duration)
        flags = ' | '.join(m.warnings + (['end clamped to 23:59'] if clamped else []))
        print('%s %s %s–%s %-5s %-44s %-22s %s%s' % (
            WEEKDAYS[m.date.weekday()], m.date.strftime('%d.%m.%Y'), m.time, end,
            'venku' if m.is_away else 'doma', m.label, m.description,
            '' if not m.is_away else '@ ' + m.alley, ('  !! ' + flags) if flags else ''))
    if unknown:
        print('\nSKIPPED (time unknown in the file — add by hand once known):')
        for m in unknown:
            print('  %s %s %s %s @ %s' % (WEEKDAYS[m.date.weekday()], m.date, m.label, m.competition, m.alley))
    if warnings:
        print('\nWARNINGS:')
        for w in warnings:
            print('  ' + w)

    os.makedirs(os.path.dirname(args.out) or '.', exist_ok=True)
    with open(args.out, 'w', encoding='utf-8') as f:
        f.write(apply_sql(matches, args.tenant, args.tenant_id, args.prep,
                          os.path.basename(args.workbook), args.force,
                          args.allow_missing_teams))
    print('\nSQL written to %s' % args.out)
    if args.no_preview:
        return 0

    # The preview: the plan, read-only, against the database the write
    # would go to.
    where = 'LOKÁLNĚ' if args.local else 'PRODUKCE'
    with tempfile.NamedTemporaryFile('w', suffix='.sql', delete=False,
                                     encoding='utf-8') as f:
        f.write(preview_sql(matches, args.tenant, args.tenant_id, args.prep, args.force))
        probe = f.name
    try:
        print('\n%s — náhled (co by se změnilo; „unchanged“ jen v součtu):' % where)
        rc = run_sql(probe, args.local)
    finally:
        os.unlink(probe)
    if rc != 0:
        print('náhled selhal — nic se nezapisovalo', file=sys.stderr)
        return rc
    if not args.apply:
        print('\nZápis:  python3 %s <soubor> --apply%s' % (sys.argv[0], ' --local' if args.local else ''))
        return 0

    print('\nZapíše se plán výše jako jedna transakce (CONFLICT nebo chybějící '
          'sledovaný tým zápis zastaví). Domácí zápasy ruší kolidující rezervace '
          'a hráčům odejde upozornění.')
    if not args.yes:
        try:
            answer = input('Napiš "ano" pro zápis%s: ' % ('' if args.local else ' do produkce')).strip().lower()
        except EOFError:
            answer = ''
        if answer != 'ano':
            print('nic se nezapisovalo')
            return 1
    return run_sql(args.out, args.local)


if __name__ == '__main__':
    sys.exit(main())

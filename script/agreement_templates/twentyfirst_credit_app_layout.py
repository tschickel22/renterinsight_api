"""Lay out every box on 21st Mortgage's 5-page credit application (v. 12/20/2023).

    pdftotext -bbox twentyfirst_credit_app_1223.pdf /tmp/bbox.html
    python3 -I twentyfirst_credit_app_layout.py /tmp/bbox.html > twentyfirst_credit_app_1223.json

The form says "must be completed and signed by the applicant(s) only", so every box is
filled by a signer on the signing page, never by the dealer: signer 0 is the applicant
(column A plus the shared property, expense and assistance sections), signer 1 the
co-applicant (column B), signer 2 an optional non-applicant spouse (waiver on page 5).
Boxes are placed against the printed labels' own coordinates (percent of the page).
Every box has its own key: signing stores answers by key, so a shared key would make
all boxes print the same answer.
"""
import json, re, sys

html = open(sys.argv[1]).read()
WORDS = {}
for i, (W, H, body) in enumerate(re.findall(r'<page width="([\d.]+)" height="([\d.]+)">(.*?)</page>', html, re.S), 1):
    W, H = float(W), float(H)
    WORDS[i] = [dict(x0=float(a) / W * 100, y0=float(b) / H * 100, x1=float(c) / W * 100, y1=float(d) / H * 100, t=t)
                for a, b, c, d, t in re.findall(r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</word>', body)]

APPLICANT, CO_APPLICANT, SPOUSE = 0, 1, 2
OUT, KEYS = [], set()


def find(page, phrase, x=(0, 100), y=(0, 100)):
    """First run of words matching `phrase` on one line, inside the x/y window."""
    parts = phrase.split()
    allw = WORDS[page]
    ws = sorted((w for w in allw if x[0] <= w['x0'] <= x[1] and y[0] <= w['y0'] <= y[1]),
                key=lambda w: (round(w['y0'], 1), w['x0']))
    for i, w in enumerate(ws):
        if not w['t'].startswith(parts[0]):
            continue
        run, ok = [w], True
        for p in parts[1:]:
            nxt = next((v for v in allw if abs(v['y0'] - run[-1]['y0']) < 0.4 and 0 <= v['x0'] - run[-1]['x1'] < 1.5), None)
            if not nxt or not nxt['t'].startswith(p):
                ok = False
                break
            run.append(nxt)
        if ok:
            return dict(x0=run[0]['x0'], x1=run[-1]['x1'], y0=run[0]['y0'], y1=run[0]['y1'])
    raise SystemExit(f'p{page}: "{phrase}" not found in x{x} y{y}')


def put(page, who, key, label, kind, x, y, w, h):
    assert key not in KEYS, key
    KEYS.add(key)
    OUT.append({'id': f'tfca_{len(OUT) + 1}', 'fieldKey': f'credit_app.{key}', 'fieldLabel': label,
                'fieldType': kind, 'page': page - 1, 'x': round(x, 2), 'y': round(y, 2),
                'width': round(w, 2), 'height': round(h, 2), 'isCustomField': False,
                'isSignerField': True, 'signerIndex': who})


def text(page, who, key, label, x0, x1, y, h=1.6):
    put(page, who, key, label, 'text_input', x0, y, x1 - x0, h)


def after(page, who, key, label, phrase, x1, x=(0, 100), y=(0, 100), gap=0.5):
    """Box on the label's own line, from just after the label to x1."""
    f = find(page, phrase, x, y)
    text(page, who, key, label, f['x1'] + gap, x1, f['y0'] - 0.2)


def below(page, who, key, label, phrase, x1, x=(0, 100), y=(0, 100), x0=None, h=1.6):
    """Box under the label (cells whose label sits at the top)."""
    f = find(page, phrase, x, y)
    text(page, who, key, label, f['x0'] if x0 is None else x0, x1, f['y1'] + 0.25, h)


def box(page, who, key, label, phrase, x=(0, 100), y=(0, 100)):
    """Checkbox over the printed square just left of the option's text."""
    f = find(page, phrase, x, y)
    put(page, who, key, label, 'checkbox', f['x0'] - 1.95, f['y0'] - 0.2, 1.65, 1.65)


# ── Page 1: property ──────────────────────────────────────────────────────
P, A = 1, APPLICANT
for k, t in [('primary', 'Primary Residence'), ('secondary', 'Secondary Residence'), ('investment', 'Investment/Rental'), ('buy_for', 'Buy-For')]:
    box(P, A, f'property_{k}', f'Property will be: {t}', t, y=(8, 10))
for k, t, xr in [('home_only', 'Home Only', (10, 22)), ('land_and_home', 'Land and Home', (22, 35)), ('land_only', 'Land Only', (35, 45)),
                 ('purchased', 'Purchased', (60, 72)), ('refinanced', 'Reﬁnanced', (72, 85))]:
    box(P, A, f'loan_{k}', f'Loan type / home is being: {t}', t, x=xr, y=(10, 11.5))
below(P, A, 'site_street', 'Street address where home will be located', 'Street Address where', 64.5, y=(12, 13.5))
below(P, A, 'hoa_fee', 'HOA fee', 'HOA Fee:', 78.2, y=(12, 13.5))
below(P, A, 'hoa_frequency', 'HOA frequency', 'HOA Frequency:', 96.5, y=(12, 13.5))
after(P, A, 'site_city', 'Site city', 'City:', 41.3, y=(15, 17))
after(P, A, 'site_state', 'Site state', 'State:', 57.2, y=(15, 17))
after(P, A, 'site_zip', 'Site ZIP', 'Zip:', 69.5, y=(15, 17))
after(P, A, 'site_county', 'Site county', 'County:', 96.5, y=(15, 17))
for k, t in [('purchased', 'Purchased'), ('refinanced', 'Reﬁnanced'), ('owned', 'Owned Free and Clear')]:
    box(P, A, f'land_{k}', f'Land is being: {t}', t, x=(60, 100), y=(17.5, 19))
after(P, A, 'land_owner', 'Whose land is it?', 'Whose land is it?', 36.5, y=(19, 20.5))
after(P, A, 'land_value', 'Estimated land value', 'Value $', 58.2, y=(19, 20.5))
after(P, A, 'land_price', 'Land purchase price/payoff', 'Price/Payoﬀ $', 80.3, y=(19, 20.5))
after(P, A, 'land_date_acquired', 'Land date acquired', 'Acquired:', 96.5, y=(19, 20.5))
box(P, A, 'public_road_yes', 'Frontage on public road: Yes', 'Yes', x=(40, 50), y=(20.5, 22))
box(P, A, 'public_road_no', 'Frontage on public road: No', 'No', x=(46, 52), y=(20.5, 22))
box(P, A, 'paved_road_yes', 'Paved road: Yes', 'Yes', x=(78, 84), y=(20.5, 22))
box(P, A, 'paved_road_no', 'Paved road: No', 'No', x=(84, 90), y=(20.5, 22))
for k, t, xr, yr in [('owned_no_lien', 'Owned Property with', (15, 40), (22.5, 24)), ('leased_private', 'Leased Private', (40, 60), (22.5, 24)),
                     ('family_land', 'Family Land', (60, 80), (22.5, 24)), ('reservation', 'Reserva', (15, 40), (24, 26)),
                     ('community_park', 'Community/Park', (40, 60), (24, 26)), ('land_contract', 'Owned Property Land', (60, 80), (24, 26))]:
    box(P, A, f'site_{k}', f'Home-only site placement: {t}', t, x=xr, y=yr)
after(P, A, 'coop', 'Resident-owned community (co-op)?', '(co-op)?', 48.2, y=(26.5, 28))
f = find(P, 'shares?', y=(26.5, 28))
text(P, A, 'coop_shares', 'Pledging or purchasing co-op shares?', f['x1'] + 0.4, 97.0, f['y0'] - 0.2)
after(P, A, 'park_name', 'Community/park/land owner/mortgage holder', 'Holder:', 96.5, y=(28, 29.5))
after(P, A, 'park_phone', 'Community/park phone', 'Phone Number:', 39.3, y=(30, 31.5))
after(P, A, 'site_payment', 'Monthly site payment', 'Site Payment:', 80.0, y=(30, 31.5))
after(P, A, 'site_rent_increase', 'Site rent increase explanation', 'explain.', 96.5, y=(31.5, 33))
f = find(P, '$', x=(2, 5), y=(35, 37))
text(P, A, 'down_payment', 'Proposed down payment', f['x1'] + 0.4, 19.6, f['y0'] - 0.2)
for k, t in [('savings', 'Savings'), ('checking', 'Checking'), ('cash', 'Cash on Hand'), ('loan', 'Loan'), ('land', 'I wish to use')]:
    box(P, A, f'down_{k}', f'Down payment source: {t}', t, x=(37, 80), y=(33.5, 35))
box(P, A, 'down_gift', 'Down payment source: Gift', 'Gi', x=(20, 24), y=(35, 37))
after(P, A, 'down_gift_from', 'Gift from whom', 'whom):', 54.6, y=(35, 37))
box(P, A, 'down_other', 'Down payment source: Other', 'Other', x=(55, 60), y=(35, 37))
after(P, A, 'down_other_explain', 'Down payment source: other (explain)', '(Explain):', 96.5, y=(35, 37))


# ── Page 1: applicant / co-applicant columns ──────────────────────────────
def page1_column(who, p, x0, x1):
    X = (x0 - 0.5, x1)
    end = x1 - 0.8
    below(1, who, f'{p}_full_name', 'Full name (last, first, middle)', 'FULL NAME', end, x=X, y=(39, 40.5))
    below(1, who, f'{p}_birth_date', 'Birth date', 'Birth Date', find(1, 'Social Security', X, (42, 43.5))['x0'] - 0.6, x=X, y=(42, 43.5))
    below(1, who, f'{p}_ssn', 'Social Security number', 'Social Security', end, x=X, y=(42, 43.5))
    for k, t in [('married', 'Married'), ('unmarried', 'Unmarried'), ('separated', 'Separated')]:
        box(1, who, f'{p}_marital_{k}', f'Marital status: {t}', t, x=X, y=(45.5, 47))
    after(1, who, f'{p}_dependents', 'Number of dependents', 'Dependents:', find(1, 'Dependent Age(s):', X, (51.5, 53))['x0'] - 0.6, x=X, y=(51.5, 53))
    after(1, who, f'{p}_dependent_ages', 'Dependent ages', 'Age(s):', end, x=X, y=(51.5, 53))
    below(1, who, f'{p}_email', 'Email', 'EMAIL:', end, x=X, y=(53.5, 55), x0=x0)
    cell = find(1, 'Cell Phone:', X, (56.5, 58))
    other = find(1, 'Other Phone:', X, (56.5, 58))
    text(1, who, f'{p}_cell_phone', 'Cell phone', cell['x1'] + 0.4, other['x0'] - 0.6, cell['y0'] - 0.2)
    text(1, who, f'{p}_other_phone', 'Other phone', other['x1'] + 0.4, end, other['y0'] - 0.2)
    below(1, who, f'{p}_street', 'Current street address', 'Current Street Address', end, x=X, y=(60.5, 62), h=1.9)
    county = find(1, 'County:', X, (64.5, 66))
    after(1, who, f'{p}_city_state_zip', 'Current city, state, ZIP', 'City, State, Zip:', county['x0'] - 0.6, x=X, y=(64.5, 66))
    after(1, who, f'{p}_county', 'Current county', 'County:', end, x=X, y=(64.5, 66))
    mcity = find(1, 'City, State, Zip:', (x0 + 20, x1), (67, 68.5))
    below(1, who, f'{p}_mailing_street', 'Mailing address (if different)', 'Mailing Address', mcity['x0'] - 0.6, x=X, y=(67, 68.5))
    text(1, who, f'{p}_mailing_city_state_zip', 'Mailing city, state, ZIP', mcity['x0'], end, mcity['y1'] + 0.25)
    yrs, mo = find(1, 'Yrs', X, (73, 74.5)), find(1, 'Mo', X, (73, 74.5))
    text(1, who, f'{p}_years_at_address', 'Years at present address', x0 + 0.3, yrs['x0'] - 0.3, yrs['y0'] - 0.2)
    text(1, who, f'{p}_months_at_address', 'Months at present address', yrs['x1'] + 0.3, mo['x0'] - 0.3, mo['y0'] - 0.2)
    for k, t, yr in [('homeowner', 'Homeowner*', (71, 72.5)), ('other', 'Other*', (71, 72.5)), ('renter', 'Renter', (73, 74.5)), ('family', 'Live with', (73, 74.5))]:
        box(1, who, f'{p}_housing_{k}', f'Housing: {t.rstrip("*")}', t, x=X, y=yr)
    rent = find(1, 'Mtg/Rent:', X, (71, 72.5))
    text(1, who, f'{p}_housing_payment', 'Monthly mortgage/rent', find(1, 'Mo. Mtg/Rent:', X, (71, 72.5))['x0'], end, rent['y1'] + 0.35)
    after(1, who, f'{p}_landlord', 'Mortgage holder or landlord', 'Landlord:', end, x=X, y=(74.5, 76))
    after(1, who, f'{p}_landlord_phone', 'Mortgage holder/landlord phone', 'Telephone Number:', end, x=X, y=(76, 77.5))
    below(1, who, f'{p}_current_home_plans', 'Plans for current home / other explained', '*If homeowner', end, x=X, y=(77.5, 79), x0=x0)
    below(1, who, f'{p}_prev_street', 'Previous address', 'Previous Address', end, x=X, y=(80.5, 82), h=1.9)
    howlong = find(1, 'How long?', X, (83.5, 85))
    after(1, who, f'{p}_prev_city_state_zip', 'Previous city, state, ZIP', 'City, State, Zip:', howlong['x0'] - 0.6, x=X, y=(83.5, 85))
    after(1, who, f'{p}_prev_how_long', 'Time at previous address', 'How long?', end, x=X, y=(83.5, 85))
    after(1, who, f'{p}_prev_landlord', 'Previous mortgage holder or landlord', 'Landlord:', end, x=X, y=(86, 87.5))
    after(1, who, f'{p}_prev_landlord_phone', 'Previous mortgage holder/landlord phone', 'Telephone Number:', end, x=X, y=(88, 89.5))
    rel = find(1, 'Rela', X, (89.5, 91))
    text(1, who, f'{p}_relative_name', 'Nearest relative not living with you', x0, rel['x0'] - 0.6, rel['y1'] + 0.5)
    after(1, who, f'{p}_relative_relationship', 'Relative: relationship', 'Rela', end, x=X, y=(89.5, 91))
    after(1, who, f'{p}_relative_phone', 'Relative: phone', 'Phone:', end, x=(rel['x0'] - 1, x1), y=(91, 92.5))


page1_column(APPLICANT, 'a', 3.0, 49.3)
page1_column(CO_APPLICANT, 'b', 50.8, 97.0)


# ── Page 2: employment and other income ───────────────────────────────────
def employment(who, p, y0, y1):
    Y = lambda a, b: (y0 + a, y0 + b)          # rows relative to the section's "1. Current Employer" line
    cur = find(2, 'Current Employer:', y=(y0 - 0.5, y0 + 1))
    base = cur['y0']
    R = lambda a, b: (base + a, base + b)
    text(2, who, f'{p}_emp1_name', 'Current employer', 3.0, 40.0, cur['y1'] + 0.25)
    after(2, who, f'{p}_emp1_position', 'Current employer: position', 'Held/Occupa', 76.2, y=R(-0.5, 0.5))
    below(2, who, f'{p}_emp1_started', 'Current employer: date started', 'Date Started:', 96.5, y=R(-0.5, 0.5))
    box(2, who, f'{p}_emp1_self_yes', 'Current employer: self employed Yes', 'Yes', x=(50, 56), y=R(1.5, 2.5))
    box(2, who, f'{p}_emp1_self_no', 'Current employer: self employed No', 'No', x=(56, 61), y=R(1.5, 2.5))
    addr = find(2, 'Employer Address:', y=R(2.5, 3.8))
    text(2, who, f'{p}_emp1_address', 'Current employer: address', 3.0, 40.0, addr['y1'] + 0.3)
    text(2, who, f'{p}_emp1_city_state_zip', 'Current employer: city, state, ZIP', 40.3, 63.9, addr['y1'] + 0.3)
    text(2, who, f'{p}_emp1_supervisor', 'Current employer: supervisor name and phone', 64.2, 96.5, addr['y1'] + 0.3)
    pay = R(7.8, 9.2)
    for k, t, xr in [('hourly', 'Hourly', (3, 10)), ('weekly', 'Weekly Salary', (36, 50)), ('biweekly', 'Bi-Weekly', (55, 66)), ('monthly', 'Monthly Salary', (75, 86))]:
        box(2, who, f'{p}_pay_{k}', f'Paid: {t}', t, x=xr, y=pay)
    for k, label, dollar_x, end in [('hourly_rate', 'Hourly rate', (10, 14), 19.1), ('weekly_salary', 'Weekly salary', (46, 50), 57.6),
                                     ('biweekly_salary', 'Bi-weekly salary', (67, 70), 78.3), ('monthly_salary', 'Monthly salary', (87, 90), 96.5)]:
        d = find(2, '$', x=dollar_x, y=pay)
        text(2, who, f'{p}_{k}', label, d['x1'] + 0.3, end, d['y0'] - 0.2)
    hours = find(2, 'Weekly:', x=(24, 32), y=pay)
    text(2, who, f'{p}_hours_weekly', 'Hours weekly', hours['x1'] + 0.3, 36.6, hours['y0'] - 0.2)
    for n, (k, word) in enumerate([('bonus', 'bonuses?'), ('commission', 'commission?'), ('overtime', 'over')]):
        row = find(2, f'receive {word}', y=R(9.5 + n * 1.85, 11.2 + n * 1.85))
        rr = (row['y0'] - 0.4, row['y0'] + 0.4)
        box(2, who, f'{p}_{k}_yes', f'Receives {k}: Yes', 'Yes', x=(21, 26), y=rr)
        box(2, who, f'{p}_{k}_no', f'Receives {k}: No', 'No', x=(26, 30), y=rr)
        often = find(2, 'o', x=(33, 35), y=rr)
        text(2, who, f'{p}_{k}_how_often', f'{k.capitalize()}: how often', often['x1'] + 2.9, 49.6, row['y0'] - 0.2)
        d = find(2, '$', x=(77, 82), y=rr)
        text(2, who, f'{p}_{k}_12_months', f'{k.capitalize()}: last 12 months', d['x1'] + 0.3, 96.5, row['y0'] - 0.2)
    for n, (label_word, k, extra_left) in enumerate([('Second Employer:', 'emp2', False), ('Previous Employer:', 'emp3', True)]):
        e = find(2, label_word, y=(base + 15 + n * 7, base + 25 + n * 7))
        ey = e['y0']
        nm = 'Second employer' if k == 'emp2' else 'Previous employer'
        text(2, who, f'{p}_{k}_name', nm, 3.0, 40.0, e['y1'] + 0.35)
        after(2, who, f'{p}_{k}_position', f'{nm}: position', 'Held/Occupa', 76.2, y=(ey - 0.5, ey + 0.5))
        started = find(2, 'Date Started:', y=(ey - 0.5, ey + 0.5))
        if extra_left:
            text(2, who, f'{p}_{k}_started', f'{nm}: date started', started['x0'], 89.0, started['y1'] + 0.35)
            below(2, who, f'{p}_{k}_left', f'{nm}: date left', 'Date Le', 96.5, y=(ey - 0.5, ey + 0.5))
        else:
            below(2, who, f'{p}_{k}_started', f'{nm}: date started', 'Date Started:', 96.5, y=(ey - 0.5, ey + 0.5))
        box(2, who, f'{p}_{k}_self_yes', f'{nm}: self employed Yes', 'Yes', x=(50, 56), y=(ey + 1.5, ey + 2.5))
        box(2, who, f'{p}_{k}_self_no', f'{nm}: self employed No', 'No', x=(56, 61), y=(ey + 1.5, ey + 2.5))
        cs = find(2, 'City, State:', y=(ey + 2.5, ey + 4))
        text(2, who, f'{p}_{k}_city_state', f'{nm}: city, state', 3.0, 40.0, cs['y1'] + 0.35)
        text(2, who, f'{p}_{k}_supervisor', f'{nm}: supervisor name and phone', 40.8, 76.2, cs['y1'] + 0.35)
        text(2, who, f'{p}_{k}_monthly_income', f'{nm}: monthly income', 76.6, 96.5, cs['y1'] + 0.35)
    gaps = find(2, 'Please provide', y=(base + 30, y1))
    text(2, who, f'{p}_job_gaps', 'Job gaps over 30 days explained', 3.0, 96.5, gaps['y1'] + 0.9, 1.9)


employment(APPLICANT, 'a', 4.5, 40)
employment(CO_APPLICANT, 'b', 43, 79)


def other_income(who, p, x0, x1):
    X = (x0 - 0.5, x1)
    ages = find(2, 'Ages of Children', X, (84.5, 86))
    below(2, who, f'{p}_child_support', 'Child support monthly amount', 'Child Support Monthly', ages['x0'] - 0.5, x=X, y=(84.5, 86))
    below(2, who, f'{p}_child_support_ages', 'Child support: ages of children', 'Ages of Children', x1 - 0.8, x=X, y=(84.5, 86))
    below(2, who, f'{p}_alimony', 'Alimony or separate maintenance', 'Alimony or Separate', ages['x0'] - 0.5, x=X, y=(87.5, 89))
    below(2, who, f'{p}_alimony_duration', 'Alimony: duration', 'Dura', x1 - 0.8, x=X, y=(87.5, 89))
    hl, amt = find(2, 'How Long:', X, (90.5, 92)), find(2, 'Monthly Amt:', X, (90.5, 92))
    below(2, who, f'{p}_other_income_source', 'Other income source', 'Other Source:', hl['x0'] - 0.5, x=X, y=(90.5, 92))
    text(2, who, f'{p}_other_income_how_long', 'Other income: how long', hl['x0'], amt['x0'] - 0.5, hl['y1'] + 0.25)
    text(2, who, f'{p}_other_income_monthly', 'Other income: monthly amount', amt['x0'], x1 - 0.8, amt['y1'] + 0.25)


other_income(APPLICANT, 'a', 3.0, 49.3)
other_income(CO_APPLICANT, 'b', 50.8, 97.0)


# ── Page 3: assets, credit, debts ─────────────────────────────────────────
def page3_column(who, p, x0, x1):
    X = (x0 - 0.5, x1)
    end = x1 - 0.8
    acct = find(3, 'Account Type:', X, (4.5, 6))
    after(3, who, f'{p}_bank_name', 'Bank name', 'Bank Name:', acct['x0'] - 0.5, x=X, y=(4.5, 6))
    after(3, who, f'{p}_account_type', 'Account type', 'Type:', end, x=(acct['x0'], x1), y=(4.5, 6))
    after(3, who, f'{p}_bank_balance', 'Bank balance', 'Balance: $', end, x=X, y=(6.5, 8))
    after(3, who, f'{p}_liquid_type', 'Type of liquid assets', 'etc.):', end, x=X, y=(8.5, 10))
    bal = find(3, 'Balance: $', X, (10.5, 12))
    after(3, who, f'{p}_liquid_institution', 'Liquid assets: institution', 'Assets:', bal['x0'] - 0.5, x=X, y=(10.5, 12))
    after(3, who, f'{p}_liquid_balance', 'Liquid assets: balance', 'Balance: $', end, x=X, y=(10.5, 12))
    after(3, who, f'{p}_retirement_type', 'Type of retirement accounts', 'etc.):', end, x=X, y=(12.5, 14))
    after(3, who, f'{p}_retirement_institution', 'Retirement: institution', 'Assets:', bal['x0'] - 0.5, x=X, y=(14.5, 16))
    after(3, who, f'{p}_retirement_balance', 'Retirement: balance', 'Balance: $', end, x=X, y=(14.5, 16))
    for n, yy in enumerate([(22, 23.5), (24, 25.5), (26, 27.8)], 1):
        pay, balw = find(3, 'Payment: $', X, yy), find(3, 'Balance: $', X, yy)
        after(3, who, f'{p}_loan{n}_lender', f'Unlisted loan {n}: lender', 'Lender:', pay['x0'] - 0.5, x=X, y=yy)
        text(3, who, f'{p}_loan{n}_payment', f'Unlisted loan {n}: payment', pay['x1'] + 0.3, balw['x0'] - 0.5, pay['y0'] - 0.2)
        text(3, who, f'{p}_loan{n}_balance', f'Unlisted loan {n}: balance', balw['x1'] + 0.3, end, balw['y0'] - 0.2)
    for key, label, yy in [('cosign', 'Co-signed debt', (30.5, 32)), ('paidoff1', 'Paid off in last 60 days (1)', (36, 37.5)), ('paidoff2', 'Paid off in last 60 days (2)', (38, 39.5))]:
        mp = find(3, 'Monthly Payment: $', X, yy)
        after(3, who, f'{p}_{key}_lender', f'{label}: lender', 'Lender:', mp['x0'] - 0.5, x=X, y=yy)
        text(3, who, f'{p}_{key}_payment', f'{label}: monthly payment', mp['x1'] + 0.3, end, mp['y0'] - 0.2)
    exp = find(3, 'Expira', X, (42, 43.5))
    after(3, who, f'{p}_debt_alimony', 'Alimony/maintenance owed', 'Alimony/Maintenance: $', exp['x0'] - 0.5, x=X, y=(42, 43.5))
    after(3, who, f'{p}_debt_alimony_expires', 'Alimony/maintenance: expiration', 'Date:', end, x=X, y=(42, 43.5))
    after(3, who, f'{p}_debt_garnishment', 'Garnishment', 'Garnishment: $', end, x=X, y=(44, 45.5))
    after(3, who, f'{p}_debt_child_support', 'Child support owed', 'Support: $', end, x=X, y=(46, 47.5))
    after(3, who, f'{p}_debt_children_ages', 'Ages of children (debts)', 'Children:', end, x=X, y=(48.5, 50))


page3_column(APPLICANT, 'a', 3.0, 49.3)
page3_column(CO_APPLICANT, 'b', 50.8, 97.0)

A = APPLICANT
d = find(3, '$', x=(72, 75), y=(56.5, 58))
text(3, A, 'expense_fuel', 'Monthly fuel and maintenance (20+ miles to work)', d['x1'] + 0.3, 96.5, d['y0'] - 0.2)
d = find(3, '$', x=(72, 75), y=(59, 60.5))
text(3, A, 'expense_child_care', 'Child care expense', d['x1'] + 0.3, 96.5, d['y0'] - 0.2)
for n, yy in enumerate([(61, 62.5), (63, 64.5)], 1):
    o, d = find(3, 'Other:', x=(2, 8), y=yy), find(3, '$', x=(72, 75), y=yy)
    text(3, A, f'expense_other{n}', f'Other budget item {n}', o['x1'] + 0.5, 72.0, o['y0'] - 0.2)
    text(3, A, f'expense_other{n}_amount', f'Other budget item {n}: monthly', d['x1'] + 0.3, 96.5, d['y0'] - 0.2)
for n, yy in enumerate([(71, 72.5), (73, 74.5)], 1):
    d = find(3, '$', x=(72, 75), y=yy)
    text(3, A, f'gov_assistance{n}', f'Government assistance {n}', 3.0, 72.0, d['y0'] - 0.2)
    text(3, A, f'gov_assistance{n}_amount', f'Government assistance {n}: monthly', d['x1'] + 0.3, 96.5, d['y0'] - 0.2)
for who, p, yes_x, no_x in [(APPLICANT, 'a', (64, 70), (70, 76)), (CO_APPLICANT, 'b', (83, 89), (89, 94))]:
    for k, yy in [('citizen', (79.5, 81)), ('permanent_resident', (81.5, 83)), ('bankruptcy', (83.5, 85))]:
        box(3, who, f'{p}_{k}_yes', f'{k.replace("_", " ").capitalize()}: Yes', 'Yes', x=yes_x, y=yy)
        box(3, who, f'{p}_{k}_no', f'{k.replace("_", " ").capitalize()}: No', 'No', x=no_x, y=yy)
after(3, APPLICANT, 'a_bankruptcy_date', 'Bankruptcy filed (date)', 'Date:', 79.0, x=(64, 70), y=(85.5, 87))
after(3, CO_APPLICANT, 'b_bankruptcy_date', 'Bankruptcy filed (date)', 'Date:', 96.5, x=(83, 89), y=(85.5, 87))


# ── Page 4: demographic information (all optional by law) ─────────────────
def demographics(who, p, x0, x1):
    X = (x0, x1)
    end = x1 - 2.5
    opts = [
        ('hispanic', 'Hispanic or La', (29.5, 31), 0), ('mexican', 'Mexican', (31.5, 33), 1), ('puerto_rican', 'Puerto Rican', (31.5, 33), 1),
        ('cuban', 'Cuban', (31.5, 33), 1), ('other_hispanic', 'Other Hispanic', (33, 34.5), 1), ('not_hispanic', 'Not Hispanic', (38.5, 40), 0),
        ('ethnicity_decline', 'I do not wish', (40.5, 42), 0), ('american_indian', 'American Indian', (46, 47.5), 0), ('asian', 'Asian', (48.5, 50), 0),
        ('asian_indian', 'Asian Indian', (50, 51.5), 1), ('chinese', 'Chinese', (50, 51.5), 1), ('filipino', 'Filipino', (50, 51.5), 1),
        ('japanese', 'Japanese', (51.5, 53), 1), ('korean', 'Korean', (51.5, 53), 1), ('vietnamese', 'Vietnamese', (51.5, 53), 1),
        ('other_asian', 'Other Asian', (53, 54.5), 1), ('black', 'Black or African', (57, 58.5), 0), ('pacific_islander', 'Na', (59, 60.5), 0),
        ('native_hawaiian', 'Na', (60.5, 62), 1), ('samoan', 'Samoan', (60.5, 62), 1), ('guamanian', 'Guamanian', (62, 63.5), 1),
        ('other_pacific', 'Other Paciﬁc', (63.5, 65), 1), ('white', 'White', (68, 69.5), 0), ('race_decline', 'I do not wish', (69.5, 71), 0),
        ('female', 'Female', (73.5, 75), 0), ('male', 'Male', (75, 76.5), 0), ('sex_decline', 'I do not wish', (76.5, 78), 0)]
    for k, t, yy, indent in opts:
        xr = (x0 + 4, x0 + 7) if indent == 0 else (x0 + 8, x1)
        if k == 'pacific_islander':
            xr = (x0 + 4, x0 + 7)
        box(4, who, f'{p}_{k}', f'Demographics: {k.replace("_", " ")}', t, x=xr, y=yy)
    o = find(4, 'origin:', X, (33, 34.5))
    text(4, who, f'{p}_hispanic_origin', 'Other Hispanic or Latino origin', o['x0'] - 22.8, end, o['y1'] + 0.35, 1.5)
    after(4, who, f'{p}_tribe', 'Enrolled or principal tribe', 'tribe:', end, x=X, y=(47, 48.5))
    after(4, who, f'{p}_other_asian_race', 'Other Asian race', 'race:', end, x=X, y=(53, 54.5))
    r = find(4, 'race:', X, (63.5, 65))
    text(4, who, f'{p}_other_pacific_race', 'Other Pacific Islander race', r['x0'] - 20.3, end, r['y1'] + 0.35, 1.5)


demographics(APPLICANT, 'a', 3.0, 49.3)
demographics(CO_APPLICANT, 'b', 50.8, 97.0)


# ── Page 5: spouse waiver and signatures ──────────────────────────────────
def sign(page, who, kind, label, x0, x1, y, h):
    OUT.append({'id': f'tfca_{len(OUT) + 1}', 'fieldKey': f'signer.{kind}', 'fieldLabel': label, 'fieldType': kind,
                'page': page - 1, 'x': round(x0, 2), 'y': round(y, 2), 'width': round(x1 - x0, 2), 'height': round(h, 2),
                'isCustomField': False, 'isSignerField': True, 'signerIndex': who})


sp = find(5, 'Spouse:', y=(39.5, 41))
sign(5, SPOUSE, 'signature', 'Non-applicant spouse signature', sp['x1'] + 0.6, 50.0, sp['y0'] - 0.4, 1.8)
dt = find(5, 'Date', x=(60, 75), y=(42, 43.5))
sign(5, SPOUSE, 'date_signed', 'Non-applicant spouse date', dt['x1'] + 0.6, 84.0, dt['y0'] - 0.3, 1.6)
a_sig = find(5, 'Applicant Signature', x=(2, 20), y=(83, 85))
a_date = find(5, 'Date', x=(25, 40), y=(83, 85))
b_sig = find(5, 'Co-Applicant Signature', y=(83, 85))
b_date = find(5, 'Date', x=(75, 90), y=(83, 85))
top = a_sig['y0'] - 3.4
sign(5, APPLICANT, 'signature', 'Applicant signature', a_sig['x0'], a_date['x0'] - 1.0, top, 3.1)
sign(5, APPLICANT, 'date_signed', 'Applicant date', a_date['x0'], 39.3, top + 1.2, 1.8)
sign(5, CO_APPLICANT, 'signature', 'Co-applicant signature', b_sig['x0'], b_date['x0'] - 1.0, top, 3.1)
sign(5, CO_APPLICANT, 'date_signed', 'Co-applicant date', b_date['x0'], 89.0, top + 1.2, 1.8)

json.dump(OUT, sys.stdout, indent=1)
from collections import Counter
print(f"{len(OUT)} boxes; by page {dict(sorted(Counter(p['page'] + 1 for p in OUT).items()))}; "
      f"by signer {dict(sorted(Counter(p['signerIndex'] for p in OUT).items()))}", file=sys.stderr)

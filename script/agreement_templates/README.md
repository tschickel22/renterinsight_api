# Building purchase agreement templates (Form 500 and forms like it)

Read this before building or changing a template script in this folder. Every
rule here comes from a gap found on a real dealer agreement. Most came from
Coastal Breeze agreement 90 (production, deal 659, 2026-11-22).

## What is here

| Script | Builds | Where it lives |
|---|---|---|
| `form500_ms.rb` | Mississippi Form 500, 3 pages, platform template `FORM500_MS` | every MS company |
| `form500_ms_buyer_ack.rb` | Form 500 + Coastal Breeze 10-page Closing Package, `FORM500_MS_BUYER_ACK` | Coastal Breeze only (prod co 27, template 41) |
| `fdhc_indiana_pa.rb`, `fdhc_indiana_packet.rb` | Factory Direct Indiana purchase agreement and packet | FDHC |
| `twentyfirst_credit_app.rb` | 21st Mortgage credit application | per dealer |

Each script previews by default and changes nothing. `--apply` saves it and
rebuilds the template in place, so agreements made from it keep their link.
`--expect "<name>"` guards against the wrong tenant, because account numbers
differ per environment.

**A clone copies its source when it runs.** `form500_ms_buyer_ack.rb` copies
pages 1 to 3 from the live `FORM500_MS` template. After any change to
`form500_ms.rb`, run `form500_ms.rb --apply` first and then the clone, in each
environment.

**Agreements already made keep the values they saved.** A template fix shows up
on a new agreement, or on an existing one after its merge values are refreshed
from the deal.

## Two kinds of box

- `merge` places a value we hold. It prints what the deal, contact or home says,
  and the dealer can't change it on the form.
- `field` is a box the preparer fills. Give it `merge_from:` and it starts with the
  value we hold, then the dealer can correct it. Use this whenever our value is
  a good guess but not always right (hitch size, delivery date, buyer names).
- `formula:` computes the box (subtotals, cash price, unpaid balance). Formulas
  can read merge fields directly, and `sum(deal.<array>.line_total)` adds a
  repeating column.

## Line items: which array to use

A deal's lines come from `Agreements::DealLineItemsResolver`: the selected Deal
Desk scenario, else `deal_products`. A `deal_products` line keeps its category
as a tag in notes (`category:service, source:standard_item`). The resolver reads
that tag. Before 2026-11-22 it didn't, so every category array came back empty
and the Form 500 option rows never filled.

| Array | What it holds | Use it for |
|---|---|---|
| `deal.line_items` | every line, home included | a full itemized list |
| `deal.non_home_line_items` | everything but the home | a list with fees in it |
| `deal.line_items_options` | everything but the home and fees | **"Optional equipment, labor and accessories"** on Form 500 style forms |
| `deal.line_items_fee` / `_service` / `_accessory` / `_land` / `_product` / `_other` | one category | a section that wants only that category |

Matching totals: `deal.options_total_from_lines`, `deal.fee_total`,
`deal.service_total`, `deal.accessory_total_from_lines`, `deal.land_total`,
`deal.home_total`.

Rules:

- **Don't put the options section on `line_items_accessory`.** Dealers add
  skirting, A/C, steps, delivery and set as `service` lines (standard items) and
  deal sheet upgrades as `accessory` or `other`. Only `line_items_options` catches
  them all.
- **Never count a line twice.** The home goes on the base price line
  (`deal.selling_price`) and fees on the fees line (`deal.fee_total`), so the
  options list leaves both out. If a form has its own line for another category
  (land, insurance), take that category out of the options too.
- Lines priced at $0 (included items) still print with their $0. That is
  intended: the buyer sees what comes with the home.
- Sales tax: `deal.tax_amount` adds up the tax on the lines (Deal Sheet deals
  use the deal's own tax).
- Down payment on a contract is `deal.contract_down_payment`. `deal.down_payment`
  is the deposit and no template should read it.
- The deal sheet writes its lines onto the deal, so reading the deal covers it.

## The home header

| Box | Merge field | Notes |
|---|---|---|
| Make, model, year, bedrooms | `vehicle.make` etc. | |
| Serial number | `vehicle.serial_number` | Blank for a catalog placeholder (`CAT-<source>-<model>...`), which every not-yet-built catalog home carries. Never print one. Else VIN. |
| Stock number | `vehicle.stock_number` | Falls back to the inventory id. |
| New / used | `vehicle.is_new`, `vehicle.is_used` | |
| Single / double wide | `vehicle.is_single_section`, `vehicle.is_multi_section` | Sections if recorded, else width: 20 feet or wider is a multi-section. Catalog homes have no sections. |
| Floor size L / W | `vehicle.length`, `vehicle.width` | Separate boxes take separate fields. `vehicle.floor_size` is "L x W" for a single box. |
| Hitch size L / W | `field` with `merge_from: 'vehicle.length'` / `'vehicle.width'` | We hold no hitch size. It starts as the floor size and the dealer corrects it. |
| Color | `vehicle.exterior_color` | Deal sheet choice, else the home's color. Blank if neither exists. |
| Insulation R-values / type | `vehicle.insulation_r_roof`, `_wall`, `_floor`, `vehicle.insulation_type` | Blank unless the home record has them. |
| Delivery date | `field` with `merge_from: 'deal.delivery_date'` | |
| Delivery address | `deal.delivery_street` etc. | |

Buyer and co-buyer: `deal.buyer_names`, `contact.*` for buyer 1 (street, city,
state, zip, phone, mobile_phone, email), `deal.co_buyer_*` for buyer 2.

## Signer boxes

- A value repeated across pages gets ONE signer-editable box. The signing page
  saves by field key, so two editable boxes with the same key overwrite each
  other. Repeats print the same answer.
- A signer's answer is saved under `custom.<key>` in `merge_field_values` and beats
  the preparer's value.
- Signer boxes are positional (`signerIndex`). An optional extra signer (for
  example Sales Representative, index 3) stays out of `default_signers` and prints
  blank when the dealer doesn't add one.

## PDFs

- Start from a blank copy of the form: strip flattened values, the old dealer
  header, DRAFT marks and publisher footers.
- Place each box on the rectangle the original form's own field used (PDF points
  from the top left, converted to percent of the page).
- Join PDFs with `qpdf`. The Form 500 PDF has optional content that other tools
  drop.

## Checklist before calling a new template done

1. Make an agreement from it on a real deal that has a home from inventory, a
   catalog (order-from-factory) home, standard items, a deal sheet upgrade, a fee
   and a co-buyer.
2. Every option row shows a deal line, and the balance carried equals their total.
3. Base price + options + tax + fees = cash price, with nothing counted twice.
4. No `CAT-` serial anywhere in the PDF.
5. The header boxes fill from the home. Anything still blank is blank on the
   record too (check the contact address and the deal's delivery fields before
   calling it a bug).
6. Spec: `spec/requests/agreement_merge_fields_form500_header_spec.rb` covers the
   options, serial, stock number and sections rules. Add to it when adding a rule.

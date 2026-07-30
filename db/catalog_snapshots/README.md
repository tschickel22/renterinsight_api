# Trove catalog snapshots

Captured catalogs for Trove-hosted manufacturer sites, used while a live crawl
is blocked.

## Why snapshots exist

Trove hosts sit behind a Vercel bot checkpoint that answers **429** to every
non-browser client, including from a datacenter IP. Crawl *rights* are fine on
manufacturer hosts (`trove.legacyhousing.com` publishes `Allow: /` plus a
sitemap) — the block is bot fingerprinting, not permission. Until a host
allowlists our user agent or egress IP, a snapshot is how a source runs.

`TroveCatalogAdapter` parses snapshot data and live-crawled data through the
**same extractors**, so a snapshot-backed run exercises the real ingestion path:
Test, Run Now, vehicles, images, change detection.

Note the image CDN (`trove.b-cdn.net`) is **not** blocked — plain server-side
requests return 200. Only the catalog HTML is gated.

## Refresh procedure

1. Open the manufacturer catalog in a browser, e.g.
   <https://trove.legacyhousing.com/homes>, and open the DevTools console.
2. Paste `capture_trove.js`. It crawls the index plus each model page and
   downloads a JSON file. Roughly 3 minutes for ~93 models.
   Chrome may block the download the first time; allow it in the address bar
   and re-run `troveCapture()`.
3. Load it and re-run the source:

   ```bash
   bin/rails 'catalog:snapshot:load[db/catalog_snapshots/trove_legacy_housing.json,legacy_housing]'
   bin/rails runner 'Catalog::RunService.new(CatalogSource.find_by(adapter_type: "trove_catalog"), trigger: "manual").call'
   ```

Change detection does the rest. `catalog_content_hash` is compared per home, so
only models whose tracked content actually moved are updated, and **dealer edits
are never clobbered** (verified: a renamed/repriced vehicle survives re-sync with
`updated=0`).

## Going live

When a host allowlists us, delete `snapshot_key` from the source config and set
a schedule. No code change:

```ruby
src = CatalogSource.find_by(adapter_type: 'trove_catalog')
src.update!(config: src.config.except('snapshot_key'), schedule: 'daily')
```

`CatalogNightlySyncJob` then picks it up on its own cadence.

## Rake tasks

| Task | Purpose |
| --- | --- |
| `catalog:snapshot:load[path,key]` | Load a JSON file into platform settings |
| `catalog:snapshot:list` | List stored snapshots |
| `catalog:snapshot:source[key]` | Create/update a source bound to a snapshot |

## Current snapshots

| File | Supplier | Homes | Images |
| --- | --- | --- | --- |
| `trove_legacy_housing.json` | Legacy Housing | 93 | 1,862 (avg 20) |

### Legacy data quirks worth knowing

- **No descriptions.** Legacy publishes the description scaffold with empty
  bodies on every record, so the source sets `untracked_fields: [description]`.
  Series is fine — it leads the model name, and resolves for all 93.
- **7 call-for-quote models** carry a `$900` placeholder price behind
  `is_price_hidden`. The adapter suppresses it; those homes ingest with no price.
- **10 name/SKU disagreements**, mostly a typographic `×` in the SKU
  (`H-32×72-43A`), normalized to `x`. Two are genuine (`C-1668-22A` has SKU
  `C-1668-22C`). That is Legacy's own data, left as published.
- **7 models ship no `supplier_sku`**; `model_id` falls back to the model name
  minus its series word.

## Do not capture dealer storefronts

`*.buildtrove.com` dealer sites are `Disallow: /` in robots.txt. They also add
nothing: their model list is byte-identical to the manufacturer catalog, and the
only difference is their own retail markup, which `IngestionService` never
touches anyway (`MANAGED_FIELDS` excludes `price`).

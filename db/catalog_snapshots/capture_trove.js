/*
 * Trove catalog capture — paste into the browser console on a Trove
 * MANUFACTURER host (e.g. https://trove.legacyhousing.com/homes).
 *
 * WHY THIS EXISTS
 * Trove sits behind a Vercel bot checkpoint that answers 429 to every
 * non-browser client, so our Ruby adapter cannot crawl it until the host
 * allowlists us. Capturing from a real browser session is the interim path.
 * The adapter parses this snapshot through exactly the same extractors it uses
 * for a live crawl, so a snapshot-backed run is a faithful rehearsal.
 *
 * CRAWL RIGHTS: run this on a manufacturer host only. trove.legacyhousing.com
 * allows crawling (robots.txt: Allow: /, sitemap published). The per-dealer
 * storefronts (*.buildtrove.com) are Disallow: / and must not be captured.
 *
 * USAGE
 *   1. Open https://trove.legacyhousing.com/homes and open DevTools console.
 *   2. Paste this whole file. It prints progress and downloads a JSON file.
 *      (Chrome may block the download the first time — allow it in the
 *      address bar, then run troveCapture() again.)
 *   3. bin/rails 'catalog:snapshot:load[<path>,legacy_housing]'
 *   4. Re-run the catalog source. Change detection (catalog_content_hash)
 *      updates only the homes whose content actually moved.
 *
 * Takes roughly 3 minutes for ~93 models at the built-in delay. Do not lower
 * DELAY_MS; it is there to stay a polite guest.
 */
(async function troveCapture() {
  const DELAY_MS = 140;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // ---- RSC flight payload helpers (mirror Catalog::NextFlightPayload) -------
  async function flightOf(url) {
    const html = await (await fetch(url)).text();
    const re = /self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)/g;
    const parts = [];
    let m;
    while ((m = re.exec(html))) parts.push(m[1]);
    try {
      return JSON.parse('"' + parts.join('').replace(/\r?\n/g, '\\n') + '"');
    } catch (e) {
      return parts.join('');
    }
  }

  // Balanced-brace scan respecting strings and escapes; Ruby side does the same.
  function decodeObjAt(buf, start) {
    let depth = 0, inStr = false, esc = false;
    for (let i = start; i < buf.length; i++) {
      const c = buf[i];
      if (esc) { esc = false; continue; }
      if (c === '\\') { esc = true; continue; }
      if (c === '"') { inStr = !inStr; continue; }
      if (inStr) continue;
      if (c === '{') depth++;
      else if (c === '}') { depth--; if (depth === 0) return buf.slice(start, i + 1); }
    }
    return null;
  }

  // Products are the objects carrying short_id + details + price.
  function productsFrom(flight) {
    const out = {};
    const mk = '"short_id":"';
    let i = 0;
    while ((i = flight.indexOf(mk, i)) !== -1) {
      let rec = null;
      for (let p = i; p > Math.max(0, i - 3000); p--) {
        if (flight[p] !== '{') continue;
        const c = decodeObjAt(flight, p);
        if (c && c.length > 800 && c.indexOf(mk) > -1) {
          try { const o = JSON.parse(c); if (o.short_id && o.details && o.price) rec = o; } catch (e) {}
        }
        if (rec) break;
      }
      if (rec && !out[rec.short_id]) out[rec.short_id] = rec;
      i += mk.length;
    }
    return out;
  }

  // A detail page carries neighbouring models' images too, and Trove labels
  // galleries at two levels ("Heritage h-3260-32a kitchen ..." vs "Heritage
  // kitchen ..."). Accept a series-only alt, but once the word after the series
  // looks like a model number it must be OUR model number.
  function altBelongs(alt, model, series) {
    const t = String(alt || '').toLowerCase().trim();
    if (!t) return false;
    if (model && t.startsWith(model)) return true;
    if (!series || !t.startsWith(series)) return false;
    const next = t.slice(series.length).trim().split(/\s+/)[0] || '';
    return !/\d/.test(next);
  }

  function galleryFrom(flight, name) {
    const model = String(name || '').toLowerCase().trim();
    const series = model.split(/\s+/)[0] || '';
    const objs = [];
    let i = 0;
    while ((i = flight.indexOf('"image_url"', i)) !== -1) {
      for (let p = i; p > Math.max(0, i - 600); p--) {
        if (flight[p] !== '{') continue;
        const c = decodeObjAt(flight, p);
        if (c && c.indexOf('"image_url"') > -1 && c.length < 1200) {
          try { objs.push(JSON.parse(c)); } catch (e) {}
          break;
        }
      }
      i += 11;
    }
    const seen = new Set(), out = [];
    objs.forEach((o) => {
      const u = o.image_url;
      if (!u || !/^https:\/\/[a-z0-9.\-]*b-cdn\.net\//i.test(u)) return;
      if (!altBelongs(o.alt, model, series)) return;
      if (seen.has(u)) return;
      seen.add(u);
      out.push({ image_url: u, alt: o.alt, image_tags: o.image_tags || [] });
    });
    return out;
  }

  // ---- capture -------------------------------------------------------------
  const origin = location.origin;
  console.log('[trove] reading index …');
  const index = productsFrom(await flightOf('/homes'));
  const slugs = Object.keys(index).sort();
  console.log(`[trove] ${slugs.length} models found; fetching galleries …`);

  const homes = [];
  for (let n = 0; n < slugs.length; n++) {
    const slug = slugs[n];
    const r = index[slug];
    let gallery = [];
    try {
      gallery = galleryFrom(await flightOf('/homes/' + slug), r.name);
    } catch (e) {
      console.warn('[trove] gallery failed for', slug, e);
    }

    // Fall back to the index thumbnails so a home is never image-less.
    const idxImgs = (r.images || []).map((i) => ({
      image_url: i.image_url, alt: i.alt, image_tags: i.image_tags || []
    }));
    const seen = new Set(), images = [];
    gallery.concat(idxImgs).forEach((i) => {
      if (i.image_url && !seen.has(i.image_url)) { seen.add(i.image_url); images.push(i); }
    });

    const d = r.details || {};
    homes.push({
      short_id: r.short_id, name: r.name, internal_name: r.internal_name,
      supplier_sku: r.supplier_sku, supplier_id: r.supplier_id,
      listed_status: r.listed_status, is_inventory: r.is_inventory,
      is_price_hidden: r.is_price_hidden, price: r.price,
      details: {
        width_inches: d.width_inches, length_inches: d.length_inches,
        square_feet: d.square_feet, bedrooms: d.bedrooms,
        bathrooms: d.bathrooms, half_bathrooms: d.half_bathrooms,
        sections: d.sections, covered_porch_sqft: d.covered_porch_sqft,
        kitchen_island_sqft: d.kitchen_island_sqft,
        descriptions: d.descriptions || [],
        embedded_media_urls: d.embedded_media_urls || []
      },
      images
    });

    if ((n + 1) % 10 === 0 || n === slugs.length - 1) {
      console.log(`[trove] ${n + 1}/${slugs.length}`);
    }
    await sleep(DELAY_MS);
  }

  const supplier = document.title.split('|').pop().trim() || origin;
  const snap = {
    schema: 'trove.catalog.snapshot/v1',
    base_url: origin,
    supplier_name: supplier,
    captured_at: new Date().toISOString(),
    home_count: homes.length,
    homes
  };

  const json = JSON.stringify(snap);
  const imgs = homes.reduce((a, h) => a + h.images.length, 0);
  console.log(`[trove] done — ${homes.length} homes, ${imgs} images ` +
              `(avg ${(imgs / homes.length).toFixed(1)}), ${(json.length / 1024).toFixed(0)} KB`);
  console.log(`[trove] homes with <3 images: ${homes.filter((h) => h.images.length < 3).length}`);

  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([json], { type: 'application/json' }));
  a.download = `trove_snapshot_${new Date().toISOString().slice(0, 10)}.json`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  window.__troveSnapshot = json; // kept so you can re-download without recapturing
})();

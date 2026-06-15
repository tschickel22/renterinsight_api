# frozen_string_literal: true

# =============================================================================
# Evangeline Home Center — onboarding import loader
# =============================================================================
# Idempotent, section-by-section import of Evangeline's MH Manager export into a
# fresh TEST company. Reads normalized CSVs (from evangeline_normalize.py) at
# EHC_CSV (default /data/evangeline). Column names verified against schema.rb.
#
# Run order (each idempotent — safe to re-run):
#   bin/rails evangeline:bootstrap        # company + 3 locations + 21st lender
#   bin/rails evangeline:custom_fields    # per-module custom fields (UI-visible)
#   bin/rails evangeline:sources
#   bin/rails evangeline:users
#   bin/rails evangeline:manufacturers
#   bin/rails evangeline:contractors
#   bin/rails evangeline:inventory
#   bin/rails evangeline:accounts
#   bin/rails evangeline:contacts
#   bin/rails evangeline:leads
#   bin/rails evangeline:deals
#   bin/rails evangeline:service_tickets
#   bin/rails evangeline:reconcile        # deferred-link sweep
#   bin/rails evangeline:all              # all of the above, in order
#   bin/rails evangeline:status           # batch counts
#   bin/rails evangeline:rollback CONFIRM=yes   # delete the test company (cascade)
#
# Flags (env):
#   EHC_CSV=/data/evangeline     path to normalized CSVs
#   EHC_BATCH=evangeline_2026_06 batch stamp (must match across steps)
#   DRY_RUN=1                    parse + report, write nothing
#   EHC_COMPANY_ID=NN            pin to existing company (skip bootstrap lookup)
# =============================================================================

require 'csv'

namespace :evangeline do
  BATCH   = ENV.fetch('EHC_BATCH', 'evangeline_2026_06')
  CSV_DIR = ENV.fetch('EHC_CSV', '/data/evangeline')
  DRY     = ENV['DRY_RUN'].present?

  COMPANY_NAME      = 'Evangeline Home Center'
  COMPANY_SUBDOMAIN = 'evangeline-homes'

  LOCATIONS = [
    { code: 'EHC',       name: 'Evangeline Home Center', address: '4040 NE Evangeline Thruway',    city: 'Carencro',    state: 'LA', zip: '70520', phone: '(337) 896-1773' },
    { code: 'H2G',       name: 'Homes 2 Geaux',          address: '3992 I-49 North Frontage Road', city: 'Opelousas',   state: 'LA', zip: '70570', phone: '(337) 948-0925' },
    { code: 'HOME LIFE', name: 'Home Life',              address: '2135 N Highway 231',            city: 'Panama City', state: 'FL', zip: '32405', phone: '(850) 215-3976' },
  ].freeze

  # ---- helpers --------------------------------------------------------------
  def log(msg) = puts(msg)
  def dry_note = DRY ? ' [DRY RUN — nothing written]' : ''

  def read_csv(name)
    path = File.join(CSV_DIR, "#{name}.csv")
    unless File.exist?(path)
      log("  ⚠️  #{name}.csv not found at #{path} — skipping")
      return []
    end
    CSV.read(path, headers: true).map(&:to_h)
  end

  def ehc_company
    @ehc_company ||= if ENV['EHC_COMPANY_ID'].present?
      Company.find(ENV['EHC_COMPANY_ID'])
    else
      Company.find_by(subdomain: COMPANY_SUBDOMAIN)
    end
  end

  def require_company!
    ehc_company || abort('No Evangeline company found. Run `evangeline:bootstrap` first (or pass EHC_COMPANY_ID=NN).')
  end

  def location_id_for(company, name)
    return nil if name.blank?
    (@loc_cache ||= {})[name] ||= company.locations.where('name ILIKE ?', name.strip).first&.id
  end

  def user_id_for(company, full_name)
    return nil if full_name.blank?
    @user_cache ||= {}
    key = full_name.strip.downcase
    return @user_cache[key] if @user_cache.key?(key)
    @user_cache[key] = company.users.where("LOWER(first_name || ' ' || last_name) = ?", key).first&.id
  end

  def source_id_for(company, name)
    return nil if name.blank?
    (@source_cache ||= {})[name] ||= company.sources.where('name ILIKE ?', name.strip).first&.id
  end

  def vehicle_id_for_serial(company, serial)
    return nil if serial.blank?
    company.vehicles.where(is_deleted: [false, nil])
           .where('serial_number = ? OR stock_number = ?', serial.strip, serial.strip).first&.id
  end

  def manufacturer_id_for(company, factory_name)
    return nil if factory_name.blank?
    (@mfr_cache ||= {})[factory_name] ||= company.manufacturers.where('name ILIKE ?', factory_name.strip).first&.id
  end

  def parse_date(v)
    return nil if v.blank?
    Date.parse(v.to_s) rescue nil
  end

  # Fetch the first present value among several possible column names. Lets the
  # loader accept both v2 (corrected) and v1 (legacy) CSV headers without
  # silently writing blanks when a header name shifts.
  def col(row, *names)
    names.each do |nm|
      v = row[nm]
      return v if v.to_s.strip != ''
    end
    nil
  end

  # Flip a raw "Last, First[, Suffix]" buyer string into a display "First Last
  # [Suffix]" household name, preserving "&"-joined multi-buyer households:
  #   "Hoss, Joshua"                              -> "Joshua Hoss"
  #   "Davis, Nathaniel, Jr. & Davis, Lindsay"    -> "Nathaniel Davis Jr. & Lindsay Davis"
  #   "Lejeune, Nathaniel & , Jasmine"            -> "Nathaniel Lejeune & Jasmine"
  def flip_household_name(raw)
    return nil if raw.blank?
    flipped = raw.to_s.split('&').map do |part|
      bits = part.split(',').map(&:strip).reject(&:blank?)
      next nil if bits.empty?
      next bits.join(' ') if bits.size == 1          # single token, nothing to flip
      last = bits.shift
      [bits.shift, last, *bits].reject(&:blank?).join(' ')  # first, last, suffix(es)
    end.compact.reject(&:blank?)
    flipped.empty? ? nil : flipped.join(' & ')
  end

  # Return the email only if it passes the same format check the models enforce;
  # otherwise nil. Prevents one malformed source email from aborting a whole task.
  def clean_email(v)
    e = v.to_s.strip.downcase
    return nil if e.blank?
    e =~ URI::MailTo::EMAIL_REGEXP ? e : nil
  end

  # Split an already-flipped display name ("First Last" or "First Last & First2
  # Last2") into [first, last] for the primary person. Used when a CSV provides
  # a single `name` column instead of discrete first/last columns.
  def split_name(full)
    primary = full.to_s.split('&').first.to_s.strip   # first buyer only
    return ['', ''] if primary.blank?
    parts = primary.split(/\s+/)
    return [parts.first, ''] if parts.size == 1
    [parts.first, parts[1..].join(' ')]
  end

  # Create a record with all side-effect callbacks suppressed. The bulk-import
  # flags (defined on ApplicationRecord) turn off webhooks, notifications,
  # per-row activity logging, and workflow emits. Without this, every single
  # create fires WebhookNotifiable -> as_json -> open_deals_count (extra
  # queries) plus workflow/notification callbacks — which is what made earlier
  # runs take hours over the remote DB connection. Returns the saved record.
  def make!(relation, attrs)
    rec = relation.new(attrs)
    rec.skip_webhooks = true
    rec.skip_notifications = true
    rec.skip_activity_tracking = true
    rec.skip_workflows = true
    rec.save!
    rec
  end

  # ===========================================================================
  # BOOTSTRAP
  # ===========================================================================
  desc 'Create Evangeline company + 3 locations + 21st Mortgage lender'
  task bootstrap: :environment do
    log("== Evangeline bootstrap ==#{dry_note}")

    company = Company.find_by(subdomain: COMPANY_SUBDOMAIN)
    if company
      log("  Company exists: #{company.name} (id=#{company.id})")
    elsif DRY
      log("  Would create company '#{COMPANY_NAME}' subdomain=#{COMPANY_SUBDOMAIN} industry=manufactured_housing")
    else
      company = Company.create!(
        name: COMPANY_NAME, subdomain: COMPANY_SUBDOMAIN,
        industry: 'manufactured_housing', status: 'trial',
        sms_provisioning_mode: 'platform', fiscal_year_start_month: 1,
        use_rbac_system: true
      )
      log("  ✅ Company id=#{company.id} (auto-seeded COA + 21st allowance defaults + default location)")
    end

    if company && !DRY
      main = company.locations.where('name ILIKE ?', 'Main Location').first
      LOCATIONS.each_with_index do |loc, idx|
        existing = company.locations.where('code = ? OR name ILIKE ?', loc[:code], loc[:name]).first
        target   = existing || (idx.zero? ? main : nil)
        attrs = {
          name: loc[:name], code: loc[:code], address_line1: loc[:address],
          city: loc[:city], state: loc[:state], zip_code: loc[:zip],
          phone: loc[:phone], active: true, timezone: 'America/Chicago'
        }
        if target
          target.update!(attrs)
          log("  ✅ Location ready: #{loc[:name]} (#{loc[:code]}) id=#{target.id}")
        else
          created = company.locations.create!(attrs)
          log("  ✅ Location created: #{loc[:name]} (#{loc[:code]}) id=#{created.id}")
        end
      end

      lender = company.lenders.where('name ILIKE ?', '21st Mortgage').first
      if lender
        log("  Lender exists: #{lender.name}")
      else
        lender = company.lenders.create!(name: '21st Mortgage', active: true)
        log("  ✅ Lender '21st Mortgage' (id=#{lender.id}) — Max Advance schedule seeded")
      end
    end

    log("  Done.#{dry_note}")
  end

  # ===========================================================================
  # CUSTOM FIELDS  (custom_fields table: module/name/label/field_type/section)
  # ===========================================================================
  desc 'Create per-module custom fields'
  task custom_fields: :environment do
    company = require_company!
    log("== Custom fields ==#{dry_note}")

    defs = {
      'inventory_mh' => [
        { name: 'building_code', label: 'Building Code', field_type: 'text', section: 'Basic Info' },
        { name: 'hud_number',    label: 'HUD Number',    field_type: 'text', section: 'Basic Info' },
      ],
      'accounts' => [
        { name: 'file_number',    label: 'File Number',    field_type: 'text', section: 'Details' },
        { name: 'finance_method', label: 'Finance Method', field_type: 'text', section: 'Details' },
        { name: 'date_sold',      label: 'Date Sold',      field_type: 'date', section: 'Details' },
        { name: 'ehc_serial',     label: 'Home Serial #',  field_type: 'text', section: 'Details' },
        { name: 'ehc_full_serial', label: 'Full Serial #', field_type: 'text', section: 'Home' },
        { name: 'series',         label: 'Series',         field_type: 'text', section: 'Home' },
        { name: 'model',          label: 'Model',          field_type: 'text', section: 'Home' },
        { name: 'model_year',     label: 'Model Year',     field_type: 'text', section: 'Home' },
        { name: 'size',           label: 'Size',           field_type: 'text', section: 'Home' },
        { name: 'building_code',  label: 'Building Code',  field_type: 'text', section: 'Home' },
        { name: 'hud_number',     label: 'HUD Number',     field_type: 'text', section: 'Home' },
        { name: 'county',         label: 'County',         field_type: 'text', section: 'Details' },
      ],
      'leads' => [
        { name: 'rating',     label: 'Rating (legacy)',  field_type: 'text', section: 'Details' },
        { name: 'wd_serial',  label: 'Working Home Serial', field_type: 'text', section: 'Details' },
        { name: 'home_interest', label: 'Home Interest',  field_type: 'text', section: 'Details' },
        { name: 'ordered_model', label: 'Ordered Model',  field_type: 'text', section: 'Details' },
      ],
      'deals' => [
        { name: 'close_reason',      label: 'Close Reason',      field_type: 'text', section: 'Details' },
        { name: 'file_number',       label: 'File Number',       field_type: 'text', section: 'Details' },
        { name: 'default_surcharge', label: 'Default Surcharge', field_type: 'text', section: 'Details' },
      ],
      'service_tickets' => [
        { name: 'warranty_start_date', label: 'Warranty Start Date', field_type: 'date', section: 'Details' },
        { name: 'building_code',       label: 'Building Code',       field_type: 'text', section: 'Details' },
        { name: 'hud_number',          label: 'HUD Number',          field_type: 'text', section: 'Details' },
      ],
    }

    created = 0
    defs.each do |mod, fields|
      fields.each do |f|
        if company.custom_fields.where(module: mod, name: f[:name]).exists?
          log("  exists: #{mod}.#{f[:name]}"); next
        end
        if DRY
          log("  would create: #{mod}.#{f[:name]} (#{f[:field_type]})")
        else
          company.custom_fields.create!(
            module: mod, name: f[:name], label: f[:label],
            field_type: f[:field_type], section: f[:section],
            is_active: true, required: false
          )
          created += 1; log("  ✅ #{mod}.#{f[:name]}")
        end
      end
    end
    log("  Created #{created} custom fields.#{dry_note}")
  end

  # ===========================================================================
  # SOURCES
  # ===========================================================================
  desc 'Import lead sources'
  task sources: :environment do
    company = require_company!
    log("== Sources ==#{dry_note}")
    n = 0
    read_csv('sources').each do |row|
      name = row['name'].to_s.strip
      next if name.blank? || company.sources.where('name ILIKE ?', name).exists?
      if DRY then log("  would create source: #{name}")
      else company.sources.create!(name: name, is_active: true); n += 1 end
    end
    log("  Created #{n} sources.#{dry_note}")
  end

  # ===========================================================================
  # USERS
  # ===========================================================================
  desc 'Import users with role assignments + location scope'
  task users: :environment do
    company = require_company!
    log("== Users ==#{dry_note}")
    n = 0
    read_csv('users').each do |row|
      email = row['email'].to_s.strip.downcase
      next if email.blank?

      user = User.find_by(email: email)
      if user
        log("  exists: #{email}")
      elsif DRY
        log("  would create user: #{email} role=#{row['role_key']} tier=#{row['access_tier']} loc=#{row['location_scope']}"); next
      else
        user = company.users.create!(
          email: email, first_name: row['first_name'], last_name: row['last_name'],
          password: SecureRandom.urlsafe_base64(16), status: 'active',
          role: (row['role_key'] == 'company_admin' ? 'admin' : 'user')
        )
        n += 1
      end

      next if DRY || user.nil?

      role = Role.find_by(key: row['role_key'], is_system_role: true)
      unless role
        log("  ⚠️  role key '#{row['role_key']}' not found — skipping assignment for #{email}"); next
      end

      if row['access_tier'] == 'location' && row['location_scope'].present?
        loc_id = location_id_for(company, row['location_scope'])
        if loc_id
          UserRoleAssignment.find_or_create_by!(user: user, role: role, tier: 'location', location_id: loc_id) do |a|
            a.company_id = company.id
          end
          UserLocation.find_or_create_by!(user: user, location_id: loc_id) { |ul| ul.company_id = company.id; ul.active = true }
        end
      else
        UserRoleAssignment.find_or_create_by!(user: user, role: role, tier: 'company', location_id: nil) do |a|
          a.company_id = company.id
        end
        company.locations.active.each do |l|
          UserLocation.find_or_create_by!(user: user, location_id: l.id) { |ul| ul.company_id = company.id; ul.active = true }
        end
      end
    end
    log("  Created #{n} users.#{dry_note}")
  end

  # ===========================================================================
  # MANUFACTURERS
  # ===========================================================================
  desc 'Import manufacturers/factories'
  task manufacturers: :environment do
    company = require_company!
    log("== Manufacturers ==#{dry_note}")
    n = 0
    read_csv('manufacturers').each do |row|
      name = row['name'].to_s.strip
      next if name.blank? || company.manufacturers.where('name ILIKE ?', name).exists?
      if DRY then log("  would create manufacturer: #{name}"); next end
      mfr = Manufacturer.create!(
        company_id: company.id, name: name, code: row['factory_code'].presence,
        active: row['active'] != 'false', industry_type: 'manufactured_housing',
        contact_email: row['service_mgr_email'].presence,
        contact_phone: row['service_mgr_phone'].to_s.strip.slice(0, 20).presence,
        contact_name:  row['service_mgr_name'].presence,
        claim_email:   row['service_mgr_email'].presence
      )
      CompanyManufacturer.find_or_create_by!(company_id: company.id, manufacturer_id: mfr.id) { |cm| cm.active = true }
      n += 1
    end
    log("  Created #{n} manufacturers.#{dry_note}")
  end

  # ===========================================================================
  # CONTRACTORS  (vendors; real insurance columns)
  # ===========================================================================
  desc 'Import contractors as vendors'
  task contractors: :environment do
    company = require_company!
    log("== Contractors ==#{dry_note}")
    n = 0
    read_csv('contractors').each do |row|
      name = row['name'].to_s.strip
      next if name.blank?
      next if company.vendors.where('name ILIKE ? AND vendor_type = ?', name, 'contractor').exists?
      if DRY then log("  would create contractor: #{name}"); next end
      company.vendors.create!(
        name: name, vendor_type: 'contractor', active: true, status: 'active',
        contact_name: name,
        address_line1: row['address'].presence, city: row['city'].presence,
        state: row['state'].presence, zip_code: row['zip'].presence,
        phone: row['phone'].presence, email: row['email'].presence,
        insurance_provider: row['gl_insurer'].presence,
        insurance_expiry: parse_date(row['gl_expiration']),
        notes: [
          row['wc_insurer'].present? ? "Workers' Comp: #{row['wc_insurer']} (exp #{row['wc_expiration']})" : nil,
          row['email2'].present? ? "Alt email: #{row['email2']}" : nil,
          row['phone2'].present? ? "Alt phone: #{row['phone2']}" : nil,
        ].compact.join("\n").presence
      )
      n += 1
    end
    log("  Created #{n} contractors.#{dry_note}")
  end

  # ===========================================================================
  # INVENTORY
  # ===========================================================================
  desc 'Import inventory homes'
  task inventory: :environment do
    company = require_company!
    log("== Inventory ==#{dry_note}")
    n = 0
    read_csv('inventory').each do |row|
      serial = row['serial_number'].to_s.strip
      serial = "ORDER-#{row['source_model_id']}" if serial.blank? && row['source_model_id'].present?
      next if serial.blank?
      next if company.vehicles.where(is_deleted: [false, nil]).where('serial_number = ?', serial).exists?
      if DRY then log("  would create home: #{serial} (#{row['status']}) #{row['make']} #{row['model']}"); next end

      v = company.vehicles.new(
        listing_type: 'manufactured_home', status: row['status'].presence || 'available',
        serial_number: serial, stock_number: row['stock_number'].presence,
        year: (row['year'].presence || Date.current.year),
        make: row['make'].presence || 'Unknown', model: row['model'].presence || 'Unknown',
        bedrooms: row['bedrooms'].presence || 0, bathrooms: row['bathrooms'].presence || 0,
        msrp: row['msrp'].presence, dealer_cost: row['dealer_cost'].presence,
        condition: (row['condition'].presence || 'new'),
        wind_zone: row['wind_zone'].presence, notes: row['notes'].presence,
        location_id: location_id_for(company, row['location_name']),
        virtual_tour_url: row['virtual_tour_url'].presence,
        custom_field_values: {
          'building_code' => row['building_code'], 'hud_number' => row['hud_number'],
          'import_batch'  => BATCH
        }.compact
      )
      v.date_in_stock = parse_date(row['date_acquired']) if row['date_acquired'].present?
      v.save!
      n += 1
    end
    log("  Created #{n} homes.#{dry_note}")
  end

  # ===========================================================================
  # ACCOUNTS  (billing_* address columns, postal_code)
  # ===========================================================================
  desc 'Import accounts (buyer households)'
  task accounts: :environment do
    company = require_company!
    log("== Accounts ==#{dry_note}")
    n = 0
    read_csv('accounts').each do |row|
      raw_name = col(row, 'household_flipped').presence || flip_household_name(row['name']).presence || row['name'].to_s.strip
      name = raw_name.to_s.strip
      next if name.blank? || company.accounts.where('name ILIKE ?', name).exists?
      if DRY then log("  would create account: #{name}"); next end
      make!(company.accounts, {
        name: name, account_type: 'customer', status: 'active',
        email: clean_email(col(row, 'email', 'email_1', 'email_2')),
        location_id: location_id_for(company, col(row, 'location_name', 'location_code')),
        source_id: source_id_for(company, col(row, 'source', 'source_name')),
        owner_id: user_id_for(company, col(row, 'salesperson')),
        billing_street: col(row, 'billing_street', 'address1'), billing_city: col(row, 'billing_city', 'city'),
        billing_state: col(row, 'billing_state', 'state'), billing_postal_code: col(row, 'billing_postal_code', 'zip'),
        notes: col(row, 'notes'),
        custom_field_values: {
          'file_number' => row['file_number'], 'finance_method' => row['finance_method'],
          'date_sold' => row['date_sold'],
          'ehc_serial' => col(row, 'ehc_serial', 'serial_number'),
          'ehc_full_serial' => row['ehc_full_serial'],
          'series' => row['series'], 'model' => row['model'], 'model_year' => row['model_year'],
          'size' => row['size'], 'building_code' => row['building_code'], 'hud_number' => row['hud_number'],
          'county' => row['county'],
          'import_batch' => BATCH
        }.compact
      })
      n += 1
    end
    log("  Created #{n} accounts.#{dry_note}")
  end

  # ===========================================================================
  # CONTACTS
  # ===========================================================================
  desc 'Import contacts (attached to accounts)'
  task contacts: :environment do
    company = require_company!
    log("== Contacts ==#{dry_note}")
    n = 0
    read_csv('contacts').each do |row|
      first = row['first_name'].to_s.strip; last = row['last_name'].to_s.strip
      next if first.blank? && last.blank?
      acct = company.accounts.where('name ILIKE ?', row['account_name'].to_s.strip).first
      if acct && company.contacts.where('first_name ILIKE ? AND last_name ILIKE ? AND account_id = ?', first, last, acct.id).exists?
        next
      end
      if DRY then log("  would create contact: #{first} #{last} -> #{row['account_name']}"); next end
      make!(company.contacts, {
        first_name: first, last_name: last,
        email: clean_email(row['email']), phone: row['phone'].presence,
        is_primary: row['is_primary'] == 'true', account_id: acct&.id,
        location_id: location_id_for(company, row['location_name']),
        custom_field_values: { 'import_batch' => BATCH }
      })
      n += 1
    end
    log("  Created #{n} contacts.#{dry_note}")
  end

  # ===========================================================================
  # LEADS  (rating -> custom_field_values; no rating column)
  # Fast path: in-memory dedup (one query up front), cached lookups, batched
  # inserts in a single transaction. Avoids ~10k cross-country round-trips.
  # ===========================================================================
  desc 'Import leads'
  task leads: :environment do
    company = require_company!
    log("== Leads ==#{dry_note}")

    rows = read_csv('leads')
    log("  #{rows.size} rows in CSV")

    # Build the existing-key set ONCE (first+last+email, downcased) instead of
    # querying per row. Pluck is a single round trip.
    existing = {}
    company.leads.pluck(:first_name, :last_name, :email).each do |f, l, e|
      existing["#{f.to_s.strip.downcase}|#{l.to_s.strip.downcase}|#{e.to_s.strip.downcase}"] = true
    end
    log("  #{existing.size} leads already present")

    # Warm the lookup caches once (source / owner / location) so per-row calls
    # are pure hash hits, not queries.
    company.sources.pluck(:name, :id).each { |nm, id| (@source_cache ||= {})[nm] = id }
    company.users.pluck(Arel.sql("LOWER(first_name || ' ' || last_name)"), :id).each { |nm, id| (@user_cache ||= {})[nm] = id }
    company.locations.pluck(:name, :id).each { |nm, id| (@loc_cache ||= {})[nm] = id }
    company.locations.pluck(:code, :id).each { |cd, id| (@loc_cache ||= {})[cd] = id if cd.present? }

    # Serial -> vehicle_id cache for working-deal lead links (single round trip).
    veh_by_serial = {}
    company.vehicles.where(is_deleted: [false, nil]).pluck(:serial_number, :stock_number, :id).each do |sn, st, id|
      veh_by_serial[sn.to_s.strip] = id if sn.present?
      veh_by_serial[st.to_s.strip] = id if st.present?
    end
    log("  #{veh_by_serial.size} vehicle serial/stock keys cached for linking")

    n = 0; skipped = 0; failed = 0
    sample_errors = []
    now = Time.current
    pending = []   # plain attribute hashes for bulk insert_all

    flush = lambda do
      return if pending.empty? || DRY
      # insert_all skips validations/callbacks (fine for import) and sends the
      # whole chunk in ONE round trip instead of one-per-row.
      company.leads.insert_all(pending)
      n += pending.size
      pending = []
      print "\r  inserted #{n}..."
    end

    rows.each do |row|
      first = col(row, 'first_name').to_s.strip; last = col(row, 'last_name').to_s.strip
      if first.blank? && last.blank?
        first, last = split_name(col(row, 'name'))   # v2 CSV provides a single flipped `name`
      end
      next if first.blank? && last.blank?

      em = clean_email(row['email'])
      key = "#{first.downcase}|#{last.downcase}|#{em.to_s.downcase}"
      if existing[key]
        skipped += 1; next
      end
      existing[key] = true # guard against in-file dupes

      next if DRY

      wd_serial = col(row, 'link_inventory_serial', 'wd_serial').to_s.strip
      vehicle_id = veh_by_serial[wd_serial]

      pending << {
        company_id: company.id,
        first_name: first, last_name: last,
        email: em, phone: row['phone'].presence,
        status: row['status'].presence || 'open',
        source_id: (@source_cache || {})[col(row, 'source', 'source_name')],
        owner_id: (@user_cache || {})[col(row, 'salesperson', 'owner').to_s.strip.downcase],
        location_id: (@loc_cache || {})[col(row, 'location_name', 'location_code')],
        notes: col(row, 'notes'),
        vehicle_id: vehicle_id,
        interests_requirements: col(row, 'home_interest'),
        custom_field_values: {
          'rating' => row['rating'].presence,
          'home_interest' => row['home_interest'].presence,
          'wd_serial' => wd_serial.presence,
          'ordered_model' => row['ordered_model'].presence,
          'import_batch' => BATCH
        }.compact,
        created_at: now, updated_at: now
      }
      flush.call if pending.size >= 1000
    end
    flush.call
    puts ''
    log("  Created #{n} leads, skipped #{skipped} (dupes/existing), failed #{failed}.#{dry_note}")
    if sample_errors.any?
      log("  First failures:")
      sample_errors.each { |m| log("    - #{m}") }
    end
  end

  # ===========================================================================
  # DEALS  (no status column — uses stage; owner_id + user_id; value)
  # Match on the clean contact_first/contact_last (account_name in this CSV is
  # raw "Last, First" and won't match flipped account names). Account comes via
  # the matched contact. Stage mapped to a valid pipeline stage.
  # ===========================================================================
  VALID_DEAL_STAGES = %w[prospecting qualification needs_analysis proposal negotiation closed_won closed_lost].freeze

  desc 'Import deals'
  task deals: :environment do
    company = require_company!
    log("== Deals ==#{dry_note}")
    n = 0; skipped = 0; orphan = 0; created_acct = 0; created_contact = 0
    orphan_names = []

    read_csv('deals').each do |row|
      name = row['name'].to_s.strip
      if name.blank? || company.deals.where('name ILIKE ?', name).exists?
        skipped += 1; next
      end

      # Match the contact by the CLEAN first/last fields (not the raw account_name).
      cf = row['contact_first'].to_s.strip
      cl = row['contact_last'].to_s.strip
      contact = nil
      if cf.present? || cl.present?
        contact = company.contacts.where('first_name ILIKE ? AND last_name ILIKE ?', cf, cl).first
      end
      # Account comes through the contact; fall back to a direct name match just in case.
      acct = contact&.account_id ? Account.find_by(id: contact.account_id) : nil
      acct ||= company.accounts.where('name ILIKE ?', row['account_name'].to_s.strip).first

      owner_id = user_id_for(company, row['owner'])

      # The model requires an account OR a contact. Evangeline's active-deal buyers
      # are NOT in the accounts/contacts import (those are the sold-customer sets),
      # so most rows resolve nothing. Create the household account + primary contact
      # inline from the deal row rather than orphaning the deal. Idempotent: re-find
      # by the flipped name / (first,last,account) before creating in case a prior
      # run already made them.
      if acct.nil? && contact.nil?
        acct_name = flip_household_name(row['account_name']).presence ||
                    [cf, cl].reject(&:blank?).join(' ').presence || name
        acct = company.accounts.where('name ILIKE ?', acct_name).first
        if acct.nil? && !DRY
          acct = make!(company.accounts, {
            name: acct_name, account_type: 'customer', status: 'active',
            email: clean_email(row['email']), phone: row['phone'].presence,
            location_id: location_id_for(company, row['location_name']),
            source_id: source_id_for(company, row['source_name']),
            owner_id: owner_id,
            custom_field_values: { 'import_batch' => BATCH }
          })
          created_acct += 1
        end

        if (cf.present? || cl.present?) && acct
          contact = company.contacts
            .where('first_name ILIKE ? AND last_name ILIKE ? AND account_id = ?', cf, cl, acct.id).first
          if contact.nil? && !DRY
            contact = make!(company.contacts, {
              first_name: cf, last_name: cl,
              email: clean_email(row['email']), phone: row['phone'].presence,
              is_primary: true, account_id: acct.id,
              location_id: location_id_for(company, row['location_name']),
              custom_field_values: { 'import_batch' => BATCH }
            })
            created_contact += 1
          end
        end

        # Still nothing to attach to (only possible in DRY, or a blank-name row) —
        # record it and skip rather than abort.
        if acct.nil? && contact.nil?
          orphan += 1
          orphan_names << name if orphan_names.size < 15
          next unless DRY
        end
      end

      # Map source stage -> valid pipeline stage. All Evangeline deals are active
      # 'Working Deal'/'working' rows -> 'negotiation'.
      raw_stage = row['stage'].to_s.strip.downcase
      stage = VALID_DEAL_STAGES.include?(raw_stage) ? raw_stage : 'negotiation'

      vehicle_id = vehicle_id_for_serial(company, row['vehicle_serial'].presence || row['vehicle_stock'])

      if DRY
        log("  would create deal: #{name} (acct=#{acct&.id || 'NEW'} contact=#{contact&.id || 'NEW'} vehicle=#{vehicle_id} stage=#{stage})"); next
      end

      make!(company.deals, {
        name: name, stage: stage,
        account_id: acct&.id, contact_id: contact&.id, vehicle_id: vehicle_id,
        owner_id: owner_id, user_id: owner_id,
        source_id: source_id_for(company, row['source_name']),
        location_id: location_id_for(company, row['location_name']),
        customer_name: name, lead_source: row['source_name'].presence,
        down_payment: row['down_payment'].presence,
        notes: row['notes'].presence,
        custom_field_values: {
          'close_reason' => row['close_reason'], 'file_number' => row['file_number'],
          'default_surcharge' => row['default_surcharge'], 'import_batch' => BATCH
        }.compact
      })
      n += 1
    end
    log("  Created #{n} deals, skipped #{skipped} (existing), orphaned #{orphan} (unresolvable).#{dry_note}")
    log("  Inline-created #{created_acct} buyer accounts + #{created_contact} contacts from deal rows.#{dry_note}")
    if orphan_names.any?
      log("  Orphaned deals (no matching account or contact):")
      orphan_names.each { |nm| log("    - #{nm}") }
    end
  end

  # ===========================================================================
  # SERVICE TICKETS  (+ warranty claims). Dedup on ticket_number (real column);
  # custom_fields is TEXT (JSON-serialized in Ruby) — never SQL-queried.
  # ===========================================================================
  desc 'Import service tickets and warranty claims'
  task service_tickets: :environment do
    company = require_company!
    log("== Service tickets ==#{dry_note}")
    n = 0; claims = 0
    read_csv('service_tickets').each do |row|
      title = col(row, 'title', 'description').to_s.strip.presence || 'Imported warranty service ticket'
      desc  = col(row, 'description').to_s.strip.presence || title
      ticket_no = "EHC-#{col(row, 'source_id', 'source_ticket_id')}"   # stable, unique, indexed dedup key

      next if company.service_tickets.where(ticket_number: ticket_no).exists?

      acct_name = col(row, 'account_name', 'customer')
      acct = acct_name.present? ? company.accounts.where('name ILIKE ?', acct_name.to_s.strip).first : nil
      vehicle_id = vehicle_id_for_serial(company, col(row, 'vehicle_serial', 'serial'))
      mfr_id = manufacturer_id_for(company, col(row, 'factory_name', 'factory'))
      claim_status = col(row, 'claim_status')
      is_warranty = col(row, 'is_warranty').to_s == 'true' || claim_status.present? || col(row, 'factory').present?

      if DRY then log("  would create ticket: #{ticket_no} status=#{col(row,'ticket_status','status')} warranty=#{is_warranty} claim=#{claim_status}"); next end

      ticket = make!(company.service_tickets, {
        ticket_number: ticket_no, title: title, description: desc,
        status: col(row, 'ticket_status', 'status').presence || 'open', priority: row['priority'].presence || 'medium',
        account_id: acct&.id, vehicle_id: vehicle_id,
        location_id: location_id_for(company, col(row, 'location_name', 'location_code')),
        is_warranty_suspected: is_warranty,
        is_warranty_confirmed: is_warranty && claim_status.present?,
        custom_fields: {
          'warranty_start_date' => row['warranty_start_date'], 'building_code' => row['building_code'],
          'hud_number' => row['hud_number'], 'import_batch' => BATCH
        }.compact
      })
      n += 1

      if claim_status.present? && mfr_id
        summary = col(row, 'notes_internal', 'description').to_s.strip.presence ||
                  "Imported warranty claim (batch #{BATCH})"
        claim = WarrantyClaim.new(
          company_id: company.id, location_id: ticket.location_id,
          service_ticket_id: ticket.id, manufacturer_id: mfr_id,
          estimated_amount: 0, parts: [], labor: [],
          status: claim_status,
          submitted_at: (parse_date(row['warranty_start_date']) || Time.current),
          closed_at: (claim_status == 'closed' ? Time.current : nil),
          submitted_by: 'Import', notes_internal: summary
        )
        claim.skip_webhooks = true; claim.skip_notifications = true
        claim.skip_activity_tracking = true; claim.skip_workflows = true
        claim.save!
        ticket.update_columns(warranty_claim_id: claim.id, is_warranty_confirmed: true)
        claims += 1
      end
    end
    log("  Created #{n} tickets, #{claims} warranty claims.#{dry_note}")
  end

  # ===========================================================================
  # RECONCILE
  # ===========================================================================
  desc 'Reconcile deferred import links'
  task reconcile: :environment do
    company = require_company!
    log('== Reconcile deferred links ==')
    if defined?(ImportExport::LinkResolver)
      log("  Resolved #{ImportExport::LinkResolver.new(company).reconcile_all!} deferred links.")
    else
      log('  LinkResolver not present — skipping.')
    end
  end

  # ===========================================================================
  # ALL
  # ===========================================================================
  desc 'Run the full import in order'
  task all: :environment do
    %w[bootstrap custom_fields sources users manufacturers contractors
       inventory accounts contacts leads deals service_tickets reconcile].each do |t|
      Rake::Task["evangeline:#{t}"].invoke
    end
  end

  # ===========================================================================
  # STATUS
  # ===========================================================================
  desc 'Show import counts'
  task status: :environment do
    c = require_company!
    log("== Company #{c.id} (#{c.name}) ==")
    log("  Locations: #{c.locations.count}  Users: #{c.users.count}  Sources: #{c.sources.count}")
    log("  Mfrs: #{c.manufacturers.count}  Vendors: #{c.vendors.count}  Homes: #{c.vehicles.where(is_deleted: [false, nil]).count}")
    log("  Accounts: #{c.accounts.where(is_deleted: [false, nil]).count}  Contacts: #{c.contacts.where(is_deleted: [false, nil]).count}")
    log("  Leads: #{c.leads.count}  Deals: #{c.deals.count}  Tickets: #{c.service_tickets.count}  Claims: #{c.warranty_claims.count}")
  end

  # ===========================================================================
  # ROLLBACK  (TEST company: delete all data in FK-safe order, then the company)
  # The model-level cascade is incomplete (service_tickets.account_id has a
  # non-cascading FK), so company.destroy! fails. Delete children before
  # parents explicitly, scoped to this company, inside one transaction.
  # ===========================================================================
  desc 'Delete the Evangeline TEST company and ALL its data (FK-safe)'
  task rollback: :environment do
    company = require_company!
    if company.subdomain != COMPANY_SUBDOMAIN
      abort("Refusing: company #{company.id} is not the import test company (#{COMPANY_SUBDOMAIN}).")
    end
    unless ENV['CONFIRM'] == 'yes'
      abort("This DELETES company #{company.id} (#{company.name}) and every record under it. Re-run with CONFIRM=yes.")
    end
    cid = company.id
    log("== Deleting company #{cid} (#{company.name}) and all children (FK-safe, multi-pass) ==")

    # No privilege to disable FK triggers on managed Postgres, so we can't just
    # SET session_replication_role. Instead: gather every table with a
    # company_id, then delete in repeated passes. Each pass deletes from every
    # remaining table inside its OWN savepoint; a table that still has children
    # (FK violation) is rolled back to the savepoint and retried next pass,
    # after its children have been cleared. Loop until everything is gone or a
    # full pass makes zero progress (then report what's stuck).
    conn = ActiveRecord::Base.connection

    # Pre-clear known company-less descendant tables that the company_id sweep
    # can't reach. These hold FKs up a chain to a company-scoped ancestor but
    # carry no company_id of their own, so we delete them via subquery on the
    # ancestor's company_id. Order: deepest descendant first.
    #   project_template_phase_tasks -> project_template_phases -> project_templates(company_id)
    company_less_deletes = [
      ["project_template_phase_tasks",
       "DELETE FROM project_template_phase_tasks WHERE project_template_phase_id IN (" \
       "SELECT ptp.id FROM project_template_phases ptp " \
       "JOIN project_templates pt ON pt.id = ptp.project_template_id " \
       "WHERE pt.company_id = #{cid.to_i})"],
      ["project_template_phases",
       "DELETE FROM project_template_phases WHERE project_template_id IN (" \
       "SELECT id FROM project_templates WHERE company_id = #{cid.to_i})"],
      # Tables that FK into locations but carry no company_id of their own.
      ["location_activities",
       "DELETE FROM location_activities WHERE location_id IN (" \
       "SELECT id FROM locations WHERE company_id = #{cid.to_i})"],
      ["location_manufacturers",
       "DELETE FROM location_manufacturers WHERE location_id IN (" \
       "SELECT id FROM locations WHERE company_id = #{cid.to_i})"],
    ]
    company_less_deletes.each do |label, sql|
      begin
        ActiveRecord::Base.transaction(requires_new: true) do
          n = conn.delete(sql)
          log("  [pre] deleted #{n} from #{label}") if n && n > 0
        end
      rescue ActiveRecord::InvalidForeignKey
        log("  [pre] #{label} still blocked — will rely on main loop")
      end
    end

    remaining = conn.tables.select do |t|
      (conn.column_exists?(t, :company_id) rescue false)
    end
    # locations + companies handled explicitly at the very end.
    remaining -= %w[companies]

    pass = 0
    loop do
      pass += 1
      progressed = false
      stuck = []
      remaining.dup.each do |table|
        begin
          n = nil
          ActiveRecord::Base.transaction(requires_new: true) do
            n = conn.delete("DELETE FROM #{conn.quote_table_name(table)} WHERE company_id = #{cid.to_i}")
          end
          # table fully cleared for this company
          remaining.delete(table)
          if n && n > 0
            progressed = true
            log("  [pass #{pass}] deleted #{n} from #{table}")
          else
            # nothing to delete; drop it from the worklist silently
          end
        rescue ActiveRecord::InvalidForeignKey
          stuck << table   # has children still; retry next pass
        end
      end
      break if remaining.empty?
      unless progressed
        abort("Rollback stalled — these tables still have undeletable rows (unmapped FK chain): #{stuck.join(', ')}. Aborting with NOTHING further deleted; tell Claude which tables are listed.")
      end
    end

    # locations last (it has company_id but other rows FK into it), then company.
    ActiveRecord::Base.transaction do
      if conn.column_exists?(:locations, :company_id)
        ln = conn.delete("DELETE FROM locations WHERE company_id = #{cid.to_i}")
        log("  deleted #{ln} from locations")
      end
      conn.delete("DELETE FROM companies WHERE id = #{cid.to_i}")
      log("  deleted company #{cid}")
    end
    log('  ✅ Company and all associated records removed.')
  end
end

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
      ],
      'leads' => [
        { name: 'rating',     label: 'Rating (legacy)',  field_type: 'text', section: 'Details' },
        { name: 'wd_serial',  label: 'Working Home Serial', field_type: 'text', section: 'Details' },
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

      role = Role.find_by(role_key: row['role_key'], is_system_role: true)
      unless role
        log("  ⚠️  role_key '#{row['role_key']}' not found — skipping assignment for #{email}"); next
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
        contact_phone: row['service_mgr_phone'].presence,
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
      name = row['name'].to_s.strip
      next if name.blank? || company.accounts.where('name ILIKE ?', name).exists?
      if DRY then log("  would create account: #{name}"); next end
      company.accounts.create!(
        name: name, account_type: 'customer', status: 'active',
        email: row['email'].presence,
        location_id: location_id_for(company, row['location_name']),
        source_id: source_id_for(company, row['source_name']),
        owner_id: user_id_for(company, row['salesperson']),
        billing_street: row['address1'].presence, billing_city: row['city'].presence,
        billing_state: row['state'].presence, billing_postal_code: row['zip'].presence,
        notes: row['notes'].presence,
        custom_field_values: {
          'file_number' => row['file_number'], 'finance_method' => row['finance_method'],
          'date_sold' => row['date_sold'], 'ehc_serial' => row['serial_number'],
          'import_batch' => BATCH
        }.compact
      )
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
      company.contacts.create!(
        first_name: first, last_name: last,
        email: row['email'].presence, phone: row['phone'].presence,
        is_primary: row['is_primary'] == 'true', account_id: acct&.id,
        location_id: location_id_for(company, row['location_name']),
        custom_field_values: { 'import_batch' => BATCH }
      )
      n += 1
    end
    log("  Created #{n} contacts.#{dry_note}")
  end

  # ===========================================================================
  # LEADS  (rating -> custom_field_values; no rating column)
  # ===========================================================================
  desc 'Import leads'
  task leads: :environment do
    company = require_company!
    log("== Leads ==#{dry_note}")
    n = 0
    read_csv('leads').each do |row|
      first = row['first_name'].to_s.strip; last = row['last_name'].to_s.strip
      next if first.blank? && last.blank?
      if company.leads.where("first_name ILIKE ? AND last_name ILIKE ? AND COALESCE(email,'') = ?", first, last, row['email'].to_s).exists?
        next
      end
      next if DRY
      company.leads.create!(
        first_name: first, last_name: last,
        email: row['email'].presence, phone: row['phone'].presence,
        status: row['status'].presence || 'open',
        source_id: source_id_for(company, row['source_name']),
        owner_id: user_id_for(company, row['owner']),
        location_id: location_id_for(company, row['location_name']),
        notes: row['notes'].presence,
        custom_field_values: {
          'rating'       => row['rating'].presence,
          'wd_serial'    => row['wd_serial'].presence,
          'import_batch' => BATCH
        }.compact
      )
      n += 1
    end
    log("  Created #{n} leads.#{dry_note}")
  end

  # ===========================================================================
  # DEALS  (no status column — uses stage; owner_id + user_id; value)
  # ===========================================================================
  desc 'Import deals'
  task deals: :environment do
    company = require_company!
    log("== Deals ==#{dry_note}")
    n = 0
    read_csv('deals').each do |row|
      name = row['name'].to_s.strip
      next if name.blank? || company.deals.where('name ILIKE ?', name).exists?

      acct = company.accounts.where('name ILIKE ?', row['account_name'].to_s.strip).first
      contact = row['contact_first'].present? ? company.contacts.where('first_name ILIKE ? AND last_name ILIKE ?', row['contact_first'], row['contact_last']).first : nil
      vehicle_id = vehicle_id_for_serial(company, row['vehicle_serial'].presence || row['vehicle_stock'])
      owner_id = user_id_for(company, row['owner'])

      if DRY then log("  would create deal: #{name} (acct=#{acct&.id} contact=#{contact&.id} vehicle=#{vehicle_id})"); next end
      company.deals.create!(
        name: name, stage: (row['stage'].presence || 'working'),
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
      )
      n += 1
    end
    log("  Created #{n} deals.#{dry_note}")
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
      title = row['title'].to_s.strip.presence || 'Imported service ticket'
      desc  = row['description'].to_s.strip.presence || title
      ticket_no = "EHC-#{row['source_ticket_id']}"   # stable, unique, indexed dedup key

      next if company.service_tickets.where(ticket_number: ticket_no).exists?

      acct = row['account_name'].present? ? company.accounts.where('name ILIKE ?', row['account_name'].to_s.strip).first : nil
      vehicle_id = vehicle_id_for_serial(company, row['vehicle_serial'])
      mfr_id = manufacturer_id_for(company, row['factory_name'])

      if DRY then log("  would create ticket: #{ticket_no} status=#{row['status']} warranty=#{row['is_warranty']} claim=#{row['claim_status']}"); next end

      ticket = company.service_tickets.create!(
        ticket_number: ticket_no, title: title, description: desc,
        status: row['status'].presence || 'open', priority: row['priority'].presence || 'medium',
        account_id: acct&.id, vehicle_id: vehicle_id,
        location_id: location_id_for(company, row['location_name']),
        is_warranty_suspected: row['is_warranty'] == 'true',
        is_warranty_confirmed: row['is_warranty'] == 'true' && row['claim_status'].present?,
        custom_fields: {
          'warranty_start_date' => row['warranty_start_date'], 'building_code' => row['building_code'],
          'hud_number' => row['hud_number'], 'import_batch' => BATCH
        }.compact
      )
      n += 1

      if row['claim_status'].present? && mfr_id
        claim = WarrantyClaim.create!(
          company_id: company.id, location_id: ticket.location_id,
          service_ticket_id: ticket.id, manufacturer_id: mfr_id,
          estimated_amount: 0, parts: [], labor: [],
          status: row['claim_status'],
          submitted_at: (parse_date(row['warranty_start_date']) || Time.current),
          closed_at: (row['claim_status'] == 'closed' ? Time.current : nil),
          submitted_by: 'Import', notes_internal: "Imported warranty claim (batch #{BATCH})"
        )
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
  # ROLLBACK  (TEST company: delete the company; cascades all children)
  # ===========================================================================
  desc 'Delete the Evangeline TEST company and ALL its data (cascade)'
  task rollback: :environment do
    company = require_company!
    if company.subdomain != COMPANY_SUBDOMAIN
      abort("Refusing: company #{company.id} is not the import test company (#{COMPANY_SUBDOMAIN}).")
    end
    unless ENV['CONFIRM'] == 'yes'
      abort("This DELETES company #{company.id} (#{company.name}) and every record under it. Re-run with CONFIRM=yes.")
    end
    log("== Deleting company #{company.id} (#{company.name}) and all children ==")
    company.destroy!
    log('  ✅ Company and all associated records removed.')
  end
end

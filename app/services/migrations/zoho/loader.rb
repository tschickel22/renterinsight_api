# frozen_string_literal: true

module Migrations
  module Zoho
    # Loads a mapped Zoho CRM snapshot into one company.
    #
    # Same shape as Migrations::Ghl::Loader and the same guarantees. The
    # snapshot is produced outside the app: extract (Zoho Bulk Read, read-only)
    # then map (zoho_map.py plus a per-tenant config), which writes
    # DealerTide-shaped records keyed by their Zoho record ids. This class only
    # writes.
    #
    # The plumbing here is deliberately a copy of the GHL loader's rather than a
    # shared base class: that loader has already run against live tenants and is
    # not worth destabilising for a second source. If a third migration shows
    # up, extract Migrations::Base then.
    #
    # Safe to run again. Every record goes through MigrationRecord, so a second
    # load (the refresh before go-live) updates what the first one created and
    # adds what is new. A record someone edited in DealerTide after it was
    # loaded is left alone and reported instead.
    #
    # Nothing is sent. Workflows are suppressed for the whole run, every record
    # is saved with skip_notifications/webhooks/activity tracking, and deals get
    # their real stage with update_columns so no accounting post, lifecycle
    # webhook or customer notice fires.
    #
    # dry_run: the whole load runs inside a transaction that is rolled back, so
    # every validation is exercised against the real database and the report
    # shows exactly what a real run would do.
    class Loader
      SYSTEM = 'zoho'
      STEPS = %w[setup accounts contacts leads deals notes activities files].freeze
      QUIET = { skip_notifications: true, skip_webhooks: true, skip_activity_tracking: true, skip_workflows: true }.freeze

      # Notes are matched by exact entity_type (Note.for_entity does no
      # normalisation), and the CRM frontend asks in CamelCase. Getting this
      # wrong stores notes nothing renders.
      NOTE_TYPES = { 'Accounts' => 'Account', 'Contacts' => 'Contact', 'Leads' => 'Lead', 'Deals' => 'Deal' }.freeze

      # Account#account_type is a closed enum describing the relationship
      # (customer, partner, vendor...), not the kind of business. Zoho's
      # Company_Type is the kind of business, so it stays in
      # custom_field_values and only the relationship lands here.
      PARTNER_COMPANY_TYPES = ['Reseller / Partner', 'Affiliate Partner', 'ILS', 'MLS',
                               'Apartment Association', 'Realtor Association', 'Software Company'].freeze

      attr_reader :report

      # user_email_rewrite: ['@renterinsight.com', '@ri-staging.invalid'] matches
      # owners against stand-in users on a test company, so a staging load never
      # points records (or notifications) at real staff inboxes.
      def initialize(company:, data:, batch:, dry_run: true, steps: STEPS, fallback_user: nil, user_email_rewrite: nil,
                     skip_matches_in: nil, pipeline: nil, log: $stdout)
        @company = company
        @data = data
        @batch = batch
        @dry_run = dry_run
        @steps = steps
        @log = log
        @users = company.users.where(deleted_at: nil).index_by { |u| u.email.to_s.downcase }
        @fallback_user = fallback_user
        @rewrite = user_email_rewrite
        @ids = {}
        @report = Hash.new { |h, k| h[k] = Hash.new(0) }
        @errors = []
        @edited = []
        # Records another tenant already holds are not loaded (Tom, 2026-11-20:
        # anything already in the DealerTide tenant stays there).
        @skip_company = skip_matches_in
        # pipeline: 'merge' writes the bundle's stages even on a company that
        # has deals of its own, keeping every stage those deals sit in.
        @pipeline_mode = pipeline.to_s
        @skipped = []
        @skipped_ids = Hash.new { |h, k| h[k] = Set.new }
        @location_id = location_id_from(data) || company.locations.order(:id).first&.id
      end

      def run
        started = Time.current
        Current.company_id = @company.id
        Current.suppress_workflow_events = true
        load_crosswalk
        if @dry_run
          ActiveRecord::Base.transaction do
            run_steps
            raise ActiveRecord::Rollback
          end
        else
          run_steps
        end
        summary(Time.current - started)
      ensure
        Current.suppress_workflow_events = false
      end

      private

      # ------------------------------------------------------------ plumbing

      def run_steps
        @steps.each do |step|
          say "== #{step}"
          send("load_#{step}")
        end
      end

      def say(msg) = @log.puts(msg)

      # The mapper may name the location by id or by name. A wrong location
      # hides every imported record from a user scoped to another one, so an
      # unmatched name is an error rather than a silent fallback.
      def location_id_from(data)
        want = data['location']
        return nil if want.blank?

        found = want.to_s.match?(/\A\d+\z/) ? @company.locations.find_by(id: want) : @company.locations.find_by(name: want)
        return found.id if found

        @errors << "location #{want.inspect} not found on company #{@company.id}; using the company's first location"
        nil
      end

      def load_crosswalk
        MigrationRecord.where(company_id: @company.id, source_system: SYSTEM)
                       .pluck(:source_type, :source_id, :record_id, :loaded_at)
                       .each { |t, s, r, at| @ids[[t, s]] = [r, at] }
      end

      def id_for(type, source_id) = @ids[[type, source_id.to_s]]&.first

      # One record, in its own savepoint so a failure is reported and the run
      # carries on. Returns the saved record or nil.
      # adopt: natural key to take over a record that already exists in the
      # company (a lead status or source the dealer already had) instead of
      # failing on a duplicate.
      def upsert(type, source_id, klass, scope, attrs = nil, adopt: nil, **fields)
        attrs = (attrs || {}).merge(fields)
        source_id = source_id.to_s
        existing_id, loaded_at = @ids[[type, source_id]]
        record = existing_id && scope.find_by(id: existing_id)
        if record.nil? && adopt && (found = scope.where(adopt).first)
          remember(type, source_id, found)
          @report[type][:adopted_existing] += 1
          return found
        end
        if record && loaded_at && record.updated_at > loaded_at + 5.seconds
          @edited << "#{type} #{source_id} (#{klass.name} #{record.id})"
          @report[type][:kept_dealertide_edit] += 1
          return record
        end
        ActiveRecord::Base.transaction(requires_new: true) do
          record ||= scope.new
          was_new = record.new_record?
          record.assign_attributes(attrs)
          QUIET.each { |k, v| record.public_send("#{k}=", v) if record.respond_to?("#{k}=") }
          yield(record) if block_given?
          save_keeping_bad_phone!(record)
          remember(type, source_id, record)
          @report[type][was_new ? :created : :updated] += 1
        end
        record
      rescue StandardError => e
        fail_record(type, source_id, e)
        nil
      end

      # A Zoho phone DealerTide's format check refuses should not cost the whole
      # record. The usual cause is an extension ("(724) 283-5618 x4"): keep the
      # number and put the extension in the notes. Anything else leaves the
      # phone column and goes to the notes whole.
      def save_keeping_bad_phone!(record)
        record.save!
      rescue ActiveRecord::RecordInvalid
        raise unless record.errors.attribute_names == [:phone] && record.respond_to?(:notes=)

        bad = record.phone.to_s
        if (m = bad.match(/\A(.*?\d)\s*(?:x|ext\.?|extension)\s*(\d+)\z/i))
          record.phone = m[1]
          record.notes = lines(record.notes, "Phone extension: #{m[2]}")
          @report['phone_extension_to_notes'][record.class.name] += 1
        else
          record.phone = nil
          record.notes = lines(record.notes, "Phone from Zoho (not a valid number): #{bad}")
          @report['phone_moved_to_notes'][record.class.name] += 1
        end
        record.save!
      end

      def remember(type, source_id, record)
        now = Time.current
        MigrationRecord.upsert(
          { company_id: @company.id, source_system: SYSTEM, source_type: type, source_id: source_id.to_s,
            record_type: record.class.base_class.name, record_id: record.id, batch: @batch, loaded_at: now,
            created_at: now, updated_at: now },
          unique_by: :idx_migration_records_source,
          update_only: %i[record_id batch loaded_at]
        )
        @ids[[type, source_id.to_s]] = [record.id, now]
      end

      def fail_record(type, source_id, error)
        @report[type][:failed] += 1
        msg = error.respond_to?(:record) && error.record ? error.record.errors.full_messages.join(', ') : error.message
        @errors << "#{type} #{source_id}: #{msg.to_s.truncate(300)}"
      end

      # Timestamps from Zoho, written without callbacks after the save.
      def stamp(record, created_at, extra = {})
        return unless record&.persisted?

        cols = extra.compact
        cols[:created_at] = time(created_at) if created_at.present?
        record.update_columns(cols) if cols.any?
      rescue ArgumentError
        nil
      end

      def time(value)
        value.present? ? Time.zone.parse(value.to_s) : nil
      rescue ArgumentError, TypeError
        nil
      end

      def owner_id(email)
        return nil if email.blank?

        key = email.to_s.downcase
        key = key.sub(@rewrite[0], @rewrite[1]) if @rewrite
        user = @users[key]
        unless user
          @report['owner'][:unmatched] += 1
          @unmatched_owners ||= Set.new
          @errors << "no DealerTide user for Zoho owner #{email}; left to the fallback user" if @unmatched_owners.add?(key)
        end
        user&.id || @fallback_user&.id
      end

      def field_key(name) = name.to_s.parameterize(separator: '_')

      def custom_values(hash)
        (hash || {}).each_with_object({}) { |(k, v), out| out[field_key(k)] = v.to_s if v.present? }.deep_stringify_keys
      end

      def lines(*parts) = parts.flatten.compact_blank.join("\n")

      def num(v)
        Float(v.to_s.delete('$,').strip)
      rescue ArgumentError, TypeError
        nil
      end

      # People already in the company before the import (website form leads,
      # hand-entered contacts) that match an imported person by email or phone.
      # Not merged automatically: listed so the dealer decides.
      def note_possible_duplicate(kind, zoho_id, email, phone)
        @pre_existing ||= begin
          ids = MigrationRecord.where(company_id: @company.id, source_system: SYSTEM, record_type: %w[Lead Contact]).pluck(:record_type, :record_id).to_set
          people = @company.leads.pluck(:id, :email, :phone).map { |i, e, p| ['Lead', i, e, p] } +
                   @company.contacts.pluck(:id, :email, :phone).map { |i, e, p| ['Contact', i, e, p] }
          people.reject { |t, i, _, _| ids.include?([t, i]) }
        end
        digits = ->(v) { v.to_s.gsub(/\D/, '').last(10) }
        hit = @pre_existing.find do |_, _, e, p|
          (email.present? && e.to_s.casecmp?(email)) || (phone.present? && digits.(p).length == 10 && digits.(p) == digits.(phone))
        end
        return unless hit

        @report['possible_duplicate'][kind] += 1
        @errors << "possible duplicate: Zoho #{kind} #{zoho_id} matches existing #{hit[0]} #{hit[1]} (#{email || phone}); both kept"
      end


      # ------------------------------------------------------------ other tenant

      FREE_MAIL = %w[gmail.com yahoo.com hotmail.com outlook.com aol.com icloud.com msn.com live.com comcast.net].freeze

      def digits(v) = v.to_s.gsub(/\D/, '').last(10)
      def company_key(v) = v.to_s.downcase.gsub(/&/, ' and ').gsub(/[^a-z0-9 ]/, ' ').gsub(/\b(llc|inc|corp|co|ltd|lp|pllc|the)\b/, ' ').squish
      def domain_of(v)
        host = v.to_s.downcase.strip.sub(%r{\Ahttps?://}, '').sub(/\Awww\./, '').split(%r{[/?#]}).first.to_s
        host.include?('.') && !FREE_MAIL.include?(host) ? host : nil
      end

      def other_tenant
        @other_tenant ||= begin
          c = @skip_company
          people = c.leads.pluck(:email, :phone) + c.contacts.pluck(:email, :phone) + c.accounts.pluck(:email, :phone)
          { emails: matchable(people.map { |e, _| e.to_s.downcase.strip }.reject(&:blank?), zoho_people.map(&:first)),
            phones: matchable(people.map { |_, p| digits(p) }.select { |d| d.length == 10 }, zoho_people.map(&:last)),
            names: c.accounts.pluck(:name).map { |n| company_key(n) }.reject(&:blank?).to_set,
            domains: c.accounts.pluck(:website).filter_map { |w| domain_of(w) }.to_set }
        end
      end

      # A phone or email on more than SHARED_AT records, on either side, is an
      # office line or a shared inbox (303-570-9810 sits on dozens of Zoho test
      # accounts), so it is not evidence two records are the same customer.
      SHARED_AT = 3

      def matchable(theirs, ours)
        counts = Hash.new(0)
        theirs.each { |v| counts[[:theirs, v]] += 1 }
        ours.compact.each { |v| counts[[:ours, v]] += 1 }
        theirs.uniq.reject { |v| counts[[:theirs, v]] >= SHARED_AT || counts[[:ours, v]] >= SHARED_AT }.to_set
      end

      def zoho_people
        @zoho_people ||= %w[accounts contacts leads].flat_map { |k| @data[k] || [] }.map do |r|
          [r['email'].to_s.downcase.strip.presence, digits(r['phone']).then { |d| d.length == 10 ? d : nil }]
        end
      end

      # Returns why the record matches the other tenant, or nil.
      def other_tenant_match(email: nil, phone: nil, name: nil, website: nil)
        return nil unless @skip_company

        t = other_tenant
        return "email #{email}" if email.present? && t[:emails].include?(email.to_s.downcase.strip)
        return "phone #{phone}" if phone.present? && digits(phone).length == 10 && t[:phones].include?(digits(phone))
        return "name #{name}" if name.present? && company_key(name).present? && t[:names].include?(company_key(name))
        return "website #{website}" if (d = domain_of(website)) && t[:domains].include?(d)

        nil
      end

      def skip!(type, zoho_id, why)
        @skipped_ids[type] << zoho_id.to_s
        @report['skipped_in_other_tenant'][type] += 1
        @skipped << "#{type} #{zoho_id}: #{why}"
        true
      end

      def skipped?(type, zoho_id) = zoho_id.present? && @skipped_ids[type].include?(zoho_id.to_s)

      # ------------------------------------------------------------ setup

      def load_setup
        ref = @data['reference'] || {}

        (ref['lead_statuses'] || []).each_with_index do |(label, key, is_excluded), i|
          upsert('lead_status', key, LeadStatus, @company.lead_statuses,
                 { key: key, label: label, sort_order: 1000 + i, is_active: true, is_excluded: !!is_excluded },
                 adopt: ['lower(key) = :k OR lower(label) = :l', { k: key.to_s.downcase, l: label.to_s.downcase }])
        end

        verify_deal_stages(ref)

        (ref['sources'] || []).each do |n|
          upsert('source', n, Source, @company.sources, { name: n, is_active: true }, adopt: ['lower(name) = ?', n.to_s.downcase])
        end

        (ref['custom_fields'] || []).each_with_index do |f, i|
          mod = f['module']
          key = field_key(f['name'])
          type = CustomField::FIELD_TYPES.include?(f['field_type']) ? f['field_type'] : 'text'
          options = Array(f['options']).map { |o| o.to_s.strip }.reject(&:empty?).uniq
          # CustomField#select_fields_have_options requires a non-empty array on
          # select and multiselect. A Zoho picklist whose values did not come
          # through becomes free text rather than failing the whole field and
          # dropping its data on the floor.
          if %w[select multiselect].include?(type) && options.empty?
            type = 'text'
            @report['custom_field'][:picklist_without_options_became_text] += 1
          end
          upsert('custom_field', "#{mod}:#{f['name']}", CustomField, CustomField.where(company_id: @company.id),
                 { company_id: @company.id, module: mod, name: key, field_key: key, label: f['name'],
                   field_type: type, options: %w[select multiselect].include?(type) ? options : nil,
                   display_order: 100 + i, section: 'Zoho', is_active: true },
                 adopt: { module: mod, field_key: key })
        end
      end

      # The mapper targets DealerTide stage keys. A company that already has
      # deals of its own keeps its pipeline: overwriting a live config to suit
      # an import is how a dealer loses their stages, so there it only checks.
      # A company with no deals of its own (company 22, Tom 2026-11-20) gets the
      # pipeline the bundle carries, which is Zoho's own stages.
      def verify_deal_stages(ref)
        wanted = (ref['deal_stage_keys'] || []).map(&:to_s).uniq
        return if wanted.empty?

        bring = Array(ref['pipeline_stages']).map(&:deep_stringify_keys)
        if bring.any? && (own_deals.none? || @pipeline_mode == 'merge')
          bring = keep_stages_in_use(bring) if @pipeline_mode == 'merge'
          Setting.set('Company', @company.id, 'pipeline_stages', bring)
          @company.instance_variables.grep(/stage_keys\z/).each { |v| @company.remove_instance_variable(v) }
          @report['pipeline_stages'][:written] += bring.size
        end

        configured = Setting.get('Company', @company.id, 'pipeline_stages', nil)
        if configured.blank?
          @report['pipeline_stages'][:not_configured] += 1
          return
        end

        have = Array(configured).map { |s| (s['key'] || s[:key]).to_s }
        missing = wanted - have
        if missing.any?
          @errors << "deal stages not on company #{@company.id}: #{missing.join(', ')} (have: #{have.join(', ')})"
          @report['pipeline_stages'][:missing] += missing.size
        else
          @report['pipeline_stages'][:verified] += wanted.size
        end
      end

      # A stage one of the company's own deals sits in stays, just before the
      # closed stages, named as the current config names it.
      def keep_stages_in_use(bring)
        have = bring.map { |s| s['key'] }
        current = @company.pipeline_stages.index_by { |s| (s['key'] || s[:key]).to_s }
        extra = own_deals.distinct.pluck(:stage).compact.map(&:to_s) - have
        return bring if extra.empty?

        first_closed = bring.index { |s| %w[closed_won closed_lost].include?(s['key']) } || bring.size
        kept = extra.map do |key|
          old = (current[key] || {}).to_h.deep_stringify_keys
          { 'key' => key, 'name' => old['name'] || key.humanize, 'probability' => old['probability'] || @company.pipeline_stage_probability(key) || 50,
            'color' => old['color'] || '#64748b', 'active' => true, 'locked' => false }
        end
        @report['pipeline_stages'][:kept_in_use] += kept.size
        (bring[0...first_closed] + kept + bring[first_closed..]).each_with_index.map { |s, i| s.merge('order' => i) }
      end

      # Deals this company has that did not come from Zoho.
      def own_deals
        from_zoho = MigrationRecord.where(company_id: @company.id, source_system: SYSTEM, record_type: 'Deal').select(:record_id)
        @company.deals.where.not(id: from_zoho)
      end

      def source_id_for(name) = name.present? ? id_for('source', name) : nil

      # Anything the mapper sends that is not one of Account::ACCOUNT_TYPES is
      # reported and replaced, so one bad value cannot fail the account and
      # orphan its contacts, deals and notes.
      def account_type_for(account)
        given = account['account_type'].to_s
        return given if Account::ACCOUNT_TYPES.include?(given)

        @report['account_type'][:replaced] += 1 if given.present?
        @errors << "account #{account['zoho_id']}: account_type #{given.inspect} is not one of Account::ACCOUNT_TYPES; used a default" if given.present?
        PARTNER_COMPANY_TYPES.include?(account.dig('custom', 'Company Type').to_s) ? 'partner' : 'customer'
      end

      # ------------------------------------------------------------ accounts

      def load_accounts
        taken = @company.accounts.pluck(:name).map(&:downcase).to_set
        (@data['accounts'] || []).each do |a|
          existing = id_for('account', a['zoho_id'])
          if !existing && (why = other_tenant_match(email: a['email'], phone: a['phone'], name: a['name'], website: a['website']))
            next skip!('account', a['zoho_id'], "#{a['name']} matches company #{@skip_company.id} by #{why}")
          end
          name = a['name'].presence || 'Customer'
          # Keep the name an account already has: the first load may have made
          # it unique ("Smith (2)"), and a dealer may have renamed it since.
          name = @company.accounts.where(id: existing).pick(:name) || name if existing
          unless existing
            base = name
            n = 1
            name = "#{base} (#{n += 1})" while taken.include?(name.downcase)
          end
          taken << name.downcase

          b = a['billing'] || {}
          s = a['shipping'] || {}
          acct = upsert('account', a['zoho_id'], Account, @company.accounts,
                        name: name, status: a['status'].presence || 'active', account_type: account_type_for(a),
                        email: a['email'].presence, phone: a['phone'].presence, website: a['website'].presence,
                        industry: a['industry'], annual_revenue: num(a['annual_revenue']),
                        employee_count: num(a['employee_count'])&.to_i,
                        owner_id: owner_id(a['owner_email']), source_id: source_id_for(a['source']),
                        location_id: @location_id,
                        billing_street: b['street'], billing_city: b['city'], billing_state: b['state'],
                        billing_postal_code: b['zip'], billing_country: b['country'],
                        shipping_street: s['street'], shipping_city: s['city'], shipping_state: s['state'],
                        shipping_postal_code: s['zip'], shipping_country: s['country'],
                        description: a['description'],
                        custom_field_values: custom_values(a['custom']),
                        notes: lines('Imported from Zoho CRM.', a['note']))
          next unless acct

          stamp(acct, a['created_at'], updated_at: time(a['updated_at']),
                                       last_activity_date: time(a['last_activity_at']))
        end
        link_account_parents
      end

      # Second pass: Zoho's Parent_Account points at another account that may
      # not have existed yet on the first pass. update_columns because the
      # parent link is structure, not a change anyone should be notified about.
      def link_account_parents
        (@data['accounts'] || []).each do |a|
          next if a['parent_zoho_id'].blank?

          child_id = id_for('account', a['zoho_id'])
          parent_id = id_for('account', a['parent_zoho_id'])
          next @report['account_parent'][:unresolved] += 1 unless child_id && parent_id
          next @report['account_parent'][:self_reference] += 1 if child_id == parent_id

          child = @company.accounts.find_by(id: child_id)
          next unless child && child.parent_account_id != parent_id

          child.update_columns(parent_account_id: parent_id)
          @report['account_parent'][:linked] += 1
        end
      end

      # ------------------------------------------------------------ contacts

      def load_contacts
        (@data['contacts'] || []).each do |c|
          unless id_for('contact', c['zoho_id'])
            next skip!('contact', c['zoho_id'], "account #{c['account_zoho_id']} was skipped") if skipped?('account', c['account_zoho_id'])
            if (why = other_tenant_match(email: c['email'], phone: c['phone']))
              next skip!('contact', c['zoho_id'], "matches company #{@skip_company.id} by #{why}")
            end
          end
          note_possible_duplicate('contact', c['zoho_id'], c['email'], c['phone']) unless id_for('contact', c['zoho_id'])
          account_id = c['account_zoho_id'].present? ? id_for('account', c['account_zoho_id']) : nil
          if c['account_zoho_id'].present? && account_id.nil?
            @report['contact'][:account_missing] += 1
            @errors << "contact #{c['zoho_id']}: account #{c['account_zoho_id']} not loaded; contact kept unassigned"
          end

          # contacts.first_name is NOT NULL, but Zoho requires Last_Name and
          # lets First_Name be blank, so promote whatever identifies the person
          # and do not leave the same value in both columns.
          first = c['first_name'].presence || c['last_name'].presence || c['email'].presence || c['phone'].presence || 'Unknown'
          last = c['first_name'].present? ? c['last_name'] : nil

          rec = upsert('contact', c['zoho_id'], Contact, @company.contacts,
                       account_id: account_id, first_name: first, last_name: last,
                       email: c['email'].presence, phone: c['phone'].presence,
                       title: c['title'], department: c['department'], company_name: c['company_name'],
                       is_primary: !!c['is_primary'],
                       opt_out_email: !!c['opt_out_email'],
                       owner_id: owner_id(c['owner_email']), location_id: @location_id,
                       street: c['street'], city: c['city'], state: c['state'], zip: c['zip'], country: c['country'],
                       custom_field_values: custom_values(c['custom']),
                       notes: lines('Imported from Zoho CRM.', c['description'],
                                    c['secondary_email'].presence ? "Other email: #{c['secondary_email']}" : nil,
                                    c['mobile'].presence ? "Mobile: #{c['mobile']}" : nil))
          stamp(rec, c['created_at'], updated_at: time(c['updated_at']))
        end
      end

      # ------------------------------------------------------------ leads

      def load_leads
        (@data['leads'] || []).each do |l|
          if !id_for('lead', l['zoho_id']) && (why = other_tenant_match(email: l['email'], phone: l['phone'], name: l['company_name']))
            next skip!('lead', l['zoho_id'], "matches company #{@skip_company.id} by #{why}")
          end
          note_possible_duplicate('lead', l['zoho_id'], l['email'], l['phone']) unless id_for('lead', l['zoho_id'])

          first = l['first_name'].presence || l['last_name'].presence || l['email'].presence || l['phone'].presence || 'Unknown'
          last = l['first_name'].present? ? l['last_name'] : nil

          rec = upsert('lead', l['zoho_id'], Lead, @company.leads,
                       first_name: first, last_name: last,
                       email: l['email'].presence, phone: l['phone'].presence,
                       status: l['status'], company_name: l['company_name'], title: l['title'],
                       owner_id: owner_id(l['owner_email']), source_id: source_id_for(l['source']),
                       location_id: @location_id,
                       street: l['street'], city: l['city'], state: l['state'], zip: l['zip'], country: l['country'],
                       budget_range: l['budget_range'], purchase_timeframe: l['purchase_timeframe'],
                       interests_requirements: l['interests_requirements'],
                       custom_field_values: custom_values(l['custom']),
                       notes: lines('Imported from Zoho CRM.', l['description'],
                                    l['secondary_email'].presence ? "Other email: #{l['secondary_email']}" : nil,
                                    l['mobile'].presence ? "Mobile: #{l['mobile']}" : nil),
                       source_created_at: l['created_at'])
          stamp(rec, l['created_at'], updated_at: time(l['updated_at']),
                                      last_activity_at: time(l['last_activity_at'] || l['updated_at']))
          @report['lead_status'][l['status'].to_s] += 1
        end
      end

      # ------------------------------------------------------------ deals

      def load_deals
        (@data['deals'] || []).each do |d|
          next skip!('deal', d['zoho_id'], "account #{d['account_zoho_id']} was skipped") if skipped?('account', d['account_zoho_id'])

          account_id = d['account_zoho_id'].present? ? id_for('account', d['account_zoho_id']) : nil
          next fail_record('deal', d['zoho_id'], StandardError.new('account missing')) unless account_id

          contact_id = d['contact_zoho_id'].present? ? id_for('contact', d['contact_zoho_id']) : nil
          existing = id_for('deal', d['zoho_id'])
          stage = d['stage'].to_s
          opening = @company.closed_deal_stage_keys.include?(stage) ? @company.default_deal_stage : stage

          rec = upsert('deal', d['zoho_id'], Deal, @company.deals,
                       name: d['name'].presence || "Zoho deal #{d['zoho_id']}",
                       account_id: account_id, contact_id: contact_id,
                       value: num(d['value']) || 0, probability: num(d['probability'])&.to_i,
                       expected_close_date: d['expected_close_date'], actual_close_date: d['actual_close_date'],
                       owner_id: owner_id(d['owner_email']), user_id: owner_id(d['owner_email']),
                       source_id: source_id_for(d['source']), lead_source: d['lead_source'],
                       deal_type: d['deal_type'], location_id: @location_id,
                       loss_reason: d['loss_reason'], competitor: d['competitor'],
                       custom_field_values: custom_values(d['custom']),
                       description: lines("Imported from Zoho CRM: #{d['zoho_pipeline']} / #{d['zoho_stage']}.", d['description'])) do |deal|
            # Open at a non-closed stage, then set the real one below without
            # callbacks, so nothing posts to accounting or notifies a customer.
            deal.stage = opening if deal.new_record?
          end
          next unless rec

          won = stage == 'closed_won' ? (time(d['actual_close_date']) || time(d['closed_at'])) : nil
          lost = stage == 'closed_lost' ? (time(d['actual_close_date']) || time(d['closed_at'])) : nil
          rec.update_columns(stage: stage, won_at: won, lost_at: lost)
          stamp(rec, d['created_at'], updated_at: time(d['updated_at']),
                                      last_activity_at: time(d['last_activity_at'] || d['updated_at']))
          @report['deal_stage'][stage] += 1 unless existing
        end
      end

      # ------------------------------------------------------------ notes

      def load_notes
        (@data['notes'] || []).each do |n|
          next @report['note'][:skipped] += 1 if n['content'].blank?

          etype = NOTE_TYPES[n['parent_module'].to_s]
          next @report['note'][:unsupported_parent] += 1 unless etype

          next skip!('note', n['zoho_id'], "#{etype.downcase} #{n['parent_zoho_id']} was skipped") if skipped?(etype.downcase, n['parent_zoho_id'])

          eid = id_for(etype.downcase, n['parent_zoho_id'])
          next @report['note'][:no_parent] += 1 unless eid

          title = n['title'].presence
          rec = upsert('note', n['zoho_id'], Note, Note.where(entity_type: etype, entity_id: eid.to_s),
                       entity_type: etype, entity_id: eid.to_s,
                       content: lines('[Zoho note]', title, n['content']),
                       user_id: owner_id(n['author_email']), category: 'general')
          stamp(rec, n['created_at'], updated_at: time(n['updated_at'] || n['created_at']))
        end
      end

      # ------------------------------------------------------------ activities

      # Zoho calls, tasks and meetings as history (Tom, 2026-11-20).
      #
      # Written with insert_all, on purpose. Saved the normal way, a meeting
      # with a start time queues a calendar invite and a booking text to the
      # customer (SendsAppointmentInvites), a task notifies its assignee, and
      # every one emits workflow events. Thousands of real Zoho prospects would
      # get a text about a 2023 demo. insert_all runs no callbacks at all.
      #
      # History only: a record already loaded is left alone on a re-run, and a
      # task Zoho never finished lands cancelled with its Zoho status noted, so
      # 70 stale tasks do not appear as overdue work.
      ACTIVITY_TABLES = { 'Deals' => DealActivity, 'Accounts' => AccountActivity,
                          'Contacts' => ContactActivity, 'Leads' => Activity }.freeze

      def load_activities
        rows = Hash.new { |h, k| h[k] = [] }
        (@data['activities'] || []).each do |a|
          next @report['activity'][:already_loaded] += 1 if id_for('activity', a['zoho_id'])

          type = a['target_module'].to_s.delete_suffix('s').downcase
          next skip!('activity', a['zoho_id'], "#{type} #{a['target_zoho_id']} was skipped") if skipped?(type, a['target_zoho_id'])

          parent_id = id_for(type, a['target_zoho_id'])
          next @report['activity'][:no_parent] += 1 unless parent_id

          klass = ACTIVITY_TABLES[a['target_module']]
          row = activity_row(klass, a, parent_id)
          # contact_activities.user_id is NOT NULL; a company with no users
          # cannot own one.
          next @report['activity'][:no_user] += 1 if klass == ContactActivity && row[:user_id].nil?

          rows[klass] << [a['zoho_id'], row]
        end

        rows.each do |klass, pairs|
          pairs.each_slice(500) do |slice|
            ids = begin
              ActiveRecord::Base.transaction(requires_new: true) do
                klass.insert_all(slice.map(&:last), returning: %w[id]).rows.flatten
              end
            rescue ActiveRecord::ActiveRecordError => e
              @report['activity'][:failed] += slice.size
              @errors << "#{klass.name}: #{slice.size} activities not loaded: #{e.message.lines.first.strip}"
              next
            end
            now = Time.current
            MigrationRecord.insert_all(slice.zip(ids).map do |(zoho_id, _), id|
              { company_id: @company.id, source_system: SYSTEM, source_type: 'activity', source_id: zoho_id.to_s,
                record_type: klass.name, record_id: id, batch: @batch, loaded_at: now, created_at: now, updated_at: now }
            end, unique_by: :idx_migration_records_source)
            slice.zip(ids).each { |(zoho_id, _), id| @ids[['activity', zoho_id.to_s]] = [id, now] }
            @report['activity'][klass.name] += ids.size
          end
        end
      end

      def activity_row(klass, a, parent_id)
        user = owner_id(a['owner_email'])
        created = time(a['created_at']) || Time.current
        start = time(a['start'])
        done = a['done']
        status = done ? 'completed' : 'cancelled'
        completed = done ? (time(a['completed_at']) || start || created) : nil
        kind = a['kind']
        call_outcome = kind == 'call' && a['missed'] ? 'no_answer' : nil
        notes = lines(a['result'].presence && "Zoho result: #{a['result']}",
                      !done && "Still open in Zoho (#{a['zoho_status']}) at import.",
                      '[Imported from Zoho CRM]')
        common = { user_id: user, created_at: created, updated_at: time(a['updated_at']) || created }

        if klass == Activity
          return common.merge(lead_id: parent_id,
                              activity_type: { 'task' => 'lead_activity_task' }.fetch(kind, kind),
                              description: lines(a['subject'], a['description'], notes),
                              duration: a['duration_minutes'], scheduled_date: start || time(a['due']),
                              completed_date: completed, metadata: { 'zoho_id' => a['zoho_id'], 'zoho_status' => a['zoho_status'] })
        end

        row = common.merge(
          activity_type: kind, subject: a['subject'].to_s.truncate(250), description: a['description'],
          status: status, priority: 'medium', due_date: time(a['due']), start_time: start, end_time: time(a['end']),
          completed_at: completed, phone_number: a['phone'], call_direction: kind == 'call' ? a['direction'] : nil,
          call_outcome: call_outcome, outcome_notes: notes, assigned_to_id: user,
          reminder_sent: true, remind_customer: false, send_calendar_invite: false, customer_notices: {}
        )
        case klass.name
        when 'DealActivity'
          row.merge(deal_id: parent_id, duration: a['duration_minutes'], location: a['location'])
        when 'AccountActivity'
          row.merge(account_id: parent_id, duration_minutes: a['duration_minutes'], meeting_location: a['location'],
                    metadata: { 'zoho_id' => a['zoho_id'] })
        when 'ContactActivity'
          row.merge(contact_id: parent_id, account_id: @company.contacts.where(id: parent_id).pick(:account_id),
                    user_id: user || @fallback_user&.id || @company.users.order(:id).pick(:id),
                    duration_minutes: a['duration_minutes'], meeting_location: a['location'],
                    metadata: { 'zoho_id' => a['zoho_id'] })
        end
      end

      # ------------------------------------------------------------ files

      FILE_PARENTS = { 'Accounts' => Account, 'Contacts' => Contact, 'Leads' => Lead, 'Deals' => Deal }.freeze

      # Zoho attachments onto the record's Files tab. The bytes were uploaded
      # beforehand to the Active Storage bucket at `key` (zoho-import/<id>), so
      # this only creates the blob row that points at that object and attaches
      # it. A missing object is reported, never attached.
      #
      # Attaching touches the record; its updated_at is put back afterwards, or
      # the next refresh would read every record with a file as a DealerTide
      # edit and stop updating it.
      def load_files
        service = ActiveStorage::Blob.service
        (@data['files'] || []).each do |f|
          next @report['file'][:already_loaded] += 1 if id_for('file', f['zoho_id'])

          type = f['target_module'].to_s.delete_suffix('s').downcase
          next skip!('file', f['zoho_id'], "#{type} #{f['target_zoho_id']} was skipped") if skipped?(type, f['target_zoho_id'])

          parent_id = id_for(type, f['target_zoho_id'])
          next @report['file'][:no_parent] += 1 unless parent_id

          record = FILE_PARENTS.fetch(f['target_module']).where(company_id: @company.id).find_by(id: parent_id)
          next @report['file'][:no_parent] += 1 unless record
          next @report['file'][:object_missing] += 1 unless service.exist?(f['key'])

          before = record.updated_at
          ActiveRecord::Base.transaction(requires_new: true) do
            blob = ActiveStorage::Blob.find_by(key: f['key']) || ActiveStorage::Blob.create!(
              key: f['key'], filename: f['filename'], content_type: f['content_type'],
              byte_size: f['byte_size'], checksum: f['checksum'], service_name: service.name,
              metadata: { 'origin' => 'zoho', 'zoho_id' => f['zoho_id'].to_s,
                          'original_created_at' => f['created_at'],
                          'uploaded_by_id' => owner_id(f['owner_email'])&.to_s, 'identified' => true }.compact
            )
            attachment = ActiveStorage::Attachment.create!(name: 'files', record: record, blob: blob)
            record.update_columns(updated_at: before)
            remember('file', f['zoho_id'], attachment)
            @report['file'][:attached] += 1
          end
        rescue StandardError => e
          fail_record('file', f['zoho_id'], e)
        end
      end

      # ------------------------------------------------------------ summary

      def summary(elapsed)
        say ''
        say "#{@dry_run ? 'DRY RUN (rolled back)' : 'LOADED'}: company #{@company.id} #{@company.name}, batch #{@batch}, #{elapsed.round}s"
        @report.sort_by { |k, _| k.to_s }.each { |k, v| say "  #{k}: #{v.sort_by { |a, _| a.to_s }.map { |a, b| "#{a} #{b}" }.join(', ')}" }
        if @edited.any?
          say "  kept DealerTide edits (#{@edited.size}):"
          @edited.first(30).each { |e| say "    #{e}" }
        end
        if @skipped.any?
          say "  skipped, already in company #{@skip_company.id} #{@skip_company.name} (#{@skipped.size}):"
          @skipped.each { |e| say "    #{e}" }
        end
        say "  errors: #{@errors.size}"
        @errors.first(60).each { |e| say "    #{e}" }
        { report: @report, errors: @errors, edited: @edited, skipped: @skipped }
      end
    end
  end
end

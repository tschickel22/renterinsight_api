# frozen_string_literal: true

require 'net/http'

module Migrations
  module Ghl
    # Loads a mapped GoHighLevel snapshot into one company (backlog E84).
    #
    # The snapshot is produced outside the app: extract (read-only GHL pull),
    # then map (ghl_map.py plus a per-tenant config), which writes
    # DealerTide-shaped records keyed by their GHL ids. This class only writes.
    # Nothing in it is specific to one dealer.
    #
    # Safe to run again. Every record goes through MigrationRecord, so a second
    # load (the refresh before go-live) updates what the first one created and
    # adds what is new. A record someone edited in DealerTide after it was
    # loaded is left alone and reported instead.
    #
    # Nothing is sent. Workflows are suppressed for the whole run, every record
    # is saved with skip_notifications/webhooks/activity tracking, deals and
    # project phases get their real stage and status with update_columns (so no
    # accounting post, lifecycle webhook or customer notice fires), and calls
    # and appointments are inserted without callbacks (so no calendar invite or
    # reminder goes out).
    #
    # dry_run: the whole load runs inside a transaction that is rolled back, so
    # every validation is exercised against the real database and the report
    # shows exactly what a real run would do. Files are not downloaded; each one
    # is checked with a HEAD request instead.
    class Loader
      SYSTEM = 'ghl'
      STEPS = %w[setup vendors leads customers deals projects notes communications activities consent tags tasks documents media].freeze
      QUIET = { skip_notifications: true, skip_webhooks: true, skip_activity_tracking: true, skip_workflows: true }.freeze

      attr_reader :report

      def initialize(company:, data:, batch:, dry_run: true, steps: STEPS, fallback_user: nil, log: $stdout)
        @company = company
        @data = data
        @batch = batch
        @dry_run = dry_run
        @steps = steps
        @log = log
        @users = company.users.where(deleted_at: nil).index_by { |u| u.email.to_s.downcase }
        @fallback_user = fallback_user
        @ids = {}
        @report = Hash.new { |h, k| h[k] = Hash.new(0) }
        @errors = []
        @edited = []
        @location_id = company.locations.order(:id).first&.id
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

      def load_crosswalk
        MigrationRecord.where(company_id: @company.id, source_system: SYSTEM)
                       .pluck(:source_type, :source_id, :record_id, :loaded_at)
                       .each { |t, s, r, at| @ids[[t, s]] = [r, at] }
      end

      def id_for(type, source_id) = @ids[[type, source_id.to_s]]&.first

      # One record, in its own savepoint so a failure is reported and the run
      # carries on. Returns the saved record or nil.
      def upsert(type, source_id, klass, scope, attrs)
        source_id = source_id.to_s
        existing_id, loaded_at = @ids[[type, source_id]]
        record = existing_id && scope.find_by(id: existing_id)
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
          record.save!
          remember(type, source_id, record)
          @report[type][was_new ? :created : :updated] += 1
        end
        record
      rescue StandardError => e
        fail_record(type, source_id, e)
        nil
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

      # Timestamps from GHL, written without callbacks after the save.
      def stamp(record, created_at, extra = {})
        return unless record&.persisted?

        cols = extra.compact
        cols[:created_at] = Time.zone.parse(created_at) if created_at.present?
        record.update_columns(cols) if cols.any?
      rescue ArgumentError
        nil
      end

      def owner_id(email)
        return nil if email.blank?

        user = @users[email.downcase]
        @report[:owners][user ? :matched : :not_found] += 1
        @report[:owners_missing][email] += 1 unless user
        user&.id
      end

      def actor_id(email) = owner_id(email) || @fallback_user&.id

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

      # Same form the STOP handler stores, so a suppression matches either way.
      def sms_ok_phone(phone) = phone.present? ? Campaigns::SmsInboundHandler.normalize_phone(phone) : nil

      # ------------------------------------------------------------ setup

      def load_setup
        ref = @data['reference']

        ref['lead_statuses'].each_with_index do |(label, key), i|
          upsert('lead_status', key, LeadStatus, @company.lead_statuses, key: key, label: label, sort_order: i, is_active: true)
        end

        stages = ref['deal_stages'].each_with_index.map do |(name, key, probability, color), i|
          { 'key' => key, 'name' => name, 'probability' => probability, 'color' => color,
            'locked' => %w[closed_won closed_lost].include?(key), 'active' => true, 'order' => i }
        end
        current = Setting.get('Company', @company.id, 'pipeline_stages', nil)
        if current != stages
          Setting.set('Company', @company.id, 'pipeline_stages', stages)
          @company.touch
          @company.instance_variable_set(:@won_stage_keys, nil)
          @company.instance_variable_set(:@lost_stage_keys, nil)
          @report['pipeline_stages'][:set] += 1
        end

        ref['sources'].each { |n| upsert('source', n, Source, @company.sources, name: n, is_active: true) }
        ref['tags'].each { |n| upsert('tag', n, Tag, Tag.where(company_id: @company.id), name: n, company_id: @company.id, is_active: true) }
        ref['lenders'].each { |n| upsert('lender', n, Lender, @company.lenders, name: n, active: true) }
        ref['custom_fields'].each_with_index do |f, i|
          mod = { 'lead' => 'leads', 'contact' => 'contacts', 'deal' => 'deals' }.fetch(f['module'])
          long = f['name'] =~ /notes|setbacks/i
          upsert('custom_field', "#{mod}:#{f['name']}", CustomField, CustomField.where(company_id: @company.id),
                 company_id: @company.id, module: mod, name: field_key(f['name']), field_key: field_key(f['name']),
                 label: f['name'], field_type: long ? 'longtext' : 'text', display_order: 100 + i, section: 'GoHighLevel', is_active: true)
        end

        tpl = ref['project_template']
        template = upsert('project_template', tpl['name'], ProjectTemplate, @company.project_templates,
                          name: tpl['name'], template_type: tpl['template_type'], is_active: true, is_deleted: false,
                          phase_count: tpl['phases'].size, location_id: nil)
        return unless template

        tpl['phases'].each_with_index do |ph, i|
          phase = upsert('project_template_phase', "#{tpl['name']}:#{i}", ProjectTemplatePhase, template.project_template_phases,
                         name: ph['name'], position: i, visible_to_client: true, is_required: true,
                         notify_client_on_start: false, notify_client_on_complete: false)
          next unless phase

          ph['tasks'].each_with_index do |t, j|
            upsert('project_template_task', "#{tpl['name']}:#{i}:#{j}", ProjectTemplatePhaseTask, phase.project_template_phase_tasks,
                   name: t, position: j, is_required: false, visible_to_client: false)
          end
        end
        @template = template
      end

      def source_id_for(name) = name.present? ? id_for('source', name) : nil
      def lender_id_for(name) = name.present? ? id_for('lender', name) : nil

      # ------------------------------------------------------------ vendors

      def load_vendors
        @data['vendors'].each do |v|
          upsert('vendor', v['ghl_key'], Vendor, @company.vendors,
                 name: v['name'], vendor_type: v['vendor_type'], status: 'active', active: true, is_vendor: true,
                 is_deleted: false,
                 notes: v['source_company_names'].size > 1 ? "Names in GoHighLevel: #{v['source_company_names'].join('; ')}" : nil)
        end
        @data['vendor_contacts'].each do |p|
          vendor_id = id_for('vendor', p['vendor_key'])
          next fail_record('vendor_contact', p['ghl_id'], StandardError.new('vendor missing')) unless vendor_id

          vendor = @company.vendors.find(vendor_id)
          upsert('vendor_contact', p['ghl_id'], VendorContact, vendor.vendor_contacts.unscope(where: :is_deleted),
                 company_id: @company.id, first_name: p['first_name'], last_name: p['last_name'],
                 title: p['title'], priority: p['priority'], email: p['email'].presence, phone: p['phone'].presence,
                 is_primary: p['is_primary'], is_deleted: false,
                 notes: lines(p['notes'], p['extra_emails'].any? ? "Other emails: #{p['extra_emails'].join(', ')}" : nil))
        end
      end

      # ------------------------------------------------------------ leads

      def load_leads
        @data['leads'].each do |l|
          others = l['other_opportunities'].map { |o| "#{o['name']} (#{o['stage']}, #{o['status']})" }
          notes = lines(
            "Imported from GoHighLevel#{l['ghl_source'].present? ? ". Source in GHL: #{l['ghl_source']}" : ''}.",
            l['ghl_opportunity_status'] == 'won' ? 'GoHighLevel had this opportunity marked won.' : nil,
            others.any? ? "Other GoHighLevel opportunities: #{others.join('; ')}" : nil,
            l['extra_emails'].any? ? "Other emails: #{l['extra_emails'].join(', ')}" : nil,
            l['website'].present? ? "Website: #{l['website']}" : nil,
            l['note_from_field']
          )
          custom = l['custom'].merge('Site Address' => l['site_address'])
          co = l['co_applicant'] || {}
          rec = upsert('lead', l['ghl_id'], Lead, @company.leads,
                       first_name: l['first_name'].presence || l['email'].presence || l['phone'], last_name: l['last_name'],
                       email: l['email'].presence, phone: l['phone'].presence, status: l['status'],
                       owner_id: owner_id(l['owner_email']), source_id: source_id_for(l['source']), location_id: @location_id,
                       street: l['street'], city: l['city'], state: l['state'], zip: l['zip'], country: l['country'],
                       budget_range: l['budget_range'], preferred_bedrooms: num(l['preferred_bedrooms'])&.to_i,
                       preferred_bathrooms: num(l['preferred_bathrooms'])&.to_i, preferred_min_sqft: num(l['preferred_min_sqft'])&.to_i,
                       preferred_home_type: l['preferred_home_type'],
                       co_applicant_first_name: co['first_name'], co_applicant_last_name: co['last_name'],
                       co_applicant_email: co['email'], co_applicant_phone: co['phone'],
                       custom_field_values: custom_values(custom), notes: notes,
                       source_created_at: l['created_at'])
          stamp(rec, l['created_at'], updated_at: (Time.zone.parse(l['updated_at']) rescue nil), last_activity_at: (Time.zone.parse(l['updated_at']) rescue nil))
        end
      end

      # ------------------------------------------------------------ customers

      def load_customers
        taken = @company.accounts.pluck(:name).map(&:downcase).to_set
        @data['accounts'].each do |a|
          existing = id_for('account', a['ghl_id'])
          name = a['name'].presence || 'Customer'
          # Keep the name an account already has: the first load may have made it
          # unique ("Smith (2)"), and a dealer may have renamed it since.
          name = @company.accounts.where(id: existing).pick(:name) || name if existing
          unless existing
            base = name
            n = 1
            name = "#{base} (#{n += 1})" while taken.include?(name.downcase)
          end
          taken << name.downcase
          b = a['billing'] || {}
          others = (a['lead_phase_opportunities'] || []).map { |o| "#{o['name']} (#{o['stage']}, #{o['status']})" }
          acct = upsert('account', a['ghl_id'], Account, @company.accounts,
                        name: name, owner_id: owner_id(a['owner_email']), source_id: source_id_for(a['source']),
                        location_id: @location_id, billing_street: b['street'], billing_city: b['city'],
                        billing_state: b['state'], billing_postal_code: b['zip'], billing_country: b['country'],
                        notes: lines('Imported from GoHighLevel.', others.any? ? "Lead-Phase opportunities in GHL: #{others.join('; ')}" : nil))
          next unless acct

          stamp(acct, a['created_at'])
          a['contacts'].each do |c|
            rec = upsert('contact', c['ghl_id'], Contact, @company.contacts,
                         account_id: acct.id, first_name: c['first_name'].presence || c['last_name'].presence || c['email'].presence || 'Unknown',
                         last_name: c['first_name'].present? ? c['last_name'] : nil,
                         email: c['email'].presence, phone: c['phone'].presence, is_primary: c['is_primary'],
                         owner_id: owner_id(c['owner_email'] || a['owner_email']), location_id: @location_id,
                         street: c['street'], city: c['city'], state: c['state'], zip: c['zip'], country: c['country'],
                         custom_field_values: custom_values(c['custom']),
                         notes: lines(c['note_from_field'], (c['extra_emails'] || []).any? ? "Other emails: #{c['extra_emails'].join(', ')}" : nil))
            stamp(rec, c['created_at'])
          end
        end
      end

      # ------------------------------------------------------------ deals

      OPEN_START = 'deposit_collected'

      def load_deals
        first_open = (@data['reference']['deal_stages'].map { |s| s[1] } - %w[closed_won closed_lost]).first || OPEN_START
        @data['deals'].each do |d|
          account_id = id_for('account', d['account_ghl_id'])
          contact_id = id_for('contact', d['contact_ghl_id'])
          co_id = d['co_applicant_ghl_id'] && id_for('contact', d['co_applicant_ghl_id'])
          next fail_record('deal', d['ghl_id'], StandardError.new('customer missing')) unless account_id

          payment = { 'Cash' => 'cash', 'Pre-Approved' => 'finance', 'Needs Financing' => 'finance' }[d['payment_type']]
          existing = id_for('deal', d['ghl_id'])
          rec = upsert('deal', d['ghl_id'], Deal, @company.deals,
                       name: d['name'], account_id: account_id, contact_id: contact_id, co_applicant_contact_id: co_id,
                       owner_id: owner_id(d['owner_email']), location_id: @location_id, value: num(d['value']) || 0,
                       source_id: source_id_for(d['source']), lead_source: d['ghl_source'],
                       lender_id: lender_id_for(d['lender']), payment_type: payment,
                       financed_amount: num(d['financed_amount']), down_payment: num(d['down_payment']),
                       delivery_street: d['delivery_address'],
                       custom_field_values: custom_values(d['custom']),
                       description: lines("Imported from GoHighLevel: #{d['ghl_pipeline']} / #{d['ghl_stage']} (#{d['ghl_status']}).", d['note'])) do |deal|
            deal.stage = first_open if deal.new_record?
          end
          next unless rec

          won = d['stage'] == 'closed_won' ? (Time.zone.parse(d['won_at'] || d['last_stage_change_at']) rescue nil) : nil
          lost = d['stage'] == 'closed_lost' ? (Time.zone.parse(d['last_stage_change_at']) rescue nil) : nil
          # The real stage without callbacks: no accounting post, lifecycle webhook or sold-home notice.
          rec.update_columns(stage: d['stage'], won_at: won, lost_at: lost)
          stamp(rec, d['created_at'])
          @report['deal_stage'][d['stage']] += 1 unless existing
        end
      end

      # ------------------------------------------------------------ projects

      def load_projects
        template = @template || @company.project_templates.find_by(id: id_for('project_template', @data['reference']['project_template']['name']))
        return fail_record('project', 'all', StandardError.new('project template missing')) unless template

        @data['projects'].each do |p|
          deal = @company.deals.find_by(id: id_for('deal', p['deal_ghl_id']))
          next fail_record('project', p['ghl_id'], StandardError.new('deal missing')) unless deal

          if (pid = id_for('project', p['ghl_id'])) && (project = @company.projects.find_by(id: pid))
            @report['project'][:updated] += 1
          else
            project = ActiveRecord::Base.transaction(requires_new: true) do
              created = template.create_project!(company: @company, deal: deal, name: p['name'],
                                                 owner: @users[p['owner_email'].to_s.downcase])
              remember('project', p['ghl_id'], created)
              created
            end
            @report['project'][:created] += 1
          end
          apply_project_progress(project, p)
        rescue StandardError => e
          fail_record('project', p['ghl_id'], e)
        end
      end

      # Phase and task status written without callbacks: no phase-started or
      # phase-completed notice goes to the customer for history.
      def apply_project_progress(project, p)
        phases = project.project_phases.order(:position).to_a
        current = nil
        p['phases'].each do |ph|
          phase = phases[ph['position']]
          next unless phase

          status = { 'completed' => 'completed', 'in_progress' => 'in_progress' }.fetch(ph['status'], 'not_started')
          done_at = ph['completed_at'].present? ? (Time.zone.parse(ph['completed_at']) rescue nil) : nil
          phase.update_columns(status: status, completed_at: status == 'completed' ? (done_at || phase.completed_at || Time.current) : nil,
                               started_at: status == 'not_started' ? nil : (phase.started_at || done_at || Time.current))
          current ||= phase if status == 'in_progress'
          tasks = phase.project_phase_tasks.order(:position).to_a
          ph['tasks'].each_with_index do |t, i|
            task = tasks[i]
            next unless task

            task.update_columns(status: t['completed'] ? 'completed' : 'pending')
          end
        end
        completed = phases.count { |ph| ph.reload.status == 'completed' }
        project.update_columns(
          status: p['status'] == 'completed' ? 'completed' : 'active',
          current_phase_id: current&.id, phase_count: phases.size, completed_phase_count: completed,
          progress_percent: phases.empty? ? 0 : (completed * 100 / phases.size),
          delivery_street: p['delivery_address'],
          started_at: (Date.parse(p['started_at']) rescue project.started_at),
          actual_completion_date: (Date.parse(p['actual_completion_date']) rescue nil)
        )
      end

      # ------------------------------------------------------------ children

      def record_ref(type, ghl_id)
        case type
        when 'Lead' then ['Lead', id_for('lead', ghl_id)]
        when 'Contact' then ['Contact', id_for('contact', ghl_id)]
        when 'VendorContact'
          vc = VendorContact.where(company_id: @company.id).find_by(id: id_for('vendor_contact', ghl_id))
          vc ? ['Vendor', vc.vendor_id, vc] : [nil, nil]
        else [nil, nil]
        end
      end

      def load_notes
        @data['notes'].each do |n|
          next @report['note'][:skipped] += 1 if n['skipped'] || n['record_type'].nil? || n['content'].blank?

          etype, eid, vc = record_ref(n['record_type'], n['record_ghl_id'])
          next @report['note'][:no_parent] += 1 unless eid

          prefix = [n['category'] == 'internal comment' ? 'GoHighLevel internal comment' : 'GoHighLevel note',
                    vc ? "about #{vc.name}" : nil].compact.join(' ')
          rec = upsert('note', n['ghl_id'], Note, Note.where(entity_type: etype, entity_id: eid.to_s),
                       entity_type: etype, entity_id: eid.to_s, content: "[#{prefix}]\n#{n['content']}",
                       user_id: owner_id(n['author_email']), category: 'general')
          stamp(rec, n['created_at'], updated_at: (Time.zone.parse(n['created_at']) rescue nil))
        end
      end

      COMM_STATUS = { 'failed' => 'failed', 'undelivered' => 'failed' }.freeze

      def load_communications
        @data['communications'].each do |c|
          next if %w[call social].include?(c['channel'])
          next @report['communication'][:skipped] += 1 if c['skipped']

          ctype, cid, = record_ref(c['record_type'], c['record_ghl_id'])
          next @report['communication'][:no_parent] += 1 unless cid

          at = (Time.zone.parse(c['at']) rescue nil)
          inbound = c['direction'] == 'inbound'
          # GHL leaves from/to off some messages; the person's side is their own
          # phone or email, and the dealer's side is unknown rather than invented.
          person = c['channel'] == 'email' ? parent_contact(ctype, cid, :email) : parent_contact(ctype, cid, :phone)
          from = c['from'].presence || (inbound ? person : nil) || 'unknown'
          to = c['to'].presence || (inbound ? nil : person) || 'unknown'
          body = c['body'].presence || (c['channel'] == 'email' ? '(email body not imported)' : nil) ||
                 (c['attachments'].any? ? '(attachment)' : '(no text)')
          rec = upsert('communication', c['ghl_id'], Communication, Communication.where(company_id: @company.id),
                       company_id: @company.id, communicable_type: ctype, communicable_id: cid,
                       channel: c['channel'], direction: inbound ? 'inbound' : 'outbound',
                       status: COMM_STATUS.fetch(c['status'].to_s, inbound ? 'delivered' : 'sent'),
                       subject: c['subject'], body: body, from_address: from, to_address: to, cc_addresses: c['cc'],
                       sent_at: inbound ? nil : at, received_at: inbound ? at : nil, external_id: "ghl:#{c['ghl_id']}",
                       provider: 'gohighlevel', portal_visible: false, user_id: owner_id(c['sent_by_email']),
                       metadata: { 'imported_from' => 'gohighlevel', 'ghl_conversation_id' => c['ghl_conversation_id'],
                                   'ghl_sent_by' => c['sent_by'], 'ghl_attachments' => c['attachments'] }.compact)
          stamp(rec, c['at'], updated_at: at)
        end
      end

      def parent_contact(type, id, attr)
        klass = { 'Lead' => Lead, 'Contact' => Contact }[type]
        klass&.where(id: id)&.pick(attr)
      end

      # Calls and appointments: inserted without callbacks, so no invite,
      # reminder or assignee notice goes out for history.
      def load_activities
        rows = Hash.new { |h, k| h[k] = [] }
        @data['communications'].each do |c|
          next unless %w[call social].include?(c['channel'])
          next if c['skipped']

          type, id, vc = record_ref(c['record_type'], c['record_ghl_id'])
          next @report['activity'][:no_parent] += 1 unless id

          if c['channel'] == 'social' || type == 'Vendor'
            label = c['channel'] == 'social' ? "#{c['network'].to_s.capitalize} message (#{c['direction']})" : "Call (#{c['direction']}) with #{vc&.name}"
            content = c['channel'] == 'social' ? c['body'].to_s : "#{c['call_duration'].to_i}s, #{c['call_status']}"
            rec = upsert('note', "msg:#{c['ghl_id']}", Note, Note.where(entity_type: type, entity_id: id.to_s),
                         entity_type: type, entity_id: id.to_s, content: "[GoHighLevel #{label}]\n#{content}".strip,
                         user_id: owner_id(c['sent_by_email']), category: 'general')
            stamp(rec, c['at'])
            next
          end
          next if id_for('activity', c['ghl_id'])

          at = Time.zone.parse(c['at'])
          secs = c['call_duration'].to_i
          outcome = { 'completed' => 'answered', 'voicemail' => 'voicemail', 'no-answer' => 'no_answer', 'busy' => 'busy' }[c['call_status'].to_s]
          rows[type] << { ghl: c['ghl_id'], parent: id, user_id: actor_id(c['sent_by_email']),
                          attrs: { activity_type: 'call', subject: "Call (#{c['direction']}#{secs.positive? ? ", #{(secs / 60.0).ceil} min" : ''})",
                                   status: 'completed', priority: 'medium', call_direction: c['direction'] == 'inbound' ? 'inbound' : 'outbound',
                                   call_outcome: outcome, duration_minutes: secs.positive? ? (secs / 60.0).ceil : nil,
                                   phone_number: c['direction'] == 'inbound' ? c['from'] : c['to'], completed_at: at,
                                   created_at: at, updated_at: at } }
        end
        @data['appointments'].each do |e|
          next @report['appointment'][:skipped_internal] += 1 unless e['import']

          type, id, = record_ref(e['record_type'], e['record_ghl_id'])
          next @report['appointment'][:no_parent] += 1 unless id
          next if id_for('activity', e['ghl_id'])

          start = Time.zone.parse(e['start'])
          finish = (Time.zone.parse(e['end']) rescue nil)
          rows[type] << { ghl: e['ghl_id'], parent: id, user_id: actor_id(e['assigned_email']),
                          attrs: { activity_type: 'meeting', subject: e['title'].presence || 'Appointment', status: start < Time.current ? 'completed' : 'pending',
                                   priority: 'medium', start_time: start, end_time: finish, completed_at: start < Time.current ? start : nil,
                                   assigned_to_id: owner_id(e['assigned_email']), created_at: start, updated_at: start } }
        end

        { 'Lead' => [LeadActivity, :lead_id], 'Contact' => [ContactActivity, :contact_id] }.each do |type, (klass, fk)|
          list = rows[type]
          missing_user = list.count { |r| r[:user_id].nil? }
          if missing_user.positive?
            @report['activity'][:failed] += missing_user
            @errors << "#{missing_user} #{type} calls/appointments have no user and no fallback user was given"
          end
          account_of = type == 'Contact' ? Contact.where(id: list.map { |r| r[:parent] }).pluck(:id, :account_id).to_h : {}
          list.reject { |r| r[:user_id].nil? }.each_slice(500) do |slice|
            payload = slice.map do |r|
              base = r[:attrs].merge(fk => r[:parent], user_id: r[:user_id], remind_customer: false,
                                     send_calendar_invite: false, metadata: { 'imported_from' => 'gohighlevel', 'ghl_id' => r[:ghl] })
              base[:company_id] = @company.id if klass.column_names.include?('company_id')
              base[:account_id] = account_of[r[:parent]] if klass.column_names.include?('account_id') && type == 'Contact'
              base
            end
            keys = payload.flat_map(&:keys).uniq
            payload = payload.map { |row| keys.index_with { |k| row[k] } }
            result = klass.insert_all(payload, returning: %w[id])
            result.rows.each_with_index do |(new_id), i|
              remember_raw('activity', slice[i][:ghl], klass.name, new_id)
            end
            @report["#{type.downcase}_activity"][:created] += slice.size
          end
        end
      end

      def remember_raw(type, source_id, record_type, record_id)
        now = Time.current
        MigrationRecord.upsert(
          { company_id: @company.id, source_system: SYSTEM, source_type: type, source_id: source_id.to_s, record_type: record_type,
            record_id: record_id, batch: @batch, loaded_at: now, created_at: now, updated_at: now },
          unique_by: :idx_migration_records_source, update_only: %i[record_id batch loaded_at]
        )
        @ids[[type, source_id.to_s]] = [record_id, now]
      end

      # Consent with its original date and evidence. opt_out!/opt_in! would
      # stamp today, which would falsify the record, so the columns are
      # written directly after the row exists.
      def load_consent
        @data['consent'].each_with_index do |c, i|
          type, id, vc = record_ref(c['record_type'], c['record_ghl_id'])
          next @report['consent'][:no_parent] += 1 unless id

          at = (Time.zone.parse(c['at'].to_s) rescue nil) || Time.current
          if c['channel'] == 'sms_undeliverable'
            tag_record(type, id, 'sms_undeliverable') unless type == 'Vendor'
            @report['consent'][:sms_undeliverable] += 1
            next
          end
          if type == 'Vendor'
            if c['channel'] == 'sms'
              vc&.record_sms_consent!(opted_in: c['opted_in'], source: 'import', note: c['evidence'], recorded_at: at)
              @report['consent'][:vendor_contact_sms] += 1
            elsif vc && !vc.notes.to_s.include?(c['evidence'].to_s)
              # vendor_contacts has no email opt-out column; keep the fact where people will see it.
              vc.update_columns(notes: lines(vc.notes, "Email: #{c['opted_in'] ? 'opted in' : 'unsubscribed'} in GoHighLevel #{at.to_date} (#{c['evidence']})"))
              @report['consent'][:vendor_contact_email_note] += 1
            end
            next
          end
          recipient = type.constantize.find(id)
          category = c['scope'] == 'marketing' ? 'marketing' : nil
          begin
            ActiveRecord::Base.transaction(requires_new: true) do
              pref = CommunicationPreference.find_or_create_by!(recipient: recipient, channel: c['channel'], category: category)
              record = { 'action' => c['opted_in'] ? 'opted_in' : 'opted_out', 'timestamp' => at.iso8601,
                         'source' => 'gohighlevel_import', 'evidence' => c['evidence'], 'ghl_message_id' => c['ghl_message_id'] }.compact
              meta = pref.compliance_metadata.is_a?(Hash) ? pref.compliance_metadata : { 'records' => [] }
              meta['records'] = (meta['records'] || []).reject { |r| r['source'] == 'gohighlevel_import' && r['timestamp'] == record['timestamp'] } + [record]
              newer = pref.opted_in_at.to_i > at.to_i || pref.opted_out_at.to_i > at.to_i
              cols = { compliance_metadata: meta }
              unless newer
                cols.merge!(opted_in: c['opted_in'], opted_in_at: c['opted_in'] ? at : pref.opted_in_at,
                            opted_out_at: c['opted_in'] ? nil : at, opted_out_reason: c['opted_in'] ? nil : c['evidence'].to_s.truncate(250))
              end
              pref.update_columns(cols)
              mirror_consent(recipient, c, at) unless newer
            end
            @report['consent'][c['opted_in'] ? :opted_in : :opted_out] += 1
          rescue StandardError => e
            fail_record('consent', "#{c['record_ghl_id']}##{i}", e)
          end
        end
        (@data['rsvps'] || []).each do |r|
          type, id, = record_ref(r['record_type'], r['record_ghl_id'])
          tag_record(type, id, @data['reference']['tags'].find { |t| t.include?('rsvp') }) if id && type != 'Vendor'
        end
      end

      # The flags campaigns and the STOP handler read, kept in step with the preference.
      def mirror_consent(recipient, c, at)
        cols = {}
        if c['channel'] == 'sms' && c['scope'] == 'all' && !c['opted_in']
          cols[:opt_out_sms] = true if recipient.has_attribute?(:opt_out_sms)
          cols[:opt_out_sms_at] = at if recipient.has_attribute?(:opt_out_sms_at)
          cols[:opt_in_sms] = false if recipient.has_attribute?(:opt_in_sms)
          phone = sms_ok_phone(recipient.phone)
          if phone
            CampaignSuppression.find_or_create_by!(company_id: @company.id, phone_number: phone) do |s|
              s.reason = 'sms_stop'
              s.suppressed_at = at
              s.notes = "Imported from GoHighLevel: #{c['evidence']}".truncate(250)
            end
          end
        elsif c['channel'] == 'sms' && c['scope'] == 'marketing'
          cols[:opt_in_sms] = c['opted_in'] if recipient.has_attribute?(:opt_in_sms)
        elsif c['channel'] == 'email' && !c['opted_in']
          cols[:opt_out_email] = true if recipient.has_attribute?(:opt_out_email)
          cols[:opt_out_email_at] = at if recipient.has_attribute?(:opt_out_email_at)
        end
        recipient.update_columns(cols) if cols.any?
      end

      def load_tags
        @data['leads'].each { |l| l['tags'].each { |t| tag_record('Lead', id_for('lead', l['ghl_id']), t) } }
        @data['accounts'].each do |a|
          primary = a['contacts'].find { |c| c['is_primary'] }
          (a['tags'] || []).each { |t| tag_record('Contact', id_for('contact', primary['ghl_id']), t) } if primary
        end
      end

      def tag_record(type, id, name)
        return unless id && name

        tag_id = id_for('tag', name) || Tag.find_by(company_id: @company.id, name: name)&.id
        return @report['tag'][:missing_tag] += 1 unless tag_id
        return if TagAssignment.exists?(tag_id: tag_id, entity_type: type, entity_id: id)

        TagAssignment.create!(tag_id: tag_id, entity_type: type, entity_id: id, company_id: @company.id,
                              assigned_by: 'GoHighLevel import', assigned_at: Time.current)
        @report['tag_assignment'][:created] += 1
      rescue StandardError => e
        fail_record('tag_assignment', "#{type}:#{id}:#{name}", e)
      end

      def load_tasks
        @data['tasks'].each do |t|
          type, id, = record_ref(t['record_type'], t['record_ghl_id'])
          upsert('task', t['ghl_id'], Task, @company.tasks,
                 title: t['title'].presence || 'Task', description: t['description'], taskable_type: type, taskable_id: id,
                 status: t['completed'] ? :completed : :pending, due_date: t['due'], assigned_to_id: owner_id(t['assigned_email']),
                 location_id: @location_id, task_module: 'crm', created_by: 'GoHighLevel import')
        end
      end

      # ------------------------------------------------------------ files

      def load_documents
        @data['documents'].each do |d|
          next if id_for('document', d['ghl_id'])

          owner = case d['owner_type']
                  when 'Lead' then @company.leads.find_by(id: id_for('lead', d['owner_ghl_id']))
                  when 'Account' then @company.accounts.find_by(id: id_for('account', d['owner_ghl_id']))
                  when 'Communication' then Communication.where(company_id: @company.id).find_by(id: id_for('communication', d['owner_ghl_id']))
                  end
          next @report['document'][:no_parent] += 1 unless owner

          if @dry_run
            head_check('document', d['url'])
            next
          end
          download(d['url']) do |file, content_type|
            name = d['file_name'].presence || File.basename(URI(d['url']).path)
            if owner.is_a?(Communication)
              owner.attachments.attach(io: file, filename: name, content_type: content_type)
              remember_raw('document', d['ghl_id'], 'ActiveStorage::Attachment', owner.attachments.last.id)
            else
              doc = PortalDocument.new(owner: owner, category: d['category'].presence || 'other', document_name: name,
                                       description: d['opportunity'].present? ? "From GoHighLevel opportunity #{d['opportunity']}" : 'From GoHighLevel',
                                       uploaded_by: 'staff')
              doc.file.attach(io: file, filename: name, content_type: content_type)
              doc.save!
              remember('document', d['ghl_id'], doc)
            end
            @report['document'][:created] += 1
          end
        rescue StandardError => e
          fail_record('document', d['ghl_id'], e)
        end
      end

      def load_media
        @data['media'].each do |m|
          next if id_for('media', m['ghl_id'])
          next if m['destination'] == 'private storage' && (@report['media'][:private_left_for_review] += 1)

          if @dry_run
            head_check('media', m['url'])
            next
          end
          download(m['url']) do |file, content_type|
            upload = ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: m['name'], type: content_type)
            s3 = S3UploadService.new.upload(upload, folder: "companies/#{@company.id}/media")
            kind = content_type.to_s.start_with?('image/') ? :image : content_type.to_s.start_with?('video/') ? :video : :other
            media = WebsiteMedia.create!(company_id: @company.id, name: m['name'], url: s3[:url], s3_key: s3[:key],
                                         s3_bucket: ENV['AWS_S3_BUCKET'], mime_type: content_type, file_size: file.size, file_type: kind)
            remember('media', m['ghl_id'], media)
            @report['media'][:created] += 1
          end
        rescue StandardError => e
          fail_record('media', m['ghl_id'], e)
        end
      end

      def head_check(type, url)
        uri = URI(url)
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 10, read_timeout: 20) do |http|
          http.head(uri.request_uri)
        end
        ok = res.is_a?(Net::HTTPSuccess) || res.is_a?(Net::HTTPRedirection)
        @report[type][ok ? :reachable : :unreachable] += 1
        @errors << "#{type} not downloadable (#{res.code}): #{url.truncate(120)}" unless ok
      rescue StandardError => e
        @report[type][:unreachable] += 1
        @errors << "#{type} check failed (#{e.class}): #{url.truncate(120)}"
      end

      # Streams to a Tempfile so a large video never sits in memory.
      def download(url, limit = 3)
        uri = URI(url)
        Tempfile.create(['ghl', File.extname(uri.path)], binmode: true) do |file|
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 15, read_timeout: 120) do |http|
            http.request(Net::HTTP::Get.new(uri.request_uri, 'User-Agent' => 'DealerTide-Migration/1.0')) do |res|
              if res.is_a?(Net::HTTPRedirection) && limit.positive?
                return download(res['location'], limit - 1) { |f, ct| yield f, ct }
              end
              raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

              res.read_body { |chunk| file.write(chunk) }
              file.flush
              file.rewind
              yield file, res['content-type'].to_s.split(';').first.presence || 'application/octet-stream'
            end
          end
        end
      end

      # ------------------------------------------------------------ report

      def summary(elapsed)
        say ''
        say "#{@dry_run ? 'DRY RUN (rolled back)' : 'LOADED'}: company #{@company.id} #{@company.name}, batch #{@batch}, #{elapsed.round}s"
        @report.sort_by { |k, _| k.to_s }.each { |k, v| say "  #{k}: #{v.sort_by { |a, _| a.to_s }.map { |a, b| "#{a} #{b}" }.join(', ')}" }
        if @edited.any?
          say "  kept DealerTide edits (#{@edited.size}):"
          @edited.first(30).each { |e| say "    #{e}" }
        end
        say "  errors: #{@errors.size}"
        @errors.first(60).each { |e| say "    #{e}" }
        { report: @report, errors: @errors, edited: @edited }
      end
    end
  end
end

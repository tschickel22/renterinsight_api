# frozen_string_literal: true

module Api
  module Partner
    module V1
      class LeadsController < BaseController
        include PartnerWebhooks
        fires_webhooks resource: :lead

        before_action :authorize_leads
        before_action :set_lead, only: [:show, :update, :destroy]

        # GET /api/partner/v1/leads
        def index
          leads = company_scope(Lead)

          # Filters
          leads = leads.where(status: params[:status]) if params[:status].present?
          leads = leads.where(source_id: params[:source_id]) if params[:source_id].present?
          leads = leads.where(owner_id: params[:owner_id]) if params[:owner_id].present?
          leads = leads.where(location_id: params[:location_id]) if params[:location_id].present?
          leads = leads.where(is_converted: params[:is_converted]) if params[:is_converted].present?

          # Search
          if params[:q].present?
            q = "%#{params[:q]}%"
            leads = leads.where(
              "first_name ILIKE :q OR last_name ILIKE :q OR email ILIKE :q OR CONCAT(first_name, ' ', last_name) ILIKE :q",
              q: q
            )
          end

          # Cursor-based pagination
          leads = leads.order(:id)
          leads = leads.where("id > ?", params[:after].to_i) if params[:after].present?
          limit = [params.fetch(:limit, 50).to_i, 200].min
          leads = leads.limit(limit + 1)

          records = leads.to_a
          has_more = records.size > limit
          records = records.first(limit)

          render json: {
            data: records.map { |l| lead_json(l) },
            meta: {
              has_more: has_more,
              next_cursor: has_more ? records.last&.id&.to_s : nil,
              limit: limit
            }
          }
        end

        # GET /api/partner/v1/leads/:id
        def show
          render json: { data: lead_json(@lead, detailed: true) }
        end

        # POST /api/partner/v1/leads
        #
        # Applies the current API key's webhook_config in this order before
        # saving so a Zapier/FB payload becomes a well-attributed, well-assigned
        # lead even when the caller can't map every field:
        #
        #   1. Source — SourceResolverService takes payload source_id/source
        #      and falls back to webhook_config.default_source_id, with fuzzy
        #      matching + auto-creation for unknown names.
        #   2. Location — payload wins; otherwise webhook_config.default_location_id.
        #   3. Owner — payload wins; otherwise webhook_config.assignment_mode
        #      picks (specific user, round-robin from a shared list, or leave
        #      unassigned for a workflow to handle).
        #   4. Dedupe — if webhook_config.dedupe_enabled and IdentityResolver
        #      matches an existing Lead or Contact by email/phone, we DON'T
        #      create a duplicate. We return 202 with the matched record so
        #      Zapier's history reflects "handled, not duplicated."
        def create
          attrs = lead_params.to_h.symbolize_keys
          config = webhook_config

          # Facebook Lead Ads (and most Zapier FB payloads) use field keys like
          # full_name / phone_number that don't match our first_name/last_name/
          # phone. Fill our canonical fields from those aliases when the caller
          # didn't map them, so an FB lead lands well-attributed even if the Zap
          # wasn't perfectly configured.
          apply_field_aliases!(attrs)

          # Default status to 'new' when the payload doesn't provide one so
          # inbound Zapier/FB leads always land on the "All Active" / "New"
          # tab instead of an empty pill that leaves dealers scratching
          # their head. Callers can still override by passing status:.
          attrs[:status] = 'new' if attrs[:status].blank?

          apply_source_config!(attrs, config)
          apply_location_config!(attrs, config)

          # Map any inbound keys matching a dealer-defined custom field onto
          # custom_field_values, then send everything still unmapped to notes so
          # nothing (e.g. Facebook qualifying questions) is dropped.
          #
          # Resolved BEFORE the dedupe branch below: a repeat inquiry needs these
          # too. While this ran after the early return, a returning customer's
          # answers only ever reached the notes text — correctly mapped keys were
          # silently discarded because the request never got this far. Dealers
          # test with people already in the system more often than not, so that
          # path is the common one, not the edge case.
          cf_values, cf_consumed = extract_inbound_custom_fields('leads')

          if config['dedupe_enabled'] && (match = dedupe_match(attrs))
            # Don't create a duplicate — but a returning inquiry is NOT a no-op.
            # Absorb any new details onto the matched record and notify its
            # owner, so the dealer hears about the re-engagement instead of it
            # vanishing silently. Best-effort: a notify failure never fails the
            # request (Zapier still sees a clean 202).
            absorb_inquiry_into_match!(match, attrs, config, cf_values: cf_values, cf_consumed: cf_consumed)
            return render json: {
              data: nil,
              deduped_to: { type: match.type.to_s, id: match.record.id, matched_on: match.matched.to_s }
            }, status: :accepted
          end

          apply_owner_config!(attrs, config)

          attrs[:custom_field_values] = (attrs[:custom_field_values] || {}).merge(cf_values) if cf_values.any?
          mapped_keys = attrs.keys + cf_consumed
          note_content = inbound_note_content(mapped_keys)
          attrs = merge_inbound_note(attrs, mapped_keys)

          lead = company_scope(Lead).new(attrs)

          if lead.save
            write_inbound_note!('lead', lead.id, note_content)
            render json: { data: lead_json(lead, detailed: true) }, status: :created
          else
            render json: { error: "Validation failed", details: lead.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/partner/v1/leads/:id
        def update
          if @lead.update(lead_params)
            render json: { data: lead_json(@lead, detailed: true) }
          else
            render json: { error: "Validation failed", details: @lead.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/partner/v1/leads/:id
        def destroy
          @lead.destroy!
          render json: { data: { id: @lead.id, deleted: true } }
        end

        private

        def authorize_leads
          case action_name
          when "index", "show"
            authorize_permission!(:leads, :read)
          when "create"
            authorize_permission!(:leads, :create)
          when "update"
            authorize_permission!(:leads, :update)
          when "destroy"
            authorize_permission!(:leads, :delete)
          end
        end

        def set_lead
          @lead = company_scope(Lead).find(params[:id])
        end

        def lead_params
          params.permit(*Integration::MappableFields.keys('leads'))
        end

        # Map common inbound aliases (Facebook Lead Ads / Zapier field keys) onto
        # our canonical fields, ONLY when the caller didn't already provide them.
        # - full_name (any case) -> first_name + last_name (split on whitespace)
        # - phone_number         -> phone
        # - email_address        -> email
        # Never overwrites a value the caller mapped correctly.
        def apply_field_aliases!(attrs)
          if attrs[:first_name].blank? && attrs[:last_name].blank?
            full = first_present_param(:full_name, :fullName, :FULL_NAME, :name).to_s.strip
            if full.present?
              first, *rest = full.split(/\s+/)
              attrs[:first_name] = first
              attrs[:last_name]  = rest.join(' ').presence
            end
          end

          split_full_name_out_of_first_name!(attrs)

          if attrs[:phone].blank?
            phone = first_present_param(:phone_number, :phoneNumber, :PHONE)
            attrs[:phone] = phone if phone.present?
          end

          if attrs[:email].blank?
            email = first_present_param(:email_address, :emailAddress, :EMAIL)
            attrs[:email] = email if email.present?
          end
        end

        # A whole name sitting in first_name with nothing in last_name is a
        # full name, not a first name — split it.
        #
        # Facebook's default lead form collects one "Full name" field, so a Zap
        # built from our payload template ("first_name": "{{First Name}}") has
        # no first-name token to map and the dealer drops Full Name into it. The
        # alias split above can't help: it only runs when BOTH name fields are
        # blank, and first_name arrives populated. The lead then lands as
        # first_name "Tia May" / last_name NULL, which breaks last-name sort,
        # A-Z grouping, merge fields and "Hi {{first_name}}" campaign greetings.
        #
        # Only fires when last_name is blank, so a correctly mapped payload is
        # never touched. A genuine two-word first name with no surname
        # ("Mary Ann") does get split — rare, and recoverable by editing the
        # lead, where the current behavior is wrong on every inbound FB lead.
        def split_full_name_out_of_first_name!(attrs)
          return if attrs[:last_name].present?

          first = attrs[:first_name].to_s.strip
          return unless first.match?(/\s/)

          head, *rest = first.split(/\s+/)
          attrs[:first_name] = head
          attrs[:last_name]  = rest.join(' ').presence
        end

        # First non-blank value among the given raw param keys.
        def first_present_param(*keys)
          keys.each do |k|
            v = params[k]
            return v if v.respond_to?(:present?) ? v.present? : v.to_s.present?
          end
          nil
        end

        def webhook_config
          (current_api_key&.webhook_config || {}).with_indifferent_access
        end

        def apply_source_config!(attrs, config)
          resolved = SourceResolverService.resolve(
            company: @current_company,
            source_id: attrs[:source_id],
            source_name: attrs.delete(:source),
            default_source_id: config['default_source_id']
          )
          attrs[:source_id] = resolved&.id if resolved && attrs[:source_id].blank?
        end

        # Location rules for a webhook key:
        #   - If the payload includes location_id AND it's in the key's allowed
        #     list, honor it (per-location Zaps sending explicit location).
        #   - If the payload's location_id is NOT in the allowed list, ignore
        #     it and fall back to the key's first default — prevents a
        #     misconfigured Zap from attributing leads to a wrong location.
        #   - If the payload has no location_id, use the first default.
        def apply_location_config!(attrs, config)
          allowed = Array(config['default_location_ids']).map(&:to_i).reject(&:zero?)
          allowed = [config['default_location_id'].to_i] if allowed.empty? && config['default_location_id'].present?

          if attrs[:location_id].present?
            return if allowed.empty? # nothing to enforce against
            attrs[:location_id] = allowed.first unless allowed.include?(attrs[:location_id].to_i)
          else
            attrs[:location_id] = allowed.first if allowed.any?
          end
        end

        def apply_owner_config!(attrs, config)
          return if attrs[:owner_id].present?

          case config['assignment_mode'].to_s
          when 'specific'
            user_id = config['assigned_user_id']
            attrs[:owner_id] = user_id if user_id.present? && User.exists?(id: user_id, company_id: @current_company.id, status: 'active')
          when 'specific_per_location'
            # Per-location: map from webhook_config['assigned_user_ids_by_location']
            # keyed by the RESOLVED location_id (already applied by
            # apply_location_config!). Skips inactive users. Falls through to
            # nil (unassigned) if no mapping exists — validation at key-create
            # time prevents this in the common case, but a config edited after
            # the fact could theoretically miss a location.
            map = config['assigned_user_ids_by_location'] || {}
            loc_key = attrs[:location_id].to_s
            picked_id = map[loc_key] || map[loc_key.to_i]
            if picked_id.present? && User.exists?(id: picked_id, company_id: @current_company.id, status: 'active')
              attrs[:owner_id] = picked_id.to_i
            end
          when 'round_robin'
            picked_id = round_robin_pick(config)
            attrs[:owner_id] = picked_id if picked_id
          # 'unassigned' or unknown: leave nil, downstream workflow handles it
          end
        end

        # Round-robin pick supports two storage shapes:
        #
        #   1. Inline on the key (default UX): webhook_config.assigned_user_ids
        #      is an ordered array + webhook_config.round_robin_cursor is the
        #      pointer to the next assignee. Simple case — no separate list
        #      resource needed for the operator to manage.
        #   2. Shared list (advanced UX): webhook_config.round_robin_list_id
        #      references a RoundRobinAssignmentList so multiple keys or a
        #      workflow can share one cursor. Falls back to this when the
        #      inline list is empty.
        #
        # Skips inactive users; returns nil if every configured user is inactive
        # (caller leaves the lead unassigned).
        def round_robin_pick(config)
          inline_ids = Array(config['assigned_user_ids']).map(&:to_i).reject(&:zero?)
          return round_robin_from_shared_list(config['round_robin_list_id']) if inline_ids.empty?

          round_robin_from_inline_list(inline_ids)
        end

        def round_robin_from_shared_list(list_id)
          return nil if list_id.blank?
          list = RoundRobinAssignmentList.active.find_by(id: list_id, company_id: @current_company.id)
          list&.next_active_user!&.id
        end

        # Atomic cursor advance directly on the api_keys row's webhook_config
        # JSONB. Reloads inside the lock so two concurrent Zap POSTs can't
        # hand the same lead to the same user.
        def round_robin_from_inline_list(user_ids)
          key = current_api_key
          key.with_lock do
            key.reload
            cfg = (key.webhook_config || {}).with_indifferent_access
            ids = Array(cfg['assigned_user_ids']).map(&:to_i).reject(&:zero?)
            return nil if ids.empty?

            active_ids = User.where(id: ids, company_id: @current_company.id, status: 'active').pluck(:id)
            return nil if active_ids.empty?

            ordered_actives = ids.select { |id| active_ids.include?(id) }
            idx = cfg['round_robin_cursor'].to_i % ordered_actives.length
            picked_id = ordered_actives[idx]

            new_cfg = cfg.to_h
            new_cfg['round_robin_cursor'] = (idx + 1) % ordered_actives.length
            key.update_column(:webhook_config, new_cfg)
            picked_id
          end
        end

        def dedupe_match(attrs)
          return nil if attrs[:email].blank? && attrs[:phone].blank?
          IdentityResolver.new(@current_company, email: attrs[:email], phone: attrs[:phone]).resolve
        end

        # A returning inbound (Zapier/FB) inquiry matched an existing record.
        # We don't duplicate it, but we DO want the dealer to know the person
        # re-engaged — mirrors the intake form's :existing_lead "Repeat Inquiry"
        # behavior.
        #
        # Every match type gets a note and an owner notification. It used to be
        # lead-only: an inquiry whose email/phone belonged to a CONTACT or an
        # ACCOUNT returned 202 and did nothing at all — no note, no notify, no
        # lead. The only trace was one log line on Render, so from inside the
        # app the lead had simply vanished, and no search could find it because
        # the person's name was never written anywhere.
        #
        # Entirely best-effort and self-contained in rescue: enrichment and
        # notification failures must never turn a successful dedupe into an
        # error for the caller.
        def absorb_inquiry_into_match!(match, attrs, config, cf_values: {}, cf_consumed: [])
          # Captured before enrichment: enrichment fills blank name fields from
          # the payload, after which "who inquired" and "whose record this is"
          # would look identical even when they weren't.
          inbound_name = [attrs[:first_name], attrs[:last_name]].compact.join(' ').strip
          record = match.record

          enriched =
            case match.type
            when :lead
              enrich_lead_from_inquiry!(record, attrs, cf_values: cf_values, cf_consumed: cf_consumed)
            when :contact
              enrich_contact_from_inquiry!(record, attrs, cf_consumed: cf_consumed)
            else
              # Accounts are organization-shaped — a person's name, email and
              # phone don't belong on their columns. Record the inquiry as a
              # note and notify; don't touch the account's own fields.
              write_inbound_note!('account', record.id, repeat_inquiry_note(attrs, cf_consumed))
              false
            end

          notify_repeat_inquiry(record, config, inbound_name: inbound_name, match_type: match.type, attrs: attrs)
          Rails.logger.info "[Partner::Leads] Absorbed repeat inquiry from " \
                            "'#{inbound_name.presence || 'unnamed'}' (#{attrs[:email] || attrs[:phone]}) " \
                            "into #{match.type} #{record.id} '#{match.name}' " \
                            "(enriched=#{enriched}, matched_on=#{match.matched}) via '#{current_api_key&.name}'"
        rescue => e
          Rails.logger.error "[Partner::Leads] absorb_inquiry_into_match! failed for #{match.type} #{match.record&.id}: #{e.class} - #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
        end

        # Contact counterpart of #enrich_lead_from_inquiry!: fill blanks only,
        # append the inquiry to the notes field, and write a Notes-tab entry.
        #
        # Custom fields are deliberately not applied — cf_values was resolved
        # against the company's LEAD custom fields, which are a different set
        # from its contact fields. Those values still reach the note, so the
        # answers aren't lost.
        def enrich_contact_from_inquiry!(contact, attrs, cf_consumed: [])
          CONTACT_FILLABLE_FROM_INQUIRY.each do |field|
            next unless contact.has_attribute?(field)
            val = attrs[field]
            contact[field] = val if val.present? && contact[field].blank?
          end

          summary = inbound_inquiry_summary(attrs, cf_consumed)
          if summary.present? && contact.has_attribute?(:notes)
            stamp = Time.current.strftime('%Y-%m-%d %H:%M %Z')
            entry = "[#{stamp}] Repeat inquiry via #{inbound_source_label}\n#{summary}"
            contact.notes = [contact.notes.presence, entry].compact.join("\n\n")
          end

          changed = contact.changed?
          contact.save if changed

          write_inbound_note!('contact', contact.id, repeat_inquiry_note(attrs, cf_consumed))
          changed
        end

        # Notes-tab body for an absorbed inquiry. Same shape the lead path
        # writes, so the Notes tab reads identically on any record type.
        def repeat_inquiry_note(attrs, cf_consumed)
          summary = inbound_inquiry_summary(attrs, cf_consumed)
          return nil if summary.blank?

          "🔁 REPEAT INQUIRY via #{inbound_source_label}\n\n#{summary}"
        end

        # Fill any blank contact/qualification fields from the new payload
        # (never overwrite existing data) and append a timestamped note
        # capturing what came in. Saving fires the lead's normal
        # emit_workflow_updated hook. Returns true if the record changed.
        def enrich_lead_from_inquiry!(lead, attrs, cf_values: {}, cf_consumed: [])
          FILLABLE_FROM_INQUIRY.each do |field|
            val = attrs[field]
            lead[field] = val if val.present? && lead[field].blank?
          end

          apply_custom_fields_from_inquiry!(lead, cf_values)

          # Anything that mapped to a custom field is already on the record, so
          # keep it out of the note rather than recording it twice.
          summary = inbound_inquiry_summary(attrs, cf_consumed)
          if summary.present?
            stamp = Time.current.strftime('%Y-%m-%d %H:%M %Z')
            entry = "[#{stamp}] Repeat inquiry via #{inbound_source_label}\n#{summary}"
            lead.notes = [lead.notes.presence, entry].compact.join("\n\n")
          end

          changed = lead.changed?
          lead.save if changed

          # Written after the save so a failed enrichment doesn't leave an
          # orphan note, and unconditionally on summary (not on `changed`) —
          # a repeat inquiry that adds no new field values is still something
          # the dealer needs to see in the Notes tab.
          if summary.present?
            write_inbound_note!('lead', lead.id, "🔁 REPEAT INQUIRY via #{inbound_source_label}\n\n#{summary}")
          end

          changed
        end

        # Human-readable digest of the inbound payload for the note + email,
        # including the raw form answers (e.g. Facebook lead-ad questions) that
        # aren't mapped to columns.
        # Blank-only merge of dealer-defined custom fields, mirroring the
        # FILLABLE_FROM_INQUIRY rule above: a repeat inquiry fills gaps, it
        # never overwrites an answer already on the record.
        def apply_custom_fields_from_inquiry!(lead, cf_values)
          return if cf_values.blank?

          existing = (lead.custom_field_values || {}).deep_stringify_keys
          merged = existing.dup
          cf_values.each do |k, v|
            key = k.to_s
            merged[key] = v if v.present? && existing[key].blank?
          end

          lead.custom_field_values = merged unless merged == existing
        end

        def inbound_inquiry_summary(attrs, skip_keys = [])
          skipped = Array(skip_keys).map { |k| k.to_s.downcase }.to_set
          lines = []
          name = [attrs[:first_name], attrs[:last_name]].compact.join(' ').strip
          lines << "Name: #{name}"                                   if name.present?
          lines << "Email: #{attrs[:email]}"                         if attrs[:email].present?
          lines << "Phone: #{attrs[:phone]}"                         if attrs[:phone].present?
          lines << "Interest: #{attrs[:interests_requirements]}"     if attrs[:interests_requirements].present?
          lines << "Timeframe: #{attrs[:purchase_timeframe]}"        if attrs[:purchase_timeframe].present?
          lines << "Notes: #{attrs[:notes]}"                         if attrs[:notes].present?

          raw = params[:raw]
          raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
          if raw.is_a?(Hash)
            skip = %w[full_name email phone].to_set | skipped
            raw.each do |k, v|
              next if v.blank? || skip.include?(k.to_s.downcase)
              lines << "#{k}: #{v}"
            end
          end

          lines.join("\n")
        rescue => e
          Rails.logger.error "[Partner::Leads] inbound_inquiry_summary failed: #{e.message}"
          nil
        end

        # Owner-facing notification for a repeat inquiry: in-app toast/bell via
        # a LeadActivity + email, matching the intake :existing_lead path. Falls
        # back to the key's assigned user when the lead has no owner.
        #
        # `inbound_name` is who the payload said was inquiring. It matters when
        # it differs from the matched record: dedupe matches on email/phone, so
        # a shared household number folds Tia May's inquiry into Bob Smith's
        # lead and every notification then said "Bob Smith". The person who
        # actually filled out the form appeared nowhere the dealer could see or
        # search — which reads as the lead vanishing.
        def notify_repeat_inquiry(record, config, inbound_name: nil, match_type: :lead, attrs: {})
          notify_user = repeat_inquiry_recipient(record, config, attrs)
          return unless notify_user

          source_label = current_api_key&.name || 'API'
          name = repeat_inquiry_display_name(matched_record_name(record, match_type), inbound_name)
          noun = match_type.to_s.capitalize

          # Creating the activity IS the send. Lead/Contact/AccountActivity all
          # share an after_create :schedule_reminders that fires for
          # activity_type 'reminder' with a reminder_time, and because that time
          # is now (delay <= 60) it calls ActivityReminderService.send_reminder
          # immediately. Calling the service again here delivered every repeat
          # inquiry twice: two bell notifications AND two Twilio SMS to the
          # owner, one duplicated charge per inbound lead.
          activity_class, foreign_key = REPEAT_INQUIRY_ACTIVITY.fetch(match_type)
          activity_class.create!(
            foreign_key => record.id,
            user_id: notify_user.id,
            assigned_to_id: notify_user.id,
            activity_type: 'reminder',
            subject: "Repeat Inquiry on Existing #{noun}: #{name}",
            description: "Existing #{match_type} re-engaged via #{source_label}. " \
                         "Contact: #{record.try(:email) || record.try(:phone) || 'N/A'}",
            priority: 'high',
            status: 'pending',
            reminder_time: Time.current,
            reminder_sent: false
          )

          send_repeat_inquiry_email(record, notify_user, source_label,
                                    inbound_name: inbound_name, match_type: match_type)
        rescue => e
          Rails.logger.error "[Partner::Leads] notify_repeat_inquiry failed for #{match_type} #{record.id}: #{e.class} - #{e.message}"
        end

        # Who hears about a repeat inquiry, first match wins:
        #
        #   1. The matched record's owner — the person who holds the relationship.
        #   2. The key's `assigned_user_id` — its designated inbound-lead owner.
        #   3. Whoever the key's assignment config would hand a NEW lead to. For
        #      a round-robin key that means taking the next person on the list
        #      and advancing the cursor, exactly as a new lead would; for a
        #      per-location key, that location's rep.
        #   4. The lead intake form's notified user — the dealer already told us
        #      who watches inbound leads there, so it's the right last resort.
        #
        # Without 3 and 4 an ownerless record on a round-robin key notified
        # nobody at all: the note got written and no human was told it arrived.
        def repeat_inquiry_recipient(record, config, attrs)
          candidate_ids = [record.try(:owner_id), config['assigned_user_id']]

          # Probe the key's assignment config with the resolved location, the
          # same input a new lead would carry. Round-robin consumes a turn here
          # — deliberate: this inquiry IS work being handed to that rep.
          probe = { location_id: attrs[:location_id] }
          apply_owner_config!(probe, config)
          candidate_ids << probe[:owner_id]

          candidate_ids << intake_form_notified_user_id(attrs)

          candidate_ids.compact.each do |id|
            user = User.find_by(id: id, company_id: @current_company.id, status: 'active')
            return user if user
          end
          nil
        end

        # The intake form whose notified user should hear about inbound leads we
        # couldn't route any other way. A company can run several forms, so
        # prefer the one bound to this inquiry's location, then the one bound to
        # its source, then the most recently touched — deterministic in every
        # case, and identical to what the dealer sees on the form itself.
        def intake_form_notified_user_id(attrs)
          forms = IntakeForm.where(company_id: @current_company.id, is_active: true)
                            .where.not(notified_user_id: nil)
                            .order(updated_at: :desc)
                            .limit(25)
                            .to_a
          return nil if forms.empty?

          form = forms.find { |f| attrs[:location_id].present? && f.location_id == attrs[:location_id].to_i } ||
                 forms.find { |f| attrs[:source_id].present? && f.source_id == attrs[:source_id].to_i } ||
                 forms.first

          Rails.logger.info "[Partner::Leads] Repeat-inquiry notify falling back to intake form " \
                            "#{form.id} ('#{form.name}') notified_user #{form.notified_user_id}"
          form.notified_user_id
        rescue => e
          Rails.logger.error "[Partner::Leads] intake_form_notified_user_id failed: #{e.class} - #{e.message}"
          nil
        end

        # Activity model + its foreign key, per match type. All three implement
        # the same reminder-on-create contract.
        REPEAT_INQUIRY_ACTIVITY = {
          lead: [LeadActivity, :lead_id],
          contact: [ContactActivity, :contact_id],
          account: [AccountActivity, :account_id]
        }.freeze

        # Accounts carry a single `name`; people carry first + last.
        def matched_record_name(record, match_type)
          return record.try(:name).to_s.strip if match_type == :account

          [record.try(:first_name), record.try(:last_name)].compact.join(' ').strip
        end

        # "Tia May (matched to existing record: Bob Smith)" when the inbound name
        # is someone else, otherwise just the one name. Compared case- and
        # whitespace-insensitively so "tia  may" doesn't read as a new person.
        def repeat_inquiry_display_name(record_name, inbound_name)
          inbound = inbound_name.to_s.strip
          return record_name if inbound.blank?

          normalize = ->(s) { s.to_s.downcase.gsub(/\s+/, ' ').strip }
          return record_name if normalize.call(inbound) == normalize.call(record_name)
          return inbound if record_name.blank?

          "#{inbound} (matched to existing record: #{record_name})"
        end

        def send_repeat_inquiry_email(record, user, source_label, inbound_name: nil, match_type: :lead)
          return unless user.email.present?

          frontend_url = ENV['FRONTEND_URL'] || 'https://staging.crm.landlordinsight.com'
          name = repeat_inquiry_display_name(matched_record_name(record, match_type), inbound_name)
          noun = match_type.to_s
          path = REPEAT_INQUIRY_PATH.fetch(match_type)
          # An account match leaves the account's own fields untouched, so don't
          # tell the owner we filled anything in.
          filled_in = match_type == :account ? '' : 'We filled in any missing details and '
          body = <<~HTML
            <h2>Repeat Inquiry on Existing #{noun.capitalize}</h2>
            <p>An <strong>existing #{noun}</strong> re-engaged via <strong>#{source_label}</strong>.
            #{filled_in}logged the new inquiry as a note — no duplicate lead was created.</p>

            <h3>Contact Information</h3>
            <p>
              <strong>Name:</strong> #{name.presence || 'Not provided'}<br>
              <strong>Email:</strong> #{record.try(:email) || 'Not provided'}<br>
              <strong>Phone:</strong> #{record.try(:phone) || 'Not provided'}
            </p>

            <p><a href="#{frontend_url}#{path}/#{record.id}" style="background-color: #3b82f6; color: white; padding: 12px 24px; text-decoration: none; border-radius: 5px; display: inline-block;">View #{noun.capitalize} in CRM</a></p>

            <hr>
            <p style="color: #6b7280; font-size: 12px;">#{@current_company&.name} - Automated Lead Notification</p>
          HTML

          CommunicationService.send_email(
            communicable: record,
            to: user.email,
            subject: "Repeat Inquiry: #{name.presence || record.try(:email) || record.try(:phone)} - #{source_label}",
            body: body,
            category: 'system',
            content_type: 'text/html',
            skip_preference_check: true,
            metadata: {
              source: 'partner_api',
              api_key_name: source_label,
              existing_lead_update: true,
              matched_record_type: match_type.to_s
            }
          )
          Rails.logger.info "[Partner::Leads] Sent repeat-inquiry email to #{user.email} for #{match_type} #{record.id}"
        rescue => e
          Rails.logger.error "[Partner::Leads] send_repeat_inquiry_email failed for #{match_type} #{record.id}: #{e.class} - #{e.message}"
        end

        # Frontend detail-page paths, matching GlobalSearch's urlMap.
        REPEAT_INQUIRY_PATH = {
          lead: '/crm/leads',
          contact: '/contacts',
          account: '/accounts'
        }.freeze

        # Blank-only fill list for repeat inquiries — never overwrites existing data.
        FILLABLE_FROM_INQUIRY = %i[
          first_name last_name email phone
          budget_range purchase_timeframe rv_experience
          preferred_contact_method interests_requirements
        ].freeze

        # Contacts share the person fields but not the lead qualification ones
        # (rv_experience, purchase_timeframe and friends aren't contact columns).
        CONTACT_FILLABLE_FROM_INQUIRY = %i[
          first_name last_name email phone budget_range
        ].freeze

        def lead_json(lead, detailed: false)
          json = {
            id: lead.id,
            first_name: lead.first_name,
            last_name: lead.last_name,
            email: lead.email,
            phone: lead.phone,
            status: lead.status,
            source_id: lead.source_id,
            owner_id: lead.owner_id,
            location_id: lead.location_id,
            is_converted: lead.is_converted,
            created_at: lead.created_at&.iso8601,
            updated_at: lead.updated_at&.iso8601
          }

          if detailed
            json.merge!(
              converted_at: lead.converted_at&.iso8601,
              converted_account_id: lead.converted_account_id,
              budget_range: lead.budget_range,
              purchase_timeframe: lead.purchase_timeframe,
              rv_experience: lead.rv_experience,
              preferred_contact_method: lead.preferred_contact_method,
              interests_requirements: lead.interests_requirements,
              notes: lead.notes
            )
          end

          json
        end
      end
    end
  end
end

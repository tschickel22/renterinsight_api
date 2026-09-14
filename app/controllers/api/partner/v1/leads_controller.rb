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
        # re-engaged. The work lives in InboundInquiryAbsorber, shared with the
        # direct Facebook Lead Ads path; what belongs to an API key is who else
        # may hear about it (see #repeat_inquiry_key_recipients).
        def absorb_inquiry_into_match!(match, attrs, config, cf_values: {}, cf_consumed: [])
          InboundInquiryAbsorber.new(
            company: @current_company,
            source_label: inbound_source_label,
            raw_answers: raw_inbound_answers,
            recipient_candidates: ->(inquiry) { repeat_inquiry_key_recipients(inquiry, config) },
            origin: 'partner_api'
          ).call(match, attrs, cf_values: cf_values, cf_consumed: cf_consumed)
        end

        # After the matched record's owner, and before the intake form's watcher:
        #
        #   1. The key's `assigned_user_id`, its designated inbound-lead owner.
        #   2. Whoever the key's assignment config would hand a NEW lead to. For
        #      a round-robin key that takes the next person on the list and
        #      advances the cursor, exactly as a new lead would (deliberate: this
        #      inquiry IS work being handed to that rep); for a per-location key,
        #      that location's rep.
        #
        # Without these an ownerless record on a round-robin key notified nobody:
        # the note got written and no human was told it arrived.
        def repeat_inquiry_key_recipients(attrs, config)
          probe = { location_id: attrs[:location_id] }
          apply_owner_config!(probe, config)
          [config['assigned_user_id'], probe[:owner_id]]
        end

        def raw_inbound_answers
          raw = params[:raw]
          raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
          raw.is_a?(Hash) ? raw : {}
        end

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

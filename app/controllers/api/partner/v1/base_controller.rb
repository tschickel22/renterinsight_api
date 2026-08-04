# frozen_string_literal: true

module Api
  module Partner
    module V1
      class BaseController < ActionController::API
        include ApiKeyAuthentication

        rescue_from ActiveRecord::RecordNotFound do |e|
          render json: { error: "Resource not found" }, status: :not_found
        end

        rescue_from ActiveRecord::RecordInvalid do |e|
          render json: { error: e.message, details: e.record&.errors&.full_messages }, status: :unprocessable_entity
        end

        rescue_from ActionController::ParameterMissing do |e|
          render json: { error: "Missing parameter: #{e.param}" }, status: :bad_request
        end

        # Request plumbing, FB ad metadata, and contact aliases we consume
        # elsewhere — never surfaced as "unmapped" content.
        INBOUND_NOISE_KEYS = %w[
          controller action format id raw lead deal account contact
          ad_id ad_name adset_id adset_name campaign_id campaign_name
          form_id form_name page_id page_name platform created_time
          custom_disclaimer_responses partner_name retailer_item_id vehicle
          full_name fullname first_name last_name email email_address
          phone phone_number
        ].freeze

        private

        # Company-scoped queries - all partner API data is scoped to the API key's company
        def company_scope(model)
          model.where(company_id: current_company_id)
        end

        # Match inbound params to the company's CUSTOM fields for `module_name`
        # (leads/deals/accounts) so a caller can map straight onto a dealer-defined
        # field via its field_key. Returns [values_by_field_key, consumed_keys].
        # Only values that pass the field definition's own validation are applied;
        # anything invalid or unmatched falls through to the notes safety net, so
        # data is never lost. Matching is case-insensitive on field_key.
        def extract_inbound_custom_fields(module_name)
          values = {}
          consumed = []
          return [values, consumed] unless current_company

          param_by_downcase = params.keys.index_by { |k| k.to_s.downcase }

          current_company.custom_fields.active.for_module(module_name).each do |field|
            pk = param_by_downcase[field.field_key.to_s.downcase]
            next unless pk
            raw = params[pk]
            next if raw.nil? || raw == '' || raw.is_a?(ActionController::Parameters) || raw.is_a?(Array)
            errs = (field.validate_value(raw) rescue [])
            next if errs.present?
            values[field.field_key] = raw
            consumed << pk.to_s
          end

          [values, consumed]
        rescue StandardError => e
          Rails.logger.warn "[Partner::BaseController] extract_inbound_custom_fields failed: #{e.class}: #{e.message}"
          [{}, []]
        end

        # A notes-friendly summary of inbound fields that didn't map to a
        # permitted attribute, so nothing a caller (Zapier/FB) sends is silently
        # dropped. `mapped_keys` are the attribute keys the caller DID map.
        # Returns nil when there's nothing unmapped worth recording.
        def unmapped_inbound_note(mapped_keys)
          lines = unmapped_inbound_lines(mapped_keys)
          return nil if lines.empty?

          stamp = Time.current.strftime('%Y-%m-%d %H:%M %Z')
          "[#{stamp}] Additional fields via #{inbound_source_label}\n#{lines.join("\n")}"
        end

        # Merge the unmapped-field note into an attributes hash's notes before save
        # (so it's part of the create, not a follow-up write). Handles symbol- or
        # string-keyed hashes.
        def merge_inbound_note(attrs, mapped_keys)
          note = unmapped_inbound_note(mapped_keys)
          return attrs if note.blank?

          existing = attrs[:notes] || attrs['notes']
          combined = [existing.presence, note].compact.join("\n\n")
          key = attrs.key?('notes') ? 'notes' : :notes
          attrs.merge(key => combined)
        end

        # Write the inbound summary to the polymorphic `notes` table as well as
        # the entity's `notes` text column.
        #
        # These are two unrelated stores. The CRM's Notes tab reads ONLY the
        # `notes` table (GET /v1/notes?entity_type=lead&entity_id=...), while
        # merge_inbound_note above appends to the entity's text column. Until
        # this existed, everything a Zap sent (e.g. Facebook lead-ad qualifying
        # questions) was captured but invisible in the UI — the column held it,
        # the tab looked empty. The intake-form path already did this correctly
        # via IntakeSubmission's Note.create! calls; this brings the partner API
        # in line.
        #
        # Best-effort: a note failure must never fail an otherwise good create.
        def write_inbound_note!(entity_type, entity_id, content)
          return nil if content.blank? || entity_id.blank?

          Note.create!(
            entity_type: entity_type,
            entity_id: entity_id.to_s,
            content: content,
            created_by_name: "System (#{inbound_source_label})"
          )
        rescue StandardError => e
          Rails.logger.error "[Partner::BaseController] write_inbound_note! failed for #{entity_type} #{entity_id}: #{e.class}: #{e.message}"
          nil
        end

        # Note-table body for a newly created record: no timestamp prefix (the
        # Note row carries its own created_at) and a header that reads clearly
        # in the CRM's Notes tab.
        def inbound_note_content(mapped_keys)
          lines = unmapped_inbound_lines(mapped_keys)
          return nil if lines.empty?

          "📥 ADDITIONAL FIELDS via #{inbound_source_label}\n\n#{lines.join("\n")}"
        end

        def inbound_source_label
          (respond_to?(:current_api_key, true) && current_api_key&.name).presence || 'API'
        end

        def unmapped_inbound_lines(mapped_keys)
          skip = (INBOUND_NOISE_KEYS + Array(mapped_keys).map { |k| k.to_s.downcase }).to_set
          seen = Set.new
          lines = []

          sources = []
          raw = params[:raw]
          raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
          sources << raw if raw.is_a?(Hash)
          sources << params.to_unsafe_h

          sources.each do |src|
            src.each do |k, v|
              key = k.to_s
              dk  = key.downcase
              next if skip.include?(dk) || seen.include?(dk)
              next if v.nil? || v == '' || v.is_a?(Hash) || v.is_a?(Array)
              seen << dk
              lines << "#{key.tr('_', ' ')}: #{v}"
            end
          end
          lines
        rescue StandardError => e
          Rails.logger.warn "[Partner::BaseController] unmapped_inbound_lines failed: #{e.class}: #{e.message}"
          []
        end
      end
    end
  end
end

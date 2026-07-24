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

        # A notes-friendly summary of inbound fields that didn't map to a
        # permitted attribute, so nothing a caller (Zapier/FB) sends is silently
        # dropped. `mapped_keys` are the attribute keys the caller DID map.
        # Returns nil when there's nothing unmapped worth recording.
        def unmapped_inbound_note(mapped_keys)
          lines = unmapped_inbound_lines(mapped_keys)
          return nil if lines.empty?

          stamp  = Time.current.strftime('%Y-%m-%d %H:%M %Z')
          source = (respond_to?(:current_api_key, true) && current_api_key&.name) || 'API'
          "[#{stamp}] Additional fields via #{source}\n#{lines.join("\n")}"
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

# frozen_string_literal: true

# Public endpoint for one-click Accept/Decline of a Champion lead from email.
#
# The Champion lead notification email contains tokenized links:
#   GET  /cl/:token/accept   — accept the lead via Champion's API
#   GET  /cl/:token/decline  — return lead summary to populate the decline form
#   POST /cl/:token/decline  — decline the lead via Champion's API
#
# Status codes the frontend (ChampionLeadAction.tsx) relies on:
#   200 — success
#   404 — token not found / lead doesn't exist
#   410 — token expired
#   409 — lead already accepted or declined (token consumed)
module Public
  class ChampionLeadActionsController < ApplicationController
    skip_before_action :authenticate, raise: false
    skip_before_action :set_company_scope, raise: false
    skip_before_action :set_current_attributes, raise: false

    before_action :find_lead

    # GET /cl/:token/accept
    def accept
      return if performed?

      config = find_config(@lead)
      return render json: { error: 'No Champion feed configuration found for this lead.' }, status: :not_found unless config

      client = ChampionLeadsApiClient.new(config)
      result = client.accept_lead(@lead.champion_salesforce_id)

      unless result[:success]
        return render json: { error: result[:error] || 'Champion API error' }, status: :bad_gateway
      end

      @lead.update!(
        champion_status:                  'active',
        champion_accepted_at:             Time.current,
        status:                           promote_status(@lead.status),
        champion_action_token:            nil,
        champion_action_token_expires_at: nil
      )

      # Trigger immediate re-sync to pull contact info revealed by accept
      ChampionLeadSyncJob.perform_later(config.id) if defined?(ChampionLeadSyncJob)

      render json: { message: 'Lead accepted. Contact info will appear within 15 minutes.',
                     lead: public_lead_json(@lead.reload) }
    end

    # GET /cl/:token/decline
    # Returns lead summary so the decline form can show what's being declined.
    def decline_form
      return if performed?

      render json: { lead: public_lead_json(@lead) }
    end

    # POST /cl/:token/decline
    def decline
      return if performed?

      config = find_config(@lead)
      return render json: { error: 'No Champion feed configuration found for this lead.' }, status: :not_found unless config

      reason  = params[:reason].presence
      comment = params[:comment].presence
      full_reason = [reason, comment].compact.reject(&:blank?).join(' — ').presence

      client = ChampionLeadsApiClient.new(config)
      result = client.decline_lead(@lead.champion_salesforce_id, reason: full_reason)

      unless result[:success]
        return render json: { error: result[:error] || 'Champion API error' }, status: :bad_gateway
      end

      @lead.update!(
        champion_status:                  'declined',
        champion_declined_at:             Time.current,
        status:                           'lost',
        lost_reason:                      full_reason.present? ? "Champion: #{full_reason}" : 'Declined via Champion',
        champion_action_token:            nil,
        champion_action_token_expires_at: nil
      )

      render json: { message: 'Lead declined and sent back to Champion.',
                     lead: public_lead_json(@lead.reload) }
    end

    private

    def find_lead
      token = params[:token].to_s
      @lead = Lead.find_by(champion_action_token: token) if token.present?

      return render json: { error: 'This link is invalid.' }, status: :not_found if @lead.nil?

      if @lead.champion_action_token_expires_at.present? && @lead.champion_action_token_expires_at < Time.current
        return render json: { error: 'This link has expired.' }, status: :gone
      end

      if already_actioned?(@lead)
        render json: { error: 'This lead has already been actioned.',
                       already_actioned: true,
                       lead: public_lead_json(@lead) }, status: :conflict
      end
    end

    def already_actioned?(lead)
      lead.champion_accepted_at.present? || lead.champion_declined_at.present?
    end

    # Don't demote leads further along in the pipeline
    def promote_status(current)
      %w[qualified proposal won converted].include?(current) ? current : 'contacted'
    end

    # Find the right Champion feed config for this lead.
    # Priority: location-specific → company-wide → config saved on the lead.
    def find_config(lead)
      company_id = lead.company_id

      config = nil
      if lead.location_id.present?
        config = ChampionLeadFeedConfig.active.find_by(company_id: company_id, location_id: lead.location_id)
      end
      config ||= ChampionLeadFeedConfig.active.find_by(company_id: company_id, location_id: nil)
      if config.nil? && lead.champion_config_id.present?
        config = ChampionLeadFeedConfig.active.find_by(company_id: company_id, id: lead.champion_config_id)
      end
      config
    end

    # Public-safe lead shape — only customer-facing context, no internal IDs
    # beyond the lead id itself, no foreign keys, no full champion_lead_data blob.
    def public_lead_json(lead)
      data       = lead.champion_lead_data || {}
      build      = data['buildDetails'] || {}
      additional = data['additionalDetails'] || {}
      contact    = data['leadContactInfo'] || {}

      {
        lead_id:        lead.id,
        customer_name:  "#{lead.first_name} #{lead.last_name}".strip,
        customer_email: lead.email,
        customer_phone: lead.phone,
        model_name:     build['modelName'],
        manufacturer:   build['manufacturer'],
        timing:         additional['timing'],
        home_placement: additional['homePlacement'],
        financing:      additional['hasFinancing'],
        customer_comment: additional.dig('customerComment', 'text'),
        status:         lead.champion_status,
        source:         'Champion Homes — Retailer API',
        submitted_at:   contact['createdDateTime'] || lead.created_at&.iso8601,
        dealer_name:    lead.company&.name,
        company_name:   lead.company&.name
      }
    end
  end
end

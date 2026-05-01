# frozen_string_literal: true

# Accept, decline, and refresh individual Champion leads.
#
# These actions proxy through to Champion's Retailer API and update the
# local CRM lead record to match.
#
# Routes: /api/v1/champion-leads/actions/:id/{accept,decline,refresh}
class Api::V1::ChampionLeads::ActionsController < ApplicationController
  before_action :set_company_scope
  before_action :set_lead

  # POST /api/v1/champion-leads/actions/:id/accept
  #
  # Accepts the lead on Champion's side, which reveals the prospect's
  # contact information (email, phone). The next sync will pull those in,
  # but we also trigger an immediate re-sync for faster turnaround.
  def accept
    return unless authorize_action!('leads', 'update')

    config = find_config
    return render json: { error: 'No Champion feed configuration found' }, status: :not_found unless config

    client = ChampionLeadsApiClient.new(config)
    result = client.accept_lead(@lead.champion_salesforce_id)

    if result[:success]
      @lead.update!(
        champion_status:      'active',
        champion_accepted_at: Time.current,
        status:               promote_status(@lead.status)
      )

      # Trigger immediate re-sync to pull contact info
      ChampionLeadSyncJob.perform_later(config.id)

      render json: {
        success: true,
        message: 'Lead accepted. Contact info will appear within 15 minutes.',
        lead: lead_json(@lead.reload)
      }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/champion-leads/actions/:id/decline
  #
  # Declines the lead on Champion's side with an optional reason.
  # The lead moves to "lost" status in the CRM.
  def decline
    return unless authorize_action!('leads', 'update')

    config = find_config
    return render json: { error: 'No Champion feed configuration found' }, status: :not_found unless config

    reason = params[:reason].presence || params[:decline_reason].presence
    client = ChampionLeadsApiClient.new(config)
    result = client.decline_lead(@lead.champion_salesforce_id, reason: reason)

    if result[:success]
      @lead.update!(
        champion_status:      'declined',
        champion_declined_at: Time.current,
        status:               'lost',
        lost_reason:          reason.present? ? "Champion: #{reason}" : 'Declined via Champion'
      )

      render json: {
        success: true,
        message: 'Lead declined and sent back to Champion.',
        lead: lead_json(@lead.reload)
      }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/champion-leads/actions/:id/refresh
  #
  # Pulls the latest data for this specific lead from Champion and
  # updates the local record. Useful for checking if contact info
  # has been populated after accepting.
  def refresh
    return unless authorize_action!('leads', 'read')

    config = find_config
    return render json: { error: 'No Champion feed configuration found' }, status: :not_found unless config

    client = ChampionLeadsApiClient.new(config)
    result = client.get_lead(@lead.champion_salesforce_id)

    if result[:success]
      champion_data = result[:data]
      contact = champion_data['leadContactInfo'] || {}

      attrs = { champion_lead_data: champion_data, champion_status: champion_data['status'] }
      attrs[:email] = contact['email'] if contact['email'].present? && @lead.email.blank?
      attrs[:phone] = contact['phone'] if contact['phone'].present? && @lead.phone.blank?

      @lead.update!(attrs)

      render json: {
        success: true,
        lead: lead_json(@lead.reload),
        championData: champion_data
      }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end

  private

  def set_lead
    @lead = @company.leads.find(params[:id])

    unless @lead.champion_salesforce_id.present?
      render json: { error: 'This lead is not from Champion' }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Lead not found' }, status: :not_found
  end

  # Find the right config for this lead — try location-specific first, then company-wide
  def find_config
    if @lead.location_id
      config = ChampionLeadFeedConfig.active.find_by(
        company_id: @company.id,
        location_id: @lead.location_id
      )
    end
    config || ChampionLeadFeedConfig.active.find_by(
      company_id: @company.id,
      location_id: nil
    ) || ChampionLeadFeedConfig.active.find_by(
      company_id: @company.id,
      champion_config_id: @lead.champion_config_id
    )
  end

  # Don't demote leads that are further in the pipeline
  def promote_status(current)
    advanced = %w[qualified proposal won converted]
    advanced.include?(current) ? current : 'contacted'
  end

  def lead_json(lead)
    {
      id: lead.id,
      firstName: lead.first_name,
      lastName: lead.last_name,
      email: lead.email,
      phone: lead.phone,
      status: lead.status,
      championStatus: lead.champion_status,
      championSalesforceId: lead.champion_salesforce_id,
      championAcceptedAt: lead.champion_accepted_at,
      championDeclinedAt: lead.champion_declined_at,
      championLeadData: lead.champion_lead_data
    }
  end
end

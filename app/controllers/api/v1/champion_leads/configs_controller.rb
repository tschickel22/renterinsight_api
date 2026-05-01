# frozen_string_literal: true

# CRUD for Champion Lead Feed configurations — manages API tokens
# and sync settings per company/location.
#
# Routes: /api/v1/champion-leads/configs
class Api::V1::ChampionLeads::ConfigsController < ApplicationController
  before_action :set_company_scope
  before_action :set_config, only: %i[show update destroy test_connection sync_now]

  # GET /api/v1/champion-leads/configs
  def index
    return unless authorize_action!('leads', 'read')

    configs = @company.champion_lead_feed_configs
                      .includes(:location)
                      .order(:created_at)

    render json: configs.map { |c| config_json(c) }
  end

  # GET /api/v1/champion-leads/configs/:id
  def show
    return unless authorize_action!('leads', 'read')

    render json: config_json(@config)
  end

  # POST /api/v1/champion-leads/configs
  def create
    return unless authorize_action!('leads', 'update')

    config = @company.champion_lead_feed_configs.build(config_params)

    if config.save
      render json: config_json(config), status: :created
    else
      render json: { errors: config.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /api/v1/champion-leads/configs/:id
  def update
    return unless authorize_action!('leads', 'update')

    if @config.update(config_params)
      render json: config_json(@config)
    else
      render json: { errors: @config.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/champion-leads/configs/:id
  def destroy
    return unless authorize_action!('leads', 'update')

    @config.destroy!
    head :no_content
  end

  # POST /api/v1/champion-leads/configs/:id/test_connection
  def test_connection
    return unless authorize_action!('leads', 'read')

    client = ChampionLeadsApiClient.new(@config)
    result = client.auth_test

    render json: {
      success: result[:success],
      message: result[:success] ? 'Connection successful' : result[:error],
      status: result[:status]
    }
  end

  # POST /api/v1/champion-leads/configs/:id/sync_now
  def sync_now
    return unless authorize_action!('leads', 'update')

    ChampionLeadSyncJob.perform_later(@config.id)

    render json: {
      success: true,
      message: 'Sync job queued. Leads will appear within a few minutes.'
    }
  end

  private

  def set_config
    @config = @company.champion_lead_feed_configs.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Configuration not found' }, status: :not_found
  end

  def config_params
    params.require(:config).permit(
      :api_token, :environment, :champion_account_number,
      :retailer_name, :active, :location_id, :sync_interval_minutes
    )
  end

  def config_json(config)
    {
      id: config.id,
      companyId: config.company_id,
      locationId: config.location_id,
      locationName: config.location&.name,
      environment: config.environment,
      championAccountNumber: config.champion_account_number,
      retailerName: config.retailer_name,
      active: config.active,
      syncIntervalMinutes: config.sync_interval_minutes,
      lastSyncedAt: config.last_synced_at,
      lastSyncErrorAt: config.last_sync_error_at,
      lastSyncError: config.last_sync_error,
      totalLeadsSynced: config.total_leads_synced,
      lastSyncStats: config.last_sync_stats,
      hasToken: config.api_token.present?,
      createdAt: config.created_at,
      updatedAt: config.updated_at
    }
  end
end

# frozen_string_literal: true

class Api::V1::FacebookIntegrationsController < ApplicationController
  before_action :set_company_scope
  before_action :set_integration, only: %i[show update destroy refresh_token lead_log]

  # GET /api/v1/facebook-integrations
  def index
    return unless authorize_action!('integrations', 'read')

    integrations = @company.facebook_integrations.where(is_deleted: [false, nil]).order(created_at: :desc)
    render json: integrations.map { |i| serialize(i) }
  end

  # GET /api/v1/facebook-integrations/:id
  def show
    return unless authorize_action!('integrations', 'read')
    render json: serialize(@integration, detailed: true)
  end

  # PATCH/PUT /api/v1/facebook-integrations/:id
  def update
    return unless authorize_action!('integrations', 'update')

    if @integration.update(permitted_params)
      render json: serialize(@integration, detailed: true)
    else
      render json: { errors: @integration.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/facebook-integrations/:id
  def destroy
    return unless authorize_action!('integrations', 'delete')

    begin
      MetaGraphApi.unsubscribe_page_from_webhooks(@integration.page_id, @integration.page_access_token) if @integration.page_access_token.present?
    rescue MetaGraphApi::Error => e
      Rails.logger.warn "[FacebookIntegrations#destroy] unsubscribe failed: #{e.message}"
    end

    @integration.update!(is_deleted: true, status: 'disconnected')
    head :no_content
  end

  # POST /api/v1/facebook-integrations/:id/refresh_token
  def refresh_token
    return unless authorize_action!('integrations', 'update')

    source_token = @integration.user_access_token.presence || @integration.page_access_token
    return render json: { error: 'No stored token to refresh' }, status: :unprocessable_entity if source_token.blank?

    begin
      resp = MetaGraphApi.exchange_token(source_token)
    rescue MetaGraphApi::Error => e
      return render json: { error: e.message }, status: :unprocessable_entity
    end

    @integration.update!(
      user_access_token: resp['access_token'],
      token_expires_at:  Time.current + resp['expires_in'].to_i.seconds,
      status:            'active'
    )

    render json: { success: true, token_expires_at: @integration.token_expires_at }
  end

  # GET /api/v1/facebook-integrations/:id/lead_log
  def lead_log
    return unless authorize_action!('integrations', 'read')

    leads = Lead.where(company_id: @company.id, utm_source: 'facebook')
                .order(created_at: :desc)
                .limit(50)

    render json: leads.map { |l|
      {
        id:         l.id,
        first_name: l.first_name,
        last_name:  l.last_name,
        email:      l.email,
        phone:      l.phone,
        status:     l.status,
        utm_campaign: l.utm_campaign,
        utm_content:  l.utm_content,
        created_at: l.created_at
      }
    }
  end

  private

  def set_integration
    @integration = @company.facebook_integrations.where(is_deleted: [false, nil]).find_by(id: params[:id])
    render json: { error: 'Not found' }, status: :not_found unless @integration
  end

  def permitted_params
    params.require(:facebook_integration).permit(
      :page_name,
      :default_source_id,
      :default_owner_id,
      :default_workflow_id,
      :location_id,
      subscribed_fields: [],
      field_mapping: {}
    )
  end

  def serialize(i, detailed: false)
    base = {
      id:                  i.id,
      page_id:             i.page_id,
      page_name:           i.page_name,
      status:              i.status,
      subscribed_fields:   i.subscribed_fields,
      field_mapping:       i.field_mapping,
      default_source_id:   i.default_source_id,
      default_owner_id:    i.default_owner_id,
      default_workflow_id: i.default_workflow_id,
      lead_count:          i.lead_count,
      last_lead_at:        i.last_lead_at,
      token_expires_at:    i.token_expires_at,
      location_id:         i.location_id,
      created_at:          i.created_at,
      updated_at:          i.updated_at
    }
    base[:metadata] = i.metadata if detailed
    base
  end
end

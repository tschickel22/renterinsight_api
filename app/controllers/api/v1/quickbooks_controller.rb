# frozen_string_literal: true

class Api::V1::QuickbooksController < ApplicationController
  before_action :set_company_scope, except: [:callback]
  skip_before_action :authenticate, only: [:callback]

  def authorize
    return unless authorize_action!('accounting', 'update')

    state = SecureRandom.hex(16)
    auth_url = Quickbooks::Client.authorization_url(state: state)
    render json: { auth_url: auth_url, state: state }
  end

  def callback
    redirect_to "/settings/company/integrations?qb_code=#{params[:code]}&qb_realm_id=#{params[:realmId]}"
  end

  def exchange_token
    return unless authorize_action!('accounting', 'update')

    tokens = Quickbooks::Client.exchange_code_for_tokens(params[:code])
    connection = QuickbooksConnection.where(company_id: @company.id).first_or_initialize
    connection.update!(
      realm_id: params[:realm_id],
      access_token: tokens['access_token'],
      refresh_token: tokens['refresh_token'],
      token_expires_at: Time.current + tokens['expires_in'].to_i.seconds,
      refresh_token_expires_at: Time.current + (tokens['x_refresh_token_expires_in'] || 8726400).to_i.seconds,
      status: QuickbooksConnection::STATUS_CONNECTED,
      error_message: nil
    )

    info = begin
      Quickbooks::Client.new(connection).company_info
    rescue StandardError
      {}
    end
    connection.update!(company_name: info.dig('CompanyInfo', 'CompanyName'))

    render json: { connected: true, company_name: connection.company_name }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def status
    return unless authorize_action!('accounting', 'read')

    connection = QuickbooksConnection.for_company(@company.id)
    if connection
      render json: {
        connected: connection.connected?,
        status: connection.status,
        company_name: connection.company_name,
        last_sync_at: connection.last_sync_at,
        sync_mode: connection.sync_mode,
        error_message: connection.error_message
      }
    else
      render json: { connected: false, status: 'disconnected' }
    end
  end

  def disconnect
    return unless authorize_action!('accounting', 'update')

    connection = QuickbooksConnection.for_company(@company.id)
    if connection
      begin
        Quickbooks::Client.revoke_token(connection.refresh_token)
      rescue StandardError
        nil
      end
      connection.update!(status: 'disconnected', access_token: nil, refresh_token: nil, realm_id: nil)
    end
    render json: { success: true }
  end

  def sync
    return unless authorize_action!('accounting', 'update')

    connection = QuickbooksConnection.for_company(@company.id)
    return render json: { error: 'Not connected' }, status: :unprocessable_entity unless connection&.connected?

    service = Quickbooks::SyncService.new(connection)
    entity = params[:entity_type]
    since = params[:since].present? ? Date.parse(params[:since]) : 30.days.ago

    result = case entity
             when 'contacts'          then service.sync_contacts
             when 'suppliers'         then service.sync_suppliers
             when 'invoices'          then service.sync_invoices(since: since)
             when 'chart_of_accounts' then service.sync_chart_of_accounts
             else
               return render json: { error: "Unknown entity: #{entity}" }, status: :bad_request
             end

    connection.update!(last_sync_at: Time.current)
    render json: { success: true, result: result }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def qb_accounts
    return unless authorize_action!('accounting', 'read')

    connection = QuickbooksConnection.for_company(@company.id)
    return render json: { error: 'Not connected' }, status: :unprocessable_entity unless connection&.connected?

    service = Quickbooks::SyncService.new(connection)
    render json: { accounts: service.fetch_qb_accounts }
  end

  def sync_logs
    return unless authorize_action!('accounting', 'read')

    logs = QuickbooksSyncLog.for_company(@company.id).recent.limit(params[:limit] || 20)
    render json: { items: logs }
  end

  def update_settings
    return unless authorize_action!('accounting', 'update')

    connection = QuickbooksConnection.for_company(@company.id)
    return render json: { error: 'Not connected' }, status: :unprocessable_entity unless connection

    connection.update!(
      params.permit(:sync_enabled, :auto_sync_enabled, :auto_sync_interval, :sync_start_date, :sync_mode)
    )
    render json: { success: true }
  end
end

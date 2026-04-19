# frozen_string_literal: true

class Api::V1::SocialAccountsController < ApplicationController
  before_action :set_company_scope
  before_action :set_account, only: %i[show update destroy refresh_token disconnect]

  def index
    return unless authorize_action!('integrations', 'read')
    accounts = @company.social_accounts.active.order(created_at: :desc)
    render json: accounts.map { |a| serialize(a) }
  end

  def show
    return unless authorize_action!('integrations', 'read')
    render json: serialize(@account)
  end

  def create
    return unless authorize_action!('integrations', 'update')

    account = @company.social_accounts.new(permitted_params)
    if account.save
      render json: serialize(account), status: :created
    else
      render json: { errors: account.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('integrations', 'update')

    if @account.update(permitted_params)
      render json: serialize(@account)
    else
      render json: { errors: @account.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('integrations', 'delete')

    @account.update!(is_deleted: true, status: 'disconnected')
    head :no_content
  end

  def refresh_token
    return unless authorize_action!('integrations', 'update')

    begin
      resp = MetaGraphApi.exchange_token(@account.access_token_encrypted)
    rescue MetaGraphApi::Error => e
      return render json: { error: e.message }, status: :unprocessable_entity
    end

    @account.update!(
      access_token_encrypted: resp['access_token'],
      token_expires_at:       Time.current + resp['expires_in'].to_i.seconds,
      status:                 'active'
    )
    render json: serialize(@account)
  end

  def disconnect
    return unless authorize_action!('integrations', 'update')

    @account.update!(status: 'disconnected')
    render json: serialize(@account)
  end

  def stats
    return unless authorize_action!('integrations', 'read')

    accounts = @company.social_accounts.active
    render json: {
      total:    accounts.count,
      by_platform: accounts.group(:platform).count,
      by_status:   @company.social_accounts.group(:status).count
    }
  end

  private

  def set_account
    @account = @company.social_accounts.find_by(id: params[:id])
    render json: { error: 'Not found' }, status: :not_found unless @account
  end

  def permitted_params
    params.require(:social_account).permit(
      :platform, :account_type, :external_id, :name, :page_url,
      :access_token_encrypted, :token_type, :token_expires_at,
      :status, :location_id, metadata: {}
    )
  end

  def serialize(a)
    {
      id: a.id, platform: a.platform, account_type: a.account_type,
      external_id: a.external_id, name: a.name, page_url: a.page_url,
      status: a.status, token_expires_at: a.token_expires_at,
      last_sync_at: a.last_sync_at, location_id: a.location_id,
      metadata: a.metadata, created_at: a.created_at, updated_at: a.updated_at
    }
  end
end

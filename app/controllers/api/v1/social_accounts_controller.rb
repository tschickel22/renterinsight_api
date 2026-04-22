# frozen_string_literal: true

class Api::V1::SocialAccountsController < ApplicationController
  before_action :set_company_scope
  before_action :set_account, only: %i[show update destroy refresh_token disconnect]

  # GET /api/v1/social-accounts
  def index
    return unless authorize_action!('integrations', 'read')

    accounts = @company.social_accounts.active.order(created_at: :desc)
    render json: accounts.map { |a| serialize(a) }
  end

  # GET /api/v1/social-accounts/:id
  def show
    return unless authorize_action!('integrations', 'read')
    render json: serialize(@account, detailed: true)
  end

  # POST /api/v1/social-accounts
  def create
    return unless authorize_action!('integrations', 'update')

    account = @company.social_accounts.new(permitted_params)
    account.status ||= 'active'

    if account.save
      render json: serialize(account, detailed: true), status: :created
    else
      render json: { errors: account.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /api/v1/social-accounts/:id
  def update
    return unless authorize_action!('integrations', 'update')

    if @account.update(permitted_params)
      render json: serialize(@account, detailed: true)
    else
      render json: { errors: @account.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/social-accounts/:id
  def destroy
    return unless authorize_action!('integrations', 'delete')

    @account.update!(is_deleted: true, status: 'disconnected')
    head :no_content
  end

  # POST /api/v1/social-accounts/:id/refresh_token
  def refresh_token
    return unless authorize_action!('integrations', 'update')

    source = @account.access_token_encrypted
    return render json: { error: 'No stored token to refresh' }, status: :unprocessable_entity if source.blank?

    begin
      resp = MetaGraphApi.exchange_token(source)
    rescue MetaGraphApi::Error => e
      return render json: { error: e.message }, status: :unprocessable_entity
    end

    @account.update!(
      access_token_encrypted: resp['access_token'],
      token_expires_at:       Time.current + resp['expires_in'].to_i.seconds,
      status:                 'active'
    )
    render json: serialize(@account, detailed: true)
  end

  # POST /api/v1/social-accounts/:id/disconnect
  def disconnect
    return unless authorize_action!('integrations', 'update')

    @account.update!(status: 'disconnected')
    render json: serialize(@account, detailed: true)
  end

  # GET /api/v1/social-accounts/stats
  def stats
    return unless authorize_action!('integrations', 'read')

    scope = @company.social_accounts
    render json: {
      total:       scope.where(is_deleted: [false, nil]).count,
      active:      scope.where(status: 'active',   is_deleted: [false, nil]).count,
      expired:     scope.where(status: 'expired',  is_deleted: [false, nil]).count,
      disconnected: scope.where(status: 'disconnected').count,
      by_platform: scope.where(is_deleted: [false, nil]).group(:platform).count,
      by_status:   scope.where(is_deleted: [false, nil]).group(:status).count
    }
  end

  private

  def set_account
    @account = @company.social_accounts.where(is_deleted: [false, nil]).find_by(id: params[:id])
    render json: { error: 'Not found' }, status: :not_found unless @account
  end

  def permitted_params
    params.require(:social_account).permit(
      :platform, :account_type, :external_id, :name, :page_url,
      :access_token_encrypted, :token_type, :token_expires_at,
      :status, :location_id, metadata: {}
    )
  end

  def serialize(a, detailed: false)
    base = {
      id:               a.id,
      platform:         a.platform,
      account_type:     a.account_type,
      external_id:      a.external_id,
      name:             a.name,
      page_url:         a.page_url,
      status:           a.status,
      token_expires_at: a.token_expires_at,
      last_sync_at:     a.last_sync_at,
      location_id:      a.location_id,
      created_at:       a.created_at,
      updated_at:       a.updated_at
    }

    if detailed
      base[:metadata]   = a.metadata
      base[:post_count] = @company.social_posts.where(social_account_id: a.id, is_deleted: [false, nil]).count
    end

    base
  end
end

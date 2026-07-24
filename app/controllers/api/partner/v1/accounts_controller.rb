# frozen_string_literal: true

module Api
  module Partner
    module V1
      class AccountsController < BaseController
        include PartnerWebhooks
        fires_webhooks resource: :account

        before_action :authorize_accounts
        before_action :set_account, only: [:show, :update, :destroy]

        # GET /api/partner/v1/accounts
        def index
          accounts = company_scope(Account).where(is_deleted: false)

          # Filters
          accounts = accounts.where(status: params[:status]) if params[:status].present?
          accounts = accounts.where(account_type: params[:account_type]) if params[:account_type].present?
          accounts = accounts.where(rating: params[:rating]) if params[:rating].present?
          accounts = accounts.where(owner_id: params[:owner_id]) if params[:owner_id].present?
          accounts = accounts.where(location_id: params[:location_id]) if params[:location_id].present?
          accounts = accounts.where(industry: params[:industry]) if params[:industry].present?

          # Search
          if params[:q].present?
            q = "%#{params[:q]}%"
            accounts = accounts.where("name ILIKE :q OR email ILIKE :q", q: q)
          end

          # Cursor-based pagination
          accounts = accounts.order(:id)
          accounts = accounts.where("id > ?", params[:after].to_i) if params[:after].present?
          limit = [params.fetch(:limit, 50).to_i, 200].min
          accounts = accounts.limit(limit + 1)

          records = accounts.to_a
          has_more = records.size > limit
          records = records.first(limit)

          render json: {
            data: records.map { |a| account_json(a) },
            meta: {
              has_more: has_more,
              next_cursor: has_more ? records.last&.id&.to_s : nil,
              limit: limit
            }
          }
        end

        # GET /api/partner/v1/accounts/:id
        def show
          render json: { data: account_json(@account, detailed: true) }
        end

        # POST /api/partner/v1/accounts
        def create
          attrs = account_params.to_h
          cf_values, cf_consumed = extract_inbound_custom_fields('accounts')
          attrs['custom_field_values'] = (attrs['custom_field_values'] || {}).merge(cf_values) if cf_values.any?
          # Safety net: unmapped inbound fields go to notes instead of being dropped.
          attrs = merge_inbound_note(attrs, attrs.keys + cf_consumed)
          account = company_scope(Account).new(attrs)

          if account.save
            render json: { data: account_json(account, detailed: true) }, status: :created
          else
            render json: { error: "Validation failed", details: account.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/partner/v1/accounts/:id
        def update
          if @account.update(account_params)
            render json: { data: account_json(@account, detailed: true) }
          else
            render json: { error: "Validation failed", details: @account.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/partner/v1/accounts/:id
        def destroy
          @account.update!(is_deleted: true, deleted_at: Time.current)
          render json: { data: { id: @account.id, deleted: true } }
        end

        private

        def authorize_accounts
          case action_name
          when "index", "show"
            authorize_permission!(:accounts, :read)
          when "create"
            authorize_permission!(:accounts, :create)
          when "update"
            authorize_permission!(:accounts, :update)
          when "destroy"
            authorize_permission!(:accounts, :delete)
          end
        end

        def set_account
          @account = company_scope(Account).where(is_deleted: false).find(params[:id])
        end

        def account_params
          params.permit(
            :name, :status, :account_type, :email, :phone, :website,
            :industry, :rating, :ownership, :annual_revenue, :employee_count,
            :description, :notes, :account_number,
            :billing_street, :billing_city, :billing_state, :billing_postal_code, :billing_country,
            :shipping_street, :shipping_city, :shipping_state, :shipping_postal_code, :shipping_country,
            :owner_id, :location_id, :source_id, :parent_account_id
          )
        end

        def account_json(account, detailed: false)
          json = {
            id: account.id,
            name: account.name,
            status: account.status,
            account_type: account.account_type,
            email: account.email,
            phone: account.phone,
            industry: account.industry,
            rating: account.rating,
            owner_id: account.owner_id,
            location_id: account.location_id,
            created_at: account.created_at&.iso8601,
            updated_at: account.updated_at&.iso8601
          }

          if detailed
            json.merge!(
              website: account.website,
              ownership: account.ownership,
              annual_revenue: account.annual_revenue,
              employee_count: account.employee_count,
              description: account.description,
              notes: account.notes,
              account_number: account.account_number,
              source_id: account.source_id,
              parent_account_id: account.parent_account_id,
              billing_street: account.billing_street,
              billing_city: account.billing_city,
              billing_state: account.billing_state,
              billing_postal_code: account.billing_postal_code,
              billing_country: account.billing_country,
              shipping_street: account.shipping_street,
              shipping_city: account.shipping_city,
              shipping_state: account.shipping_state,
              shipping_postal_code: account.shipping_postal_code,
              shipping_country: account.shipping_country,
              last_activity_date: account.last_activity_date&.iso8601,
              converted_date: account.converted_date&.iso8601
            )
          end

          json
        end
      end
    end
  end
end

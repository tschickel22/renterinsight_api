# frozen_string_literal: true

module Api
  module Partner
    module V1
      class DealsController < BaseController
        include PartnerWebhooks
        fires_webhooks resource: :deal

        before_action :authorize_deals
        before_action :set_deal, only: [:show, :update, :destroy]

        # GET /api/partner/v1/deals
        def index
          deals = company_scope(Deal).where(deleted_at: nil)

          # Filters
          deals = deals.where(stage: params[:stage]) if params[:stage].present?
          deals = deals.where(owner_id: params[:owner_id]) if params[:owner_id].present?
          deals = deals.where(account_id: params[:account_id]) if params[:account_id].present?
          deals = deals.where(contact_id: params[:contact_id]) if params[:contact_id].present?
          deals = deals.where(vehicle_id: params[:vehicle_id]) if params[:vehicle_id].present?
          deals = deals.where(location_id: params[:location_id]) if params[:location_id].present?
          deals = deals.where(deal_type: params[:deal_type]) if params[:deal_type].present?

          # Search
          if params[:q].present?
            q = "%#{params[:q]}%"
            deals = deals.where("name ILIKE :q OR customer_name ILIKE :q", q: q)
          end

          # Cursor-based pagination
          deals = deals.order(:id)
          deals = deals.where("id > ?", params[:after].to_i) if params[:after].present?
          limit = [params.fetch(:limit, 50).to_i, 200].min
          deals = deals.limit(limit + 1)

          records = deals.to_a
          has_more = records.size > limit
          records = records.first(limit)

          render json: {
            data: records.map { |d| deal_json(d) },
            meta: {
              has_more: has_more,
              next_cursor: has_more ? records.last&.id&.to_s : nil,
              limit: limit
            }
          }
        end

        # GET /api/partner/v1/deals/:id
        def show
          render json: { data: deal_json(@deal, detailed: true) }
        end

        # POST /api/partner/v1/deals
        def create
          # Safety net: unmapped inbound fields go to notes instead of being dropped.
          attrs = merge_inbound_note(deal_params.to_h, deal_params.keys)
          deal = company_scope(Deal).new(attrs)

          if deal.save
            render json: { data: deal_json(deal, detailed: true) }, status: :created
          else
            render json: { error: "Validation failed", details: deal.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/partner/v1/deals/:id
        def update
          if @deal.update(deal_params)
            render json: { data: deal_json(@deal, detailed: true) }
          else
            render json: { error: "Validation failed", details: @deal.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/partner/v1/deals/:id
        def destroy
          @deal.update!(deleted_at: Time.current)
          render json: { data: { id: @deal.id, deleted: true } }
        end

        private

        def authorize_deals
          case action_name
          when "index", "show"
            authorize_permission!(:deals, :read)
          when "create"
            authorize_permission!(:deals, :create)
          when "update"
            authorize_permission!(:deals, :update)
          when "destroy"
            authorize_permission!(:deals, :delete)
          end
        end

        def set_deal
          @deal = company_scope(Deal).where(deleted_at: nil).find(params[:id])
        end

        def deal_params
          params.permit(
            :name, :value, :stage, :probability, :expected_close_date,
            :actual_close_date, :description, :notes, :customer_name,
            :deal_type, :vertical, :quantity, :delivery_date,
            :account_id, :contact_id, :owner_id, :location_id,
            :vehicle_id, :source_id, :territory_id,
            :selling_price, :unit_cost, :trade_allowance, :trade_payoff,
            :doc_fee, :delivery_fee, :setup_fee, :skirting_fee,
            :accessories_total, :pack_amount, :finance_reserve, :product_margin
          )
        end

        def deal_json(deal, detailed: false)
          json = {
            id: deal.id,
            name: deal.name,
            value: deal.value,
            stage: deal.stage,
            probability: deal.probability,
            expected_close_date: deal.expected_close_date&.iso8601,
            account_id: deal.account_id,
            contact_id: deal.contact_id,
            owner_id: deal.owner_id,
            location_id: deal.location_id,
            vehicle_id: deal.vehicle_id,
            customer_name: deal.customer_name,
            deal_type: deal.deal_type,
            won_at: deal.won_at&.iso8601,
            lost_at: deal.lost_at&.iso8601,
            created_at: deal.created_at&.iso8601,
            updated_at: deal.updated_at&.iso8601
          }

          if detailed
            json.merge!(
              actual_close_date: deal.actual_close_date&.iso8601,
              description: deal.description,
              notes: deal.notes,
              vertical: deal.vertical,
              quantity: deal.quantity,
              delivery_date: deal.delivery_date&.iso8601,
              source_id: deal.source_id,
              territory_id: deal.territory_id,
              selling_price: deal.selling_price,
              unit_cost: deal.unit_cost,
              trade_allowance: deal.trade_allowance,
              trade_payoff: deal.trade_payoff,
              doc_fee: deal.doc_fee,
              delivery_fee: deal.delivery_fee,
              setup_fee: deal.setup_fee,
              skirting_fee: deal.skirting_fee,
              accessories_total: deal.accessories_total,
              pack_amount: deal.pack_amount,
              finance_reserve: deal.finance_reserve,
              product_margin: deal.product_margin,
              win_reason: deal.win_reason,
              loss_reason: deal.loss_reason,
              competitor: deal.competitor,
              primary_salesperson_id: deal.primary_salesperson_id,
              sales_manager_id: deal.sales_manager_id,
              finance_manager_id: deal.finance_manager_id
            )
          end

          json
        end
      end
    end
  end
end

# frozen_string_literal: true

module Api
  module V1
    # Company-level dealer-installed item defaults (Max Advance two-tier system, tier 1).
    # Managed in Company Settings > Finance. Seeded from 21st Mortgage allowances; dealers
    # edit Standard/Max defaults and set their own dealer_cost / dealer_price, plus add
    # custom items. When a lender is created these are copied as the lender's starting
    # schedule (tier 2 = per-lender overrides via LenderAllowanceItemsController).
    #
    # Reads available to deal-creators (the calculator needs them); writes are
    # admin/finance-gated. company_id is NEVER permitted — derived from scope.
    class CompanyAllowanceDefaultsController < ApplicationController
      before_action :set_company_scope
      before_action :set_item, only: [:show, :update, :destroy]

      def index
        return unless authorize_action!('deals', 'create')
        render json: @company.company_allowance_defaults.ordered.map { |i| item_json(i) }
      end

      def show
        return unless authorize_action!('deals', 'create')
        render json: item_json(@item)
      end

      def create
        return unless authorize_action!('accounting', 'update')
        item = @company.company_allowance_defaults.build(item_params)
        item.is_seeded = false
        item.position = next_position if item.position.to_i.zero?
        if item.save
          render json: item_json(item), status: :created
        else
          render json: { errors: item.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        return unless authorize_action!('accounting', 'update')
        if @item.update(item_params)
          render json: item_json(@item)
        else
          render json: { errors: @item.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        return unless authorize_action!('accounting', 'update')
        if @item.is_seeded
          # Seeded rows are deactivated rather than destroyed so re-seeding stays idempotent
          # and lender items that reference them (FK) keep their lineage.
          @item.update!(active: false)
        else
          @item.destroy
        end
        head :no_content
      end

      # POST /api/v1/company_allowance_defaults/seed
      # Idempotently (re)seeds the 21st Mortgage defaults for this company.
      def seed
        return unless authorize_action!('accounting', 'update')
        CompanyAllowanceDefault.seed_defaults(@company)
        render json: @company.company_allowance_defaults.ordered.map { |i| item_json(i) }
      end

      # POST /api/v1/company_allowance_defaults/sync_lenders
      # Pushes current defaults to lenders that are missing them (existing lenders created
      # before this system, or after new custom items were added). Never overwrites a
      # lender's existing per-item overrides — find_or_create only fills gaps.
      def sync_lenders
        return unless authorize_action!('accounting', 'update')
        synced = 0
        @company.lenders.not_deleted.find_each do |lender|
          CompanyAllowanceDefault.populate_lender(lender)
          synced += 1
        end
        render json: { message: "Synced defaults to #{synced} lender(s)", lenders_synced: synced }
      end

      private

      def set_item
        @item = @company.company_allowance_defaults.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      def item_params
        params.require(:allowance_default).permit(
          :category, :name, :standard_allowance, :maximum_allowance,
          :dealer_cost, :dealer_price, :pricing_basis, :material,
          :wind_zone2_adder_per_side, :wind_zone3_adder_per_side,
          :active, :position
        )
      end

      def next_position
        (@company.company_allowance_defaults.maximum(:position) || 0) + 10
      end

      def item_json(i)
        {
          id: i.id,
          category: i.category,
          name: i.name,
          standardAllowance: i.standard_allowance,
          maximumAllowance: i.maximum_allowance,
          dealerCost: i.dealer_cost,
          dealerPrice: i.dealer_price,
          pricingBasis: i.pricing_basis,
          material: i.material,
          windZone2AdderPerSide: i.wind_zone2_adder_per_side,
          windZone3AdderPerSide: i.wind_zone3_adder_per_side,
          isSeeded: i.is_seeded,
          active: i.active,
          position: i.position,
          createdAt: i.created_at,
          updatedAt: i.updated_at
        }
      end
    end
  end
end

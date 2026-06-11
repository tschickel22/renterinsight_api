# frozen_string_literal: true

module Api
  module V1
    # Finance-settings for a lender's markup/VEP config (Max Advance Phase 2).
    # Singular nested resource at /api/v1/lenders/:lender_id/markup_config — exactly
    # one per lender; create and update both UPSERT it.
    #
    # Read available to deal-creators (deals:create); writes admin/finance-gated
    # (accounting:update). company_id/lender_id never permitted (scope/route derived).
    class LenderMarkupConfigsController < ApplicationController
      before_action :set_company_scope
      before_action :set_lender

      def show
        return unless authorize_action!('deals', 'create')
        cfg = @lender.markup_config
        return render(json: { error: 'No markup config' }, status: :not_found) unless cfg
        render json: config_json(cfg)
      end

      def create
        upsert
      end

      def update
        upsert
      end

      private

      def upsert
        return unless authorize_action!('accounting', 'update')
        cfg = @lender.markup_config || @lender.build_markup_config
        existing = cfg.persisted?
        cfg.assign_attributes(config_params)
        cfg.company = @company
        if cfg.save
          render json: config_json(cfg), status: existing ? :ok : :created
        else
          render json: { errors: cfg.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def set_lender
        @lender = @company.lenders.not_deleted.find(params[:lender_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Lender not found' }, status: :not_found
      end

      def config_params
        params.require(:markup_config).permit(
          :base_markup_pct, :max_age_years, :vep0_adj_pct, :vep1_adj_pct, :vep2_adj_pct,
          :used_onsite_factor_pct, :used_delivered_factor_pct
        )
      end

      def config_json(c)
        {
          id: c.id,
          lenderId: c.lender_id,
          baseMarkupPct: c.base_markup_pct,
          maxAgeYears: c.max_age_years,
          vep0AdjPct: c.vep0_adj_pct,
          vep1AdjPct: c.vep1_adj_pct,
          vep2AdjPct: c.vep2_adj_pct,
          usedOnsiteFactorPct: c.used_onsite_factor_pct,
          usedDeliveredFactorPct: c.used_delivered_factor_pct,
          createdAt: c.created_at,
          updatedAt: c.updated_at
        }
      end
    end
  end
end

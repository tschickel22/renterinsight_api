# frozen_string_literal: true

module Api
  module V1
    # Surface A — dealer-facing catalog opt-in. Company-scoped: a dealer sees the
    # vetted catalog sources available to them and opts in/out. Platform-admin
    # management of the sources themselves lives in
    # Api::Admin::CatalogSourcesController.
    #
    # TENANT ISOLATION: everything is scoped to @company (set_company_scope).
    # company_id is NEVER read from params — the join row always belongs to the
    # current company.
    class CatalogSubscriptionsController < ApplicationController
      before_action :set_company_scope

      # GET /api/v1/catalog_subscriptions
      def index
        sources = CatalogSource.enabled.select(&:selectable_for_dealers?)
        subs    = @company.dealer_catalog_subscriptions.order(:id)

        render json: {
          availableSources: sources.map { |s| available_source_json(s) },
          subscriptions:    subs.map { |s| subscription_json(s) }
        }
      end

      # POST /api/v1/catalog_subscriptions
      def create
        source = CatalogSource.active.find_by(id: subscription_params[:catalog_source_id])
        unless source&.selectable_for_dealers?
          return render json: { error: 'catalog is not available to dealers' },
                        status: :unprocessable_entity
        end

        existing = @company.dealer_catalog_subscriptions.find_by(catalog_source_id: source.id)
        return render(json: { subscription: subscription_json(existing) }, status: :ok) if existing

        sub = @company.dealer_catalog_subscriptions.new(
          catalog_source_id: source.id,
          location_id:       subscription_params[:location_id],
          enabled:           true
        )
        sub.save!
        render json: { subscription: subscription_json(sub) }, status: :created
      rescue ActiveRecord::RecordNotUnique
        # Lost a race on the unique [company_id, catalog_source_id] index — return
        # the row that won. Idempotent, never a 500.
        existing = @company.dealer_catalog_subscriptions.find_by(
          catalog_source_id: subscription_params[:catalog_source_id]
        )
        render json: { subscription: subscription_json(existing) }, status: :ok
      end

      # DELETE /api/v1/catalog_subscriptions/:id
      # Scoped to the current company — another company's row is simply not found.
      # Only removes the join; imported vehicles are untouched.
      def destroy
        sub = @company.dealer_catalog_subscriptions.find(params[:id])
        sub.destroy!
        head :no_content
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Subscription not found' }, status: :not_found
      end

      private

      # company_id intentionally NOT permitted (tenant isolation).
      def subscription_params
        params.require(:catalog_subscription).permit(:catalog_source_id, :location_id)
      end

      def available_source_json(source)
        {
          id:             source.id,
          name:           source.name,
          adapterType:    source.adapter_type,
          manufacturerId: source.manufacturer_id
        }
      end

      def subscription_json(sub)
        {
          id:              sub.id,
          catalogSourceId: sub.catalog_source_id,
          locationId:      sub.location_id
        }
      end
    end
  end
end

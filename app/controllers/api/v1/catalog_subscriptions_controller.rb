# frozen_string_literal: true

module Api
  module V1
    # Surface A — dealer-facing catalog opt-in. Company-scoped: a dealer sees the
    # vetted catalog sources available to them and opts in/out, choosing which of
    # their locations the homes appear at (none = all locations). Platform-admin
    # management of the sources lives in Api::Admin::CatalogSourcesController.
    #
    # TENANT ISOLATION: everything is scoped to @company (set_company_scope).
    # company_id is NEVER read from params; location_ids are validated to belong
    # to the current company.
    class CatalogSubscriptionsController < ApplicationController
      # Platform-admin only. Subscribing a catalog writes available-to-order homes
      # into a dealer's inventory at chosen locations, and a wrong choice puts
      # another manufacturer's homes in front of that location's buyers. Dealer
      # staff previously reached this with inventory:manage; catalog assignment is
      # now something we do for them, alongside the per-dealer Clayton sources.
      #
      # Uses original_user, so it still works while impersonating a tenant.
      before_action :require_platform_admin!
      before_action :set_company_scope

      # GET /api/v1/catalog_subscriptions
      def index
        sources   = CatalogSource.enabled.select(&:selectable_for_dealers?)
        subs      = @company.dealer_catalog_subscriptions.order(:id)
        locations = @company.locations.where(is_deleted: [false, nil]).order(:name)

        render json: {
          availableSources: sources.map { |s| available_source_json(s) },
          subscriptions:    subs.map { |s| subscription_json(s) },
          locations:        locations.map { |l| { id: l.id, name: l.name } }
        }
      end

      # POST /api/v1/catalog_subscriptions — subscribe OR update locations (upsert).
      def create
        source = CatalogSource.active.find_by(id: subscription_params[:catalog_source_id])
        unless source&.selectable_for_dealers?
          return render json: { error: 'catalog is not available to dealers' },
                        status: :unprocessable_entity
        end

        sub = @company.dealer_catalog_subscriptions.find_or_initialize_by(catalog_source_id: source.id)
        was_new = sub.new_record?
        sub.enabled      = true
        sub.location_ids = permitted_location_ids
        sub.save!

        # Backfill the dealer's inventory now instead of waiting for the nightly
        # run (re-crawls the source; the in-progress guard prevents stacking).
        enqueue_run(source)

        render json: { subscription: subscription_json(sub) }, status: (was_new ? :created : :ok)
      rescue ActiveRecord::RecordNotUnique
        existing = @company.dealer_catalog_subscriptions.find_by(catalog_source_id: source&.id)
        render json: { subscription: subscription_json(existing) }, status: :ok
      end

      # DELETE /api/v1/catalog_subscriptions/:id — unsubscribe.
      # Removes the join. Pure catalog-imported vehicles get soft-deleted.
      # Supplement-stamped vehicles (dealer-originals we attached catalog data
      # to) are NOT deleted — they're un-stamped instead so they revert to
      # plain dealer rows. The catalog-filled values (images/specs) stay; the
      # dealer keeps the data they got from the catalog.
      def destroy
        sub = @company.dealer_catalog_subscriptions.find(params[:id])
        source_id = sub.catalog_source_id

        # 1) Soft-delete pure catalog imports for this source.
        @company.vehicles
                .where(catalog_source_id: source_id, is_deleted: [false, nil])
                .where("(catalog_last_synced_values->>'__supplemented__') IS DISTINCT FROM 'true'")
                .update_all(is_deleted: true, deleted_at: Time.current)

        # 2) Unstamp supplemented dealer vehicles for this source so a future
        # re-subscribe won't smart-update them as if they were never disconnected
        # (and so the destroy is reversible in a clean way — re-running supplement
        # picks them up by name match again).
        @company.vehicles
                .where(catalog_source_id: source_id, is_deleted: [false, nil])
                .where("(catalog_last_synced_values->>'__supplemented__') = 'true'")
                .update_all(
                  catalog_source_id: nil,
                  catalog_source_key: nil,
                  catalog_content_hash: nil,
                  catalog_last_synced_values: {},
                  catalog_last_seen_at: nil
                )

        sub.destroy!
        head :no_content
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Subscription not found' }, status: :not_found
      end

      private

      # company_id intentionally NOT permitted (tenant isolation).
      def subscription_params
        params.require(:catalog_subscription).permit(:catalog_source_id, location_ids: [])
      end

      # Only the current company's own locations may be targeted.
      def permitted_location_ids
        requested = Array(subscription_params[:location_ids]).map(&:to_i).uniq
        return [] if requested.empty?

        @company.locations.where(id: requested).pluck(:id)
      end

      def enqueue_run(source)
        return if source.scrape_runs.where(status: 'running').exists?

        CatalogSourceRunJob.perform_later(source.id, trigger: 'scheduled')
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
          locationIds:     Array(sub.location_ids).map(&:to_i)
        }
      end
    end
  end
end

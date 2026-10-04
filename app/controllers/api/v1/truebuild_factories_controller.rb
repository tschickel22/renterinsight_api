# frozen_string_literal: true

module Api
  module V1
    # The factories a dealer offers in TrueBuild (backlog E64). Only platform
    # admins choose them, beside the dealer's catalog subscriptions, and only
    # released factories can be given. Scoped to the company being viewed.
    class TruebuildFactoriesController < ApplicationController
      # Uses original_user, so it works while impersonating the dealer.
      before_action :require_platform_admin!
      before_action :set_company_scope

      # GET /api/v1/truebuild_factories
      def index
        given = @company.dealer_factories.includes(factory: :manufacturer).order(:created_at)
        suggestions = Truebuild::DealerFactories.suggestions(@company)
        others = Factory.truebuild_released.where.not(id: given.map(&:factory_id) + suggestions.map { |s| s[:factory].id })
                        .includes(:manufacturer).order(:name)
        render json: {
          given: given.map { |d| factory_json(d.factory).merge(added_at: d.created_at) },
          suggestions: suggestions.map { |s| factory_json(s[:factory]).merge(miles: s[:miles]) },
          others: others.map { |f| factory_json(f) },
          suggest_miles: Truebuild::DealerFactories::SUGGEST_MILES
        }
      end

      # POST /api/v1/truebuild_factories { factory_id }
      def create
        factory = Factory.find_by(id: params[:factory_id])
        return render json: { error: 'Factory not found' }, status: :not_found unless factory

        row = @company.dealer_factories.find_or_initialize_by(factory_id: factory.id)
        row.added_by_id ||= current_user&.id
        return render json: { error: row.errors.full_messages.to_sentence }, status: :unprocessable_entity unless row.save

        Truebuild::FactoryReadiness.bust!
        render json: factory_json(factory), status: :created
      end

      # DELETE /api/v1/truebuild_factories/:id   (the factory's id)
      # Its homes leave the dealer's designer at once; saved designs keep working.
      def destroy
        row = @company.dealer_factories.find_by(factory_id: params[:id])
        return render json: { error: 'Not found' }, status: :not_found unless row

        row.destroy!
        Truebuild::FactoryReadiness.bust!
        head :no_content
      end

      private

      def factory_json(factory)
        { id: factory.id, name: factory.name, city: factory.city, state: factory.state,
          manufacturer: factory.manufacturer&.name, released: factory.truebuild_released? }
      end
    end
  end
end

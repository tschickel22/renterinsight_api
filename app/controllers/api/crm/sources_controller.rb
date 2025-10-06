# frozen_string_literal: true
# app/controllers/api/crm/sources_controller.rb

module Api
  module Crm
    class SourcesController < ApplicationController
      before_action :set_source, only: [:show, :update, :destroy, :stats]

      # GET /api/crm/sources
      def index
        sources = Source.all.order(:name)
        render json: sources.map { |s| source_json(s) }, status: :ok
      end

      # GET /api/crm/sources/:id
      def show
        render json: source_json(@source), status: :ok
      end

      # POST /api/crm/sources
      def create
        source = Source.new(source_params)
        
        if source.save
          render json: source_json(source), status: :created
        else
          render json: { errors: source.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/crm/sources/:id
      def update
        if @source.update(source_params)
          render json: source_json(@source), status: :ok
        else
          render json: { errors: @source.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/crm/sources/:id
      def destroy
        @source.destroy!
        head :no_content
      end

      # GET /api/crm/sources/:id/stats
      def stats
        leads_count = Lead.where(source_id: @source.id).count
        
        render json: {
          sourceId: @source.id,
          sourceName: @source.name,
          leadsCount: leads_count,
          conversionRate: @source.try(:conversion_rate) || 0.0
        }, status: :ok
      end

      private

      def set_source
        @source = Source.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Source not found' }, status: :not_found
      end

      def source_params
        params.require(:source).permit(:name, :source_type, :tracking_code, :is_active)
      rescue ActionController::ParameterMissing
        # Handle both nested and root-level params
        params.permit(:name, :source_type, :type, :tracking_code, :trackingCode, :is_active, :isActive)
      end

      def source_json(source)
        {
          id: source.id,
          name: source.name,
          type: source.try(:source_type),
          sourceType: source.try(:source_type),
          trackingCode: source.try(:tracking_code),
          isActive: source.try(:is_active).nil? ? true : source.is_active,
          createdAt: source.created_at&.iso8601,
          updatedAt: source.updated_at&.iso8601
        }.compact
      end
    end
  end
end

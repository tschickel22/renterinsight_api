# frozen_string_literal: true
# Sources are company-scoped for proper multi-tenant isolation

module Api
  module Crm
    class SourcesController < ApplicationController
      include RbacAuthorization
      rbac_resource :leads,
        read_actions: [:index, :show, :stats],
        create_actions: [:create],
        update_actions: [:update],
        delete_actions: [:destroy]

      before_action :set_company_scope
      before_action :set_company_id
      before_action :set_source, only: [:show, :update, :destroy, :stats]

      # GET /api/crm/sources
      def index
        sources = company_sources.order(:name)
        render json: sources.map { |s| source_json(s) }, status: :ok
      end

      # GET /api/crm/sources/:id
      def show
        render json: source_json(@source), status: :ok
      end

      # POST /api/crm/sources
      def create
        name = params[:name] || params.dig(:source, :name)

        if name.blank?
          return render json: { error: 'Name is required' }, status: :unprocessable_entity
        end

        source = company_sources.new(source_params)
        source.company_id = @company_id

        if source.save
          render json: source_json(source), status: :created
        else
          render json: {
            ok: false,
            errors: source.errors.full_messages
          }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/crm/sources/:id
      def update
        if @source.update(source_params)
          render json: source_json(@source), status: :ok
        else
          render json: {
            ok: false,
            errors: @source.errors.full_messages
          }, status: :unprocessable_entity
        end
      end

      # DELETE /api/crm/sources/:id
      def destroy
        @source.destroy!
        head :no_content
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/crm/sources/:id/stats
      def stats
        leads_scope = @company.leads.where(source_id: @source.id)
        deals_scope = @company.deals.where(source_id: @source.id)

        leads_count = leads_scope.count
        deals_count = deals_scope.count
        conversion_rate = leads_count > 0 ? (deals_count.to_f / leads_count * 100).round(1) : 0.0

        render json: {
          leads: leads_count,
          deals: deals_count,
          conversionRate: conversion_rate
        }, status: :ok
      end

      private

      def set_company_scope
        unless current_user
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end

        company_id = current_company_id

        unless company_id.present?
          render json: { error: 'No company context' }, status: :forbidden
          return
        end

        @company = ::Company.find_by(id: company_id)

        if @company.nil?
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
      end

      def set_company_id
        @company_id = request.headers['X-Company-ID'].presence&.to_i || @company&.id
      end

      def company_sources
        if @company_id.present?
          Source.where(company_id: @company_id)
        else
          Source.none
        end
      end

      def set_source
        @source = company_sources.find_by(id: params[:id])
        unless @source
          render json: { error: 'Source not found or access denied' }, status: :not_found
          return
        end
      end

      def source_params
        if params[:source].present?
          params.require(:source).permit(:name, :source_type, :tracking_code, :is_active)
        else
          {
            name: params[:name],
            source_type: params[:source_type] || params[:type],
            tracking_code: params[:tracking_code] || params[:trackingCode],
            is_active: params[:is_active].nil? ? true : params[:is_active]
          }.compact
        end
      end

      def source_json(source)
        {
          id: source.id,
          name: source.name,
          type: source.try(:source_type),
          sourceType: source.try(:source_type),
          trackingCode: source.try(:tracking_code),
          isActive: source.respond_to?(:is_active) ? (source.is_active.nil? ? true : source.is_active) : true,
          is_active: source.respond_to?(:is_active) ? (source.is_active.nil? ? true : source.is_active) : true,
          createdAt: source.respond_to?(:created_at) ? source.created_at&.iso8601 : nil,
          updatedAt: source.respond_to?(:updated_at) ? source.updated_at&.iso8601 : nil
        }.compact
      end
    end
  end
end

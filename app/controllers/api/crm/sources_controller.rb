# frozen_string_literal: true
# Sources are now company-scoped for proper multi-tenant isolation

module Api
  module Crm
    class SourcesController < ApplicationController
      include RbacAuthorization
      rbac_resource :crm,
        read_actions: [:index, :show, :stats],
        create_actions: [:create],
        update_actions: [:update],
        delete_actions: [:destroy]

      before_action :set_company_scope
      before_action :set_source, only: [:show, :update, :destroy, :stats]

      # GET /api/crm/sources
      def index
        # Company-scoped sources (includes company sources + global sources with nil company_id)
        sources = Source.for_company(@company.id).order(:name)
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
        
        # Create source within current company
        source = @company.sources.new(source_params)
        
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
        # STRICT TENANT ISOLATION: Only count leads from current company
        leads_count = @company.leads.where(source_id: @source.id).count
        deals_count = @company.deals.where(source_id: @source.id).count
        
        render json: {
          sourceId: @source.id,
          sourceName: @source.name,
          leadsCount: leads_count,
          conversionRate: @source.try(:conversion_rate) || 0.0,
          dealsCount: deals_count
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

      def set_source
        # Company-scoped sources (includes company sources + global sources)
        @source = Source.for_company(@company.id).find_by(id: params[:id])
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

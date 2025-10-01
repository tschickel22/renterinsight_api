module Api
  module Crm
    class SourcesController < ApplicationController
      before_action :set_source, only: [:update, :destroy, :stats]

      def index
        render json: Source.order(created_at: :desc).map { |s| source_json(s) }
      end

      def create
        s = Source.new(source_params)
        s.source_type   = params[:type] if params.key?(:type)
        s.tracking_code = params[:trackingCode] if params.key?(:trackingCode)
        s.is_active     = true if s.is_active.nil?
        s.save!
        render json: source_json(s), status: :created
      end

      def update
        attrs = source_params
        attrs[:source_type]   = params[:type] if params.key?(:type)
        attrs[:tracking_code] = params[:trackingCode] if params.key?(:trackingCode)
        @source.update!(attrs)
        render json: source_json(@source)
      end

      def destroy
        @source.destroy!
        head :no_content
      end

      def stats
        leads_count = Lead.where(source_id: @source.id).count
        conv = @source.conversion_rate.present? ? @source.conversion_rate.to_f : 0.0
        render json: { leads: leads_count, deals: 0, conversionRate: conv }
      end

      private

      def set_source
        @source = Source.find(params[:id])
      end

      def source_params
        h = params.permit(:name, :isActive).to_h
        h.transform_keys! { |k| k == 'isActive' ? 'is_active' : k }
        h.symbolize_keys
      end

      def source_json(s)
        {
          id: s.id,
          name: s.name,
          type: s.source_type,
          trackingCode: s.tracking_code,
          isActive: s.is_active,
          createdAt: s.created_at,
          updatedAt: s.updated_at
        }
      end
    end
  end
end

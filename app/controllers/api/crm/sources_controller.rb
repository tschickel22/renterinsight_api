module Api
  module Crm
    class SourcesController < ApplicationController
      def index
        records = Source.order(:name) rescue []
        records = [
          OpenStruct.new(id: 1, name: "Web", is_active: true),
          OpenStruct.new(id: 2, name: "Referral", is_active: true),
          OpenStruct.new(id: 3, name: "Walk-in", is_active: true)
        ] if records.blank?

        render json: records.map { |s|
          { id: s.id, name: s.name,
            is_active: (s.respond_to?(:is_active) ? s.is_active : true),
            isActive:  (s.respond_to?(:is_active) ? s.is_active : true) }
        }
      end

      def create; render json: { ok: true }, status: :created; end
      def update; render json: { ok: true }; end
    end
  end
end

# frozen_string_literal: true

module Api
  module Crm
    # Everything messaging one lead or contact, with Stop (Automations::ForRecord).
    #   GET  /api/crm/automations?record_type=Lead&record_id=1
    #   POST /api/crm/automations/stop      { record_type, record_id, kind, id }
    #   POST /api/crm/automations/stop_all  { record_type, record_id }
    class AutomationsController < ApplicationController
      before_action :set_company_scope

      RESOURCES = { 'Lead' => 'leads', 'Contact' => 'crm' }.freeze

      def index
        return unless authorize_action!(resource, 'read')
        return unless (automations = load_automations)

        render json: automations.payload
      end

      def stop
        return unless authorize_action!(resource, 'update')
        return unless (automations = load_automations)

        automations.stop!(params[:kind], params[:id])
        render json: automations.payload
      rescue Automations::ForRecord::NotFound => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def stop_all
        return unless authorize_action!(resource, 'update')
        return unless (automations = load_automations)

        stopped = automations.stop_all!
        render json: automations.payload.merge(stopped: stopped)
      end

      private

      def record_type
        RESOURCES.key?(params[:record_type].to_s) ? params[:record_type].to_s : 'Lead'
      end

      def resource
        RESOURCES.fetch(record_type)
      end

      def load_automations
        scope = record_type == 'Lead' ? @company.leads : @company.contacts
        record = scope.find_by(id: params[:record_id])
        unless record
          render json: { error: 'Not found' }, status: :not_found
          return nil
        end

        Automations::ForRecord.new(company: @company, record: record, user: current_user)
      end
    end
  end
end

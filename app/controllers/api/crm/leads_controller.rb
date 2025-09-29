module Api
  module Crm
    class LeadsController < ApplicationController
      before_action :set_lead, only: [:update, :destroy, :notes]

      def index
        render json: Lead.includes(:source).order(created_at: :desc).map { |l| lead_json(l) }
      end

      def create
        l = Lead.new(lead_params)
        l.save!
        render json: lead_json(l), status: :created
      end

      def update
        @lead.update!(lead_params)
        render json: lead_json(@lead)
      end

      def destroy
        @lead.destroy!
        head :no_content
      end

      def notes
        @lead.update!(notes: params[:notes].to_s)
        render json: lead_json(@lead)
      end

      private

      def set_lead
        @lead = Lead.find(params[:id])
      end

      # Merge root + nested (:lead), accept camel & snake, normalize to snake.
      def lead_params
        allowed = [:first_name, :last_name, :email, :phone, :notes, :source_id,
                   :firstName, :lastName, :sourceId]

        root = params.permit(*allowed, lead: {})
        nested = params[:lead].is_a?(ActionController::Parameters) ? params.require(:lead).permit(*allowed) : {}

        raw = root.to_h.merge(nested.to_h) # nested wins if both present

        {
          first_name: raw['first_name'] || raw['firstName'],
          last_name:  raw['last_name']  || raw['lastName'],
          email:      raw['email'],
          phone:      raw['phone'],
          notes:      raw['notes'],
          source_id:  (raw['source_id']  || raw['sourceId']).presence&.to_i
        }.compact
      end

      def lead_json(l)
        {
          id:        l.id,
          firstName: l.first_name,
          lastName:  l.last_name,
          email:     l.email,
          phone:     l.phone,
          notes:     l.notes,
          sourceId:  l.source_id,
          source:    (l.source ? { id: l.source.id, name: l.source.name } : nil),
          createdAt: l.created_at,
          updatedAt: l.updated_at
        }
      end
    end
  end
end

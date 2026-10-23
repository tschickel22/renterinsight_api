# frozen_string_literal: true

module Api
  module V1
    # Followers on a lead, account, contact or deal (backlog E86).
    #
    #   GET /api/v1/followers?record_type=lead&record_id=1
    #   PUT /api/v1/followers  { record_type, record_id, user_ids: [] }  (replaces the set)
    class FollowersController < ApplicationController
      include FollowedRecords

      before_action :set_company_scope
      before_action :set_record

      # record_type => [model association, RBAC resource]
      TYPES = {
        'lead'    => [:leads,    'leads'],
        'account' => [:accounts, 'crm'],
        'contact' => [:contacts, 'crm'],
        'deal'    => [:deals,    'deals']
      }.freeze

      def show
        return unless authorize_action!(@resource, 'read')

        render json: { followers: followers_payload }
      end

      def update
        return unless authorize_action!(@resource, 'update')

        @record.replace_followers!(params[:user_ids], by: current_user)
        render json: { followers: followers_payload }
      end

      private

      def set_record
        association, @resource = TYPES[params[:record_type].to_s]
        return render(json: { error: 'Unknown record type' }, status: :bad_request) unless association

        @record = visible(@company.public_send(association)).find(params[:record_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      # The same reach the record's own page has: admins and company-wide
      # readers see everything, a location-tier rep sees their locations
      # (accounts and contacts also those with no location) and what they follow.
      def visible(scope)
        return scope unless current_user.uses_rbac? && !current_user.effective_admin?
        return scope if @resource == 'leads' && permission_service.can?('leads', 'read', 'all')

        location_ids = permission_service.accessible_location_ids
        return scope if location_ids.empty?

        located = if %w[accounts contacts].include?(scope.klass.table_name)
                    scope.where('location_id IN (?) OR location_id IS NULL', location_ids)
                  else
                    scope.where(location_id: location_ids)
                  end
        or_followed(scope, located)
      end

      def followers_payload
        @record.followers.order(:first_name, :last_name).map { |u| { id: u.id, name: u.name, email: u.email } }
      end
    end
  end
end

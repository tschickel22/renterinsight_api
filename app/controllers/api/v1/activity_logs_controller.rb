# frozen_string_literal: true

module Api
  module V1
    class ActivityLogsController < ApplicationController
      before_action :set_company_scope

      # GET /api/v1/activity_logs
      def index
        logs = @company.activity_logs

        # Permission-based scoping
        unless can?('activity_logs', 'read')
          if current_user.uses_rbac? && !current_user.effective_admin?
            location_ids = permission_service.accessible_location_ids
            logs = logs.where("location_id IN (?) OR location_id IS NULL", location_ids)
          else
            logs = logs.for_user(current_user.id)
          end
        end

        logs = apply_filters(logs)

        # Stats (before pagination)
        stats = build_stats(logs)

        # Pagination
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 25).to_i, 100].min
        total = logs.count
        logs = logs.recent.offset((page - 1) * per_page).limit(per_page)
        logs = logs.includes(:user)

        render json: {
          activity_logs: serialize_logs(logs),
          meta: {
            total: total,
            page: page,
            per_page: per_page,
            total_pages: (total.to_f / per_page).ceil,
            stats: stats
          }
        }
      end

      # GET /api/v1/activity_logs/my_activity
      def my_activity
        logs = @company.activity_logs.for_user(current_user.id)
        logs = apply_filters(logs, exclude: [:user_id])

        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 10).to_i, 100].min
        total = logs.count
        logs = logs.recent.offset((page - 1) * per_page).limit(per_page)
        logs = logs.includes(:user)

        render json: {
          activity_logs: serialize_logs(logs),
          meta: {
            total: total,
            page: page,
            per_page: per_page,
            total_pages: (total.to_f / per_page).ceil
          }
        }
      end

      # GET /api/v1/activity_logs/account/:account_id
      def account_feed
        return unless authorize_action!('crm', 'read')

        logs = @company.activity_logs.for_account(params[:account_id])
        logs = apply_filters(logs)

        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 25).to_i, 100].min
        total = logs.count
        logs = logs.recent.offset((page - 1) * per_page).limit(per_page)
        logs = logs.includes(:user)

        render json: {
          activity_logs: serialize_logs(logs),
          meta: {
            total: total,
            page: page,
            per_page: per_page,
            total_pages: (total.to_f / per_page).ceil
          }
        }
      end

      # GET /api/v1/activity_logs/entity/:trackable_type/:trackable_id
      def entity_feed
        trackable_type = params[:trackable_type]
        module_name = module_for_type(trackable_type)
        return unless authorize_action!(module_name, 'read') if module_name != 'general'

        logs = @company.activity_logs
                       .where(trackable_type: trackable_type, trackable_id: params[:trackable_id])
        logs = apply_filters(logs)

        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 25).to_i, 100].min
        total = logs.count
        logs = logs.recent.offset((page - 1) * per_page).limit(per_page)
        logs = logs.includes(:user)

        render json: {
          activity_logs: serialize_logs(logs),
          meta: {
            total: total,
            page: page,
            per_page: per_page,
            total_pages: (total.to_f / per_page).ceil
          }
        }
      end

      # GET /api/v1/activity_logs/stats
      def stats
        logs = @company.activity_logs

        unless can?('activity_logs', 'read')
          if current_user.uses_rbac? && !current_user.effective_admin?
            location_ids = permission_service.accessible_location_ids
            logs = logs.where("location_id IN (?) OR location_id IS NULL", location_ids)
          else
            logs = logs.for_user(current_user.id)
          end
        end

        render json: { stats: build_stats(logs) }
      end

      private

      def apply_filters(logs, exclude: [])
        logs = logs.for_user(params[:user_id]) if params[:user_id].present? && !exclude.include?(:user_id)
        logs = logs.for_module(params[:module_name]) if params[:module_name].present?
        logs = logs.for_action(params[:action_filter]) if params[:action_filter].present?
        logs = logs.for_account(params[:account_id]) if params[:account_id].present?
        logs = logs.where(trackable_type: params[:trackable_type]) if params[:trackable_type].present?

        if params[:search].present?
          logs = logs.where("description ILIKE ?", "%#{params[:search]}%")
        end

        if params[:start_date].present? && params[:end_date].present?
          logs = logs.for_date_range(
            Time.zone.parse(params[:start_date]).beginning_of_day,
            Time.zone.parse(params[:end_date]).end_of_day
          )
        end

        logs
      end

      def build_stats(logs)
        {
          today: logs.where(created_at: Time.current.beginning_of_day..Time.current.end_of_day).count,
          this_week: logs.where(created_at: Time.current.beginning_of_week..Time.current.end_of_week).count,
          by_module: logs.group(:module_name).count,
          by_action: logs.group(:action).count
        }
      end

      def serialize_logs(logs)
        logs.map do |log|
          user = log.user
          {
            id: log.id,
            user: user ? {
              id: user.id,
              first_name: user.try(:first_name),
              last_name: user.try(:last_name),
              email: user.email,
              avatar_url: user.try(:avatar_url)
            } : nil,
            action: log.action,
            module_name: log.module_name,
            entity_type_label: log.entity_type_label,
            description: log.description,
            changes_made: log.changes_made,
            metadata: log.metadata,
            trackable_type: log.trackable_type,
            trackable_id: log.trackable_id,
            account_id: log.account_id,
            created_at: log.created_at
          }
        end
      end

      def module_for_type(type)
        case type
        when 'Lead', 'Contact', 'Account', 'Deal' then 'crm'
        when 'Quote', 'Invoice', 'Payment' then 'finance'
        when 'ServiceTicket' then 'service'
        when 'Vehicle', 'Part' then 'inventory'
        when 'Communication' then 'communications'
        else 'general'
        end
      end
    end
  end
end

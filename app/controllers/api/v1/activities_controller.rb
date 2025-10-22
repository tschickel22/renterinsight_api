# frozen_string_literal: true

module Api
  module V1
    class ActivitiesController < ApplicationController
      before_action :set_company

      # GET /api/v1/activities/recent
      def recent
        limit = [params[:limit]&.to_i || 10, 50].min

        activities = fetch_recent_activities(limit)

        render json: { activities: activities }
      end

      private

      def set_company
        @company = ::Company.find_by(id: current_user.company_id)
        @company ||= ::Company.first
        
        unless @company
          render json: { error: 'Company not found' }, status: :not_found
        end
      end

      def fetch_recent_activities(limit)
        activities = []

        # Fetch recent vehicles created/updated
        recent_vehicles = @company.vehicles.active.order(created_at: :desc).limit(limit / 4)
        recent_vehicles.each do |vehicle|
          activities << {
            id: "vehicle-#{vehicle.id}",
            type: 'inventory',
            title: 'New inventory added',
            description: "#{vehicle.display_name} added to inventory",
            time: time_ago(vehicle.created_at),
            timestamp: vehicle.created_at.iso8601,
            entity_type: 'Vehicle',
            entity_id: vehicle.id.to_s
          }
        end

        # Fetch recent quotes
        begin
          if defined?(Quote)
            recent_quotes = @company.quotes.order(created_at: :desc).limit(limit / 4)
            recent_quotes.each do |quote|
              customer_name = quote.try(:customer)&.full_name || 'Customer'
              activities << {
                id: "quote-#{quote.id}",
                type: 'quote',
                title: "Quote #{quote.status}",
                description: "Quote #{quote.quote_number} for #{customer_name}",
                time: time_ago(quote.updated_at),
                timestamp: quote.updated_at.iso8601,
                entity_type: 'Quote',
                entity_id: quote.id.to_s
              }
            end
          end
        rescue => e
          Rails.logger.warn "Failed to fetch quotes for activities: #{e.message}"
        end

        # Fetch recent leads if CRM module exists
        begin
          if defined?(Lead)
            recent_leads = Lead.where(company: @company).order(created_at: :desc).limit(limit / 4)
            recent_leads.each do |lead|
              activities << {
                id: "lead-#{lead.id}",
                type: 'lead',
                title: 'New lead captured',
                description: "#{lead.full_name} - #{lead.status}",
                time: time_ago(lead.created_at),
                timestamp: lead.created_at.iso8601,
                entity_type: 'Lead',
                entity_id: lead.id.to_s
              }
            end
          end
        rescue => e
          Rails.logger.warn "Failed to fetch leads for activities: #{e.message}"
        end

        # Fetch recent deals if they exist
        begin
          if defined?(Deal)
            recent_deals = Deal.where(company: @company).order(updated_at: :desc).limit(limit / 4)
            recent_deals.each do |deal|
              activities << {
                id: "deal-#{deal.id}",
                type: 'deal',
                title: "Deal updated: #{deal.stage}",
                description: "#{deal.name} - #{deal.stage}",
                time: time_ago(deal.updated_at),
                timestamp: deal.updated_at.iso8601,
                entity_type: 'Deal',
                entity_id: deal.id.to_s
              }
            end
          end
        rescue => e
          Rails.logger.warn "Failed to fetch deals for activities: #{e.message}"
        end

        # Sort by timestamp descending and limit
        activities.sort_by { |a| a[:timestamp] }.reverse.take(limit)
      end

      def time_ago(time)
        seconds = Time.current - time
        
        case seconds
        when 0..59
          'just now'
        when 60..3599
          minutes = (seconds / 60).to_i
          "#{minutes} #{minutes == 1 ? 'minute' : 'minutes'} ago"
        when 3600..86399
          hours = (seconds / 3600).to_i
          "#{hours} #{hours == 1 ? 'hour' : 'hours'} ago"
        when 86400..2591999
          days = (seconds / 86400).to_i
          "#{days} #{days == 1 ? 'day' : 'days'} ago"
        else
          time.strftime('%B %d, %Y')
        end
      end
    end
  end
end

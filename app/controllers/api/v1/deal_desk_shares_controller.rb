# frozen_string_literal: true

module Api
  module V1
    # Public-token share of one or more Deal Desk scenarios.
    # * POST   /api/v1/deal_desk/shares         — create + send via SMS/email
    # * GET    /api/v1/deal_desk/shares/:token  — public snapshot (no auth)
    #
    # Design:
    # * Snapshot is authoritative and customer-safe (no gross/cost/margin).
    #   Enforced in `DealDesk::ShareSnapshotBuilder`, not the client.
    # * Delivery mirrors the brochure pattern (`DealDesk::ShareSendingService`
    #   wrapping `CommunicationService`) so opt-outs, provider selection, and
    #   activity logging behave identically.
    class DealDeskSharesController < ApplicationController
      include ModuleAccessRequired
      include VehicleBrochureJson

      before_action :set_company_scope, except: [:show]
      require_module! 'sales.deal_desk', except: [:show]
      skip_before_action :authenticate, only: [:show]

      RESOURCE = 'deal_desk'

      # POST /api/v1/deal_desk/shares
      # Body: { deal_id, scenario_ids: [], channels: ['email'|'sms'], to_email, to_phone, custom_message, expires_in_days }
      def create
        return unless authorize_action!(RESOURCE, 'read')

        deal = @company.deals.find(params.require(:deal_id))
        scenario_ids = Array(params[:scenario_ids]).map(&:to_i).reject(&:zero?).uniq
        return render_error('At least one scenario is required', :unprocessable_entity) if scenario_ids.empty?

        scenarios = deal.deal_desk_scenarios.where(id: scenario_ids).to_a
        return render_error('No matching scenarios for this deal', :unprocessable_entity) if scenarios.empty?

        channels = Array(params[:channels]).map(&:to_s) & %w[email sms]
        return render_error('Pick at least one channel (email or sms)', :unprocessable_entity) if channels.empty?

        vehicle = scenarios.first.vehicle_id ? Vehicle.find_by(id: scenarios.first.vehicle_id) : deal.vehicle
        vehicle_payload = vehicle ? vehicle_brochure_payload(vehicle) : nil

        snapshot = DealDesk::ShareSnapshotBuilder.new(
          deal: deal,
          scenarios: scenarios,
          vehicle_payload: vehicle_payload
        ).build

        share = DealDeskShare.new(
          company: @company,
          deal: deal,
          shared_by: current_user,
          scenario_ids: scenario_ids,
          channels: channels,
          to_email: params[:to_email].presence,
          to_phone: params[:to_phone].presence,
          custom_message: params[:custom_message].presence,
          snapshot: snapshot,
          expires_at: parse_expires_at(params[:expires_in_days])
        )

        unless share.save
          return render_error(share.errors.full_messages.join(', '), :unprocessable_entity)
        end

        service = DealDesk::ShareSendingService.new(share)
        results = service.send(
          delivery_methods: channels,
          to_email: share.to_email,
          to_phone: share.to_phone,
          custom_message: share.custom_message
        )
        share.update_columns(
          sent_at: Time.current,
          send_results: results.transform_values { |v| v.is_a?(Array) ? v.map(&:to_s) : v }
        )

        render json: {
          share: {
            id: share.id,
            token: share.public_token,
            public_url: share.public_url(frontend_base_url),
            channels: share.channels,
            sent_at: share.sent_at,
            expires_at: share.expires_at,
            delivery: {
              sent:   results[:sent].map { |r| { channel: r[:channel], to: r[:to] } },
              failed: results[:failed]
            }
          }
        }, status: :created
      rescue ActiveRecord::RecordNotFound
        render_error('Deal not found', :not_found)
      rescue ArgumentError => e
        render_error(e.message, :unprocessable_entity)
      end

      # POST /api/v1/deal_desk/shares/preview
      # Assembles the SAME customer-safe payload that `show` returns for a share,
      # but without persisting anything. Used by the in-app "Print Package" flow
      # so the print HTML matches byte-for-byte what a customer would receive.
      def preview
        return unless authorize_action!(RESOURCE, 'read')

        deal = @company.deals.find(params.require(:deal_id))
        scenario_ids = Array(params[:scenario_ids]).map(&:to_i).reject(&:zero?).uniq
        return render_error('At least one scenario is required', :unprocessable_entity) if scenario_ids.empty?

        scenarios = deal.deal_desk_scenarios.where(id: scenario_ids).to_a
        return render_error('No matching scenarios for this deal', :unprocessable_entity) if scenarios.empty?

        vehicle = scenarios.first.vehicle_id ? Vehicle.find_by(id: scenarios.first.vehicle_id) : deal.vehicle
        vehicle_payload = vehicle ? vehicle_brochure_payload(vehicle) : nil

        snapshot = DealDesk::ShareSnapshotBuilder.new(
          deal: deal,
          scenarios: scenarios,
          vehicle_payload: vehicle_payload
        ).build

        render json: {
          preview: {
            deal: snapshot['deal'],
            vehicle: snapshot['vehicle'],
            unit: snapshot['unit'],
            location: snapshot['location'],
            salesperson: snapshot['salesperson'],
            scenarios: snapshot['scenarios'],
            company: {
              name: @company.name,
              branding: @company.branding_settings || {}
            },
            rep: current_user ? {
              name: current_user.respond_to?(:full_name) ? current_user.full_name : current_user.email,
              email: current_user.email,
              phone: current_user.respond_to?(:phone) ? current_user.phone : nil
            } : nil
          }
        }
      rescue ActiveRecord::RecordNotFound
        render_error('Deal not found', :not_found)
      end

      # GET /api/v1/deal_desk/shares/:token  (public)
      def show
        share = DealDeskShare.find_by!(public_token: params[:token])
        if share.expired?
          return render json: { error: 'This link has expired.' }, status: :gone
        end
        share.register_view!

        render json: {
          share: {
            token: share.public_token,
            deal: share.snapshot['deal'],
            vehicle: share.snapshot['vehicle'],
            unit: share.snapshot['unit'],
            location: share.snapshot['location'],
            salesperson: share.snapshot['salesperson'],
            scenarios: share.snapshot['scenarios'],
            shared_at: share.snapshot['shared_at'],
            company: {
              name: share.company&.name,
              branding: share.company&.branding_settings || {}
            }
          }
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Share link not found.' }, status: :not_found
      end

      private

      def render_error(message, status)
        render json: { error: message }, status: status
      end

      def parse_expires_at(days)
        return nil if days.blank?
        n = days.to_i
        return nil if n <= 0
        n.days.from_now
      end

      def frontend_base_url
        ENV['FRONTEND_URL'] || ENV['API_BASE_URL'] || 'http://localhost:5173'
      end
    end
  end
end

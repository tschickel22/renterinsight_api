# frozen_string_literal: true

module Api
  module V1
    # Starter plays: bundles a dealer turns on with a few answers instead of
    # building each workflow, form, sequence or campaign by hand, then
    # customizes and watches.
    class PlaysController < ApplicationController
      include ModuleAccessRequired

      before_action :set_company_scope
      require_module! 'marketing.automation'
      before_action :set_play, only: [:show, :install, :customize, :uninstall, :performance, :leads, :lead_journey]

      # GET /api/v1/plays
      # Offered plays, plus any retired play this company still has on.
      def index
        return unless authorize_action!('workflow_automation', 'read')

        plays = Plays::Registry.all.select do |play|
          !play.hidden? || active_installation(play).present?
        end
        render json: { plays: plays.map { |play| play_json(play) } }
      end

      # GET /api/v1/plays/:id
      def show
        return unless authorize_action!('workflow_automation', 'read')

        render json: { play: play_json(@play) }
      end

      # POST /api/v1/plays/:id/install
      def install
        return unless authorize_action!('workflow_automation', 'create')
        return render(json: { error: "#{@play::NAME} is no longer offered." }, status: :unprocessable_entity) if @play.hidden?

        @play.new(company: @company, user: current_user, answers: answers_param).install!
        render json: { play: play_json(@play) }, status: :created
      rescue Plays::InstallError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH /api/v1/plays/:id/customize
      def customize
        return unless authorize_action!('workflow_automation', 'update')
        return unless (installation = require_installation)

        @play.new(company: @company, user: current_user, answers: answers_param, installation: installation).customize!
        render json: { play: play_json(@play) }
      rescue Plays::InstallError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/plays/:id/uninstall
      def uninstall
        return unless authorize_action!('workflow_automation', 'update')
        return unless (installation = require_installation)

        @play.uninstall!(installation)
        render json: { play: play_json(@play) }
      end

      # GET /api/v1/plays/:id/performance?period=90
      # Where leads are in the play, counts per step, and whether it works.
      def performance
        return unless authorize_action!('workflow_automation', 'read')
        return unless (installation = require_installation)

        render json: @play.performance_for(installation, period: params[:period], location_ids: visible_location_ids)
      end

      # GET /api/v1/plays/:id/leads?period=90&stage=replied&page=1
      def leads
        return unless authorize_action!('workflow_automation', 'read')
        return unless (installation = require_installation)

        render json: @play.leads_for(installation, period: params[:period], location_ids: visible_location_ids,
                                                   stage: params[:stage], page: params[:page] || 1,
                                                   per_page: params[:per_page] || 25)
      end

      # GET /api/v1/plays/:id/leads/:lead_id
      # One record's journey through the play, and where it is now. A lead,
      # unless the play follows another kind of record (a deal).
      def lead_journey
        return unless authorize_action!('workflow_automation', 'read')
        return unless (installation = require_installation)

        own_record = @play.respond_to?(:journey_record)
        record = own_record ? @play.journey_record(@company, params[:lead_id]) : @company.leads.find_by(id: params[:lead_id])
        journey = record && @play.lead_journey_for(installation, record, location_ids: visible_location_ids)
        unless journey
          return render(json: { error: "That #{own_record ? 'deal' : 'lead'} is not in this play." }, status: :not_found)
        end

        render json: journey
      end

      private

      def set_play
        @play = Plays::Registry.find(params[:id])
        render json: { error: 'Play not found' }, status: :not_found unless @play
      end

      def active_installation(play)
        PlayInstallation.active.find_by(company_id: @company.id, play_key: play::KEY)
      end

      def require_installation
        installation = active_installation(@play)
        render json: { error: "#{@play::NAME} is not on." }, status: :not_found unless installation
        installation
      end

      # Lead names and results follow the same location rules as every other
      # lead list: a location-tier user sees their locations, and the location
      # selector narrows further. nil means every location.
      def visible_location_ids
        location_ids = nil
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
        end
        if Current.location_filtered?
          location_ids = location_ids ? location_ids & [Current.location_id] : [Current.location_id]
        end
        location_ids
      end

      # Answers are validated and scoped to this company by the play itself;
      # ids that are not this company's are dropped there. Never a company_id.
      def answers_param
        raw = params[:answers]
        raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
        (raw || {}).to_h.slice('sources', 'reps_by_location', 'send_texts', 'content')
      end

      def play_json(play)
        installation = active_installation(play)
        play.definition(@company).merge(installation: installation && play.installation_json(installation))
      end
    end
  end
end

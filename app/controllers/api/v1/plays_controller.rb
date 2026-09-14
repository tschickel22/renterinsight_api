# frozen_string_literal: true

module Api
  module V1
    # Starter plays: bundles a dealer turns on with a few answers instead of
    # building each workflow, form and sequence by hand, then customizes.
    class PlaysController < ApplicationController
      include ModuleAccessRequired

      before_action :set_company_scope
      require_module! 'marketing.automation'
      before_action :set_play, only: [:show, :install, :customize, :uninstall]

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

        installation = active_installation(@play)
        return render(json: { error: "#{@play::NAME} is not on." }, status: :not_found) unless installation

        @play.new(company: @company, user: current_user, answers: answers_param, installation: installation).customize!
        render json: { play: play_json(@play) }
      rescue Plays::InstallError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/plays/:id/uninstall
      def uninstall
        return unless authorize_action!('workflow_automation', 'update')

        installation = active_installation(@play)
        return render(json: { error: "#{@play::NAME} is not on." }, status: :not_found) unless installation

        @play.uninstall!(installation)
        render json: { play: play_json(@play) }
      end

      private

      def set_play
        @play = Plays::Registry.find(params[:id])
        render json: { error: 'Play not found' }, status: :not_found unless @play
      end

      def active_installation(play)
        PlayInstallation.active.find_by(company_id: @company.id, play_key: play::KEY)
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

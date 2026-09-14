# frozen_string_literal: true

module Api
  module V1
    # Starter plays: bundles a dealer turns on with a few answers instead of
    # building each workflow, form and sequence by hand.
    class PlaysController < ApplicationController
      include ModuleAccessRequired

      before_action :set_company_scope
      require_module! 'marketing.automation'
      before_action :set_play, only: [:install, :uninstall]

      # GET /api/v1/plays
      def index
        return unless authorize_action!('workflow_automation', 'read')

        render json: { plays: Plays::Registry.all.map { |play| play_json(play) } }
      end

      # POST /api/v1/plays/:id/install
      def install
        return unless authorize_action!('workflow_automation', 'create')

        @play.new(company: @company, user: current_user, answers: answers_param).install!
        render json: { play: play_json(@play) }, status: :created
      rescue Plays::InstallError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/plays/:id/uninstall
      def uninstall
        return unless authorize_action!('workflow_automation', 'update')

        installation = PlayInstallation.active.find_by(company_id: @company.id, play_key: @play::KEY)
        return render(json: { error: "#{@play::NAME} is not on." }, status: :not_found) unless installation

        @play.uninstall!(installation)
        render json: { play: play_json(@play) }
      end

      private

      def set_play
        @play = Plays::Registry.find(params[:id])
        render json: { error: 'Play not found' }, status: :not_found unless @play
      end

      # Answers are validated and scoped to this company by the play itself;
      # ids that are not this company's are dropped there. Never a company_id.
      def answers_param
        raw = params[:answers]
        raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
        (raw || {}).to_h.slice('channels', 'reps_by_location', 'call_within_minutes', 'send_texts')
      end

      def play_json(play)
        installation = PlayInstallation.active.find_by(company_id: @company.id, play_key: play::KEY)
        play.definition(@company).merge(installation: installation && play.installation_json(installation))
      end
    end
  end
end

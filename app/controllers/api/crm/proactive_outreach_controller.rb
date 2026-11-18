# frozen_string_literal: true

module Api
  module Crm
    # Marketing, Proactive Outreach settings (backlog E105).
    class ProactiveOutreachController < ApplicationController
      before_action :set_company_scope

      def show
        return unless authorize_action!('company_settings', 'read')
        return unless outreach_allowed!

        render json: payload
      end

      def update
        return unless authorize_action!('company_settings', 'update')
        return unless outreach_allowed!

        attrs = params.require(:settings).permit(
          :enabled, :persona_name, :persona_title, :sender_user_id, :demo_minutes, :product_facts,
          playbook: %i[objection answer action share_hint]
        ).to_h
        attrs['playbook'] = [] if params[:settings].key?(:playbook) && params[:settings][:playbook].blank?
        settings.update!(attrs)
        render json: payload
      end

      # Fills an empty playbook with DealerTide's starter answers.
      def load_starter
        return unless authorize_action!('company_settings', 'update')
        return unless outreach_allowed!

        unless Outreach::StarterContent.available_for?(@company)
          return render(json: { error: 'No starter content is available for this company' }, status: :unprocessable_entity)
        end

        changes = {}
        changes['playbook'] = Outreach::StarterContent::PLAYBOOK if Array(settings['playbook']).empty?
        changes['product_facts'] = Outreach::StarterContent::PRODUCT_FACTS if settings['product_facts'].blank?
        settings.update!(changes) if changes.any?
        render json: payload
      end

      private

      def settings
        @settings ||= Outreach::Settings.for(@company)
      end

      def outreach_allowed!
        return true if settings.add_on?

        render json: { error: 'Proactive Outreach is not part of this subscription' }, status: :forbidden
        false
      end

      def payload
        {
          settings: settings.to_h,
          readiness: settings.readiness,
          starter_available: Outreach::StarterContent.available_for?(@company),
          demo_minutes_options: Outreach::Settings::DEMO_MINUTES,
          content: @company.outreach_content_items.where.not(status: 'archived').order(:status, :title).map { |item| Api::Crm::OutreachContentItemsController.item_json(item) },
          training_videos: TrainingVideo.published.where(share_enabled: true).order(:title).limit(200).map do |video|
            { id: video.id, title: video.title, url: Assistant::Software.watch_url(video) }
          end
        }
      end
    end
  end
end

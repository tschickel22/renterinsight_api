# frozen_string_literal: true

module Api
  module Crm
    # Marketing, Lead Assistant settings (backlog E96).
    class LeadAssistantSettingsController < ApplicationController
      before_action :set_company_scope

      def show
        return unless authorize_action!('company_settings', 'read')

        render json: payload
      end

      def update
        return unless authorize_action!('company_settings', 'update')

        settings = Assistant::Settings.for(@company)
        attrs = params.require(:settings).permit(
          :enabled, :assistant_name, :tone, :handoff_mode, :handoff_user_id, :extra_facts,
          :quiet_start_hour, :quiet_end_hour, :source_ids, :link_website_id, :auto_start, :goal,
          source_ids: [], faqs: %i[q a], chat_sites: []
        ).to_h
        # An emptied list arrives as no key at all.
        attrs['chat_sites'] = [] if params[:settings].key?(:chat_sites) && params[:settings][:chat_sites].blank?
        attrs['enabled'] = ActiveModel::Type::Boolean.new.cast(attrs['enabled']) if attrs.key?('enabled')
        if attrs['enabled'] && !settings.add_on?
          return render(json: { error: 'The Lead Assistant add-on is not on this account' }, status: :forbidden)
        end
        # The goal, name and answers also drive the website chat, so a dealer
        # with either add-on may change them.
        unless settings.add_on? || settings.chat_add_on?
          return render(json: { error: 'Quinn AI is not part of this subscription' }, status: :forbidden)
        end

        settings.update!(attrs)
        render json: payload
      end

      private

      def embed_code
        token = @company.public_inventory_token
        return nil if token.blank?

        base = (ENV['RAILS_API_URL'].presence || request.base_url).to_s.chomp('/')
        %(<script src="#{base}/chat/#{token}.js" async></script>)
      end

      def payload
        settings = Assistant::Settings.for(@company)
        own = TwilioAccount.active.where(company_id: @company.id).pluck(:phone_number)
        {
          settings: settings.to_h,
          # Published sites Quinn may link home pages from.
          websites: @company.websites.where(status: :published, is_deleted: [false, nil]).order(:name)
                            .map { |w| { id: w.id, name: w.name, url: (w.public_url rescue nil) } },
          add_on: settings.add_on?,
          # The website chat add-on (marketing.ai_concierge): Quinn in a chat on
          # the dealer's sites, and the line to put it on their own.
          chat: {
            add_on: settings.chat_add_on?,
            embed_code: settings.chat_add_on? ? embed_code : nil,
            sites: settings.chat_sites
          },
          texting: {
            own_numbers: own,
            pool_live: Assistant::Pool.live?,
            # What the assistant texts from today: the dealer's own number, the
            # shared number while theirs is pending, or nothing yet.
            sends_from: own.any? ? 'own' : (Assistant::Pool.live? ? 'pool' : 'none')
          }
        }
      end
    end
  end
end

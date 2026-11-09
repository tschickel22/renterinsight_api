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
          :texts_from, :cadence, :follow_up_channels, :use_website_text,
          :email_replies, :handoff_on_ready, :handoff_on_unknown, :handoff_after,
          :books_visits, :visit_minutes, :booking_notice_hours, :cold_texts,
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

        before = settings.cadence
        settings.update!(attrs)
        # A new follow-up plan applies to conversations already under way.
        if settings.cadence != before
          @company.conversations.where(status: 'active').find_each { |c| Assistant::FollowUp.schedule!(c) }
        end
        render json: payload
      end

      # Reads the dealer's own website (FAQs, About) with the site scanner.
      def read_site
        return unless authorize_action!('company_settings', 'update')

        settings = Assistant::Settings.for(@company)
        unless settings.add_on? || settings.chat_add_on?
          return render(json: { error: 'Quinn AI is not part of this subscription' }, status: :forbidden)
        end

        Assistant::Sources.read_site!(@company, params[:url].presence || settings.chat_sites.first, current_user)
        render json: payload
      rescue SiteProfiles::UrlGuard::BlockedUrlError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      # Everything Quinn AI already reads, as Quinn reads it, for the settings
      # page: so a dealer adds only what is missing.
      def knowledge
        facts = Concierge::Knowledge.new(website: nil, company: @company).to_h
        {
          company: { name: facts[:dealer_name], phone: facts[:phone], email: facts[:email], address: facts[:address],
                     hours: facts[:hours].present? },
          homes: { count: facts[:inventory_count], brands: facts[:manufacturers] },
          about: Assistant::Sources.about(@company),
          website_faqs: Assistant::Sources.website_faqs(@company),
          hosted_sites: Assistant::Sources.hosted_sites(@company).map(&:name),
          reading: Assistant::Sources.reading_status(@company)
        }
      rescue StandardError => e
        Rails.logger.warn("[LeadAssistantSettings] knowledge failed: #{e.class}: #{e.message}")
        {}
      end

      def texting_automations
        plays = @company.workflow_rules.where(status: 'active', entity_type: 'Lead').select do |rule|
          Array(rule.steps.to_h['nodes']).any? do |node|
            node['type'] == 'send_sms' && node.dig('config', 'to').to_s.match?(/\A\s*(\{\{\s*entity\.phone\s*\}\})?\s*\z/)
          end
        end
        nurtures = NurtureSequence.where(company_id: @company.id, is_active: true)
                                  .where(id: NurtureStep.where(step_type: 'sms').select(:nurture_sequence_id))
        plays.map { |r| { kind: 'play', id: r.id, name: r.name } } +
          nurtures.map { |n| { kind: 'nurture', id: n.id, name: n.name } }
      rescue StandardError => e
        Rails.logger.warn("[LeadAssistantSettings] automations lookup failed: #{e.message}")
        []
      end

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
          # Plays and nurtures that also text leads, so a dealer can see what
          # "Who texts new leads" decides between.
          texting_automations: texting_automations,
          follow_up_plans: Assistant::FollowUp::PLANS,
          knowledge: knowledge,
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

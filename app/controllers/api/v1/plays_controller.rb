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
      before_action :set_play, only: [:show, :install, :customize, :uninstall, :performance, :leads, :lead_journey, :start,
                                      :dismiss, :restore, :duplicate, :readiness]

      MAX_START_LEADS = 500

      # GET /api/v1/plays(?include_dismissed=true)
      # Offered plays, plus any retired play this company still has on. Plays the
      # company hid are left out unless asked for.
      def index
        return unless authorize_action!('workflow_automation', 'read')

        include_dismissed = ActiveModel::Type::Boolean.new.cast(params[:include_dismissed])
        plays = Plays::Registry.all_for(@company).select do |play|
          next false if play.hidden? && active_installation(play).nil?

          include_dismissed || !dismissed?(play)
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
        undismiss(@play)

        notices = []
        if @play.kind == 'lead_response' && ActiveModel::Type::Boolean.new.cast(params[:turn_on_weekly_homes])
          notices << turn_on_weekly_homes
        end
        render json: { play: play_json(@play), notices: notices.compact }, status: :created
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

      # POST /api/v1/plays/:id/uninstall  { remove: true }
      # Turning off always stops what the play started and keeps its history.
      # With remove, the play also leaves Starter Plays, and anything it built
      # that would still show elsewhere (a landing page) is deleted.
      def uninstall
        return unless authorize_action!('workflow_automation', 'update')
        return unless (installation = require_installation)

        @play.uninstall!(installation)
        if ActiveModel::Type::Boolean.new.cast(params[:remove])
          @play.remove_built!(installation) if @play.respond_to?(:remove_built!)
          dismiss_play!(@play)
        end
        render json: { play: play_json(@play) }
      end

      # POST /api/v1/plays/:id/dismiss
      # Hides a play that is off from Starter Plays, for this company.
      def dismiss
        return unless authorize_action!('workflow_automation', 'update')
        if active_installation(@play)
          return render json: { error: "Turn #{@play::NAME} off before hiding it." }, status: :unprocessable_entity
        end

        dismiss_play!(@play)
        render json: { play: play_json(@play) }
      end

      # GET /api/v1/plays/:id/readiness
      # What the play needs to work well, checked now, with where to fix each.
      def readiness
        return unless authorize_action!('workflow_automation', 'read')

        render json: Plays::Readiness.new(play: @play, company: @company, installation: active_installation(@play)).call
      end

      # POST /api/v1/plays/:id/duplicate  { name:, sources: [], start_tag: }
      # A copy of a lead response play for another channel ("New Google lead"),
      # starting from the original's current messages. It starts off; the dealer
      # sets it up like any other play.
      def duplicate
        return unless authorize_action!('workflow_automation', 'create')

        installation = active_installation(@play)
        content = installation ? @play.answers_for(installation)['content'] : @play.try(:default_content)
        base = (@play.respond_to?(:base_play) && @play.base_play) || @play
        copy = Plays::PlayCopy.create!(company: @company, user: current_user, base: base, name: params[:name],
                                       sources: params[:sources], start_tag: params[:start_tag], content: content)
        render json: { play: play_json(copy) }, status: :created
      rescue Plays::InstallError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/plays/:id/restore
      def restore
        return unless authorize_action!('workflow_automation', 'update')

        undismiss(@play)
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

      # POST /api/v1/plays/:id/start  { lead_ids: [...] }
      # Starts a play for leads a rep picked by adding the play's starting tag,
      # so they go through exactly what a tagged lead does. A lead that already
      # has the tag is not started again.
      def start
        return unless authorize_action!('leads', 'update')
        return unless (installation = require_installation)

        tag_name = @play.respond_to?(:start_tag_for) ? @play.start_tag_for(installation) : nil
        if tag_name.blank?
          return render json: { error: "#{@play::NAME} can't be started by hand." }, status: :unprocessable_entity
        end

        ids = Array(params[:lead_ids]).map(&:to_i).select(&:positive?).uniq
        return render(json: { error: 'Choose at least one lead.' }, status: :unprocessable_entity) if ids.empty?
        if ids.size > MAX_START_LEADS
          return render json: { error: "Start a play for up to #{MAX_START_LEADS} leads at a time." }, status: :unprocessable_entity
        end

        leads = @company.leads.where(id: ids)
        leads = leads.where(location_id: visible_location_ids) if visible_location_ids
        tag = @company.tags.find_or_create_by!(name: tag_name) do |t|
          t.color = '#0F766E'
          t.is_active = true
          t.is_system = false
        end
        already = TagAssignment.where(tag_id: tag.id, entity_type: 'Lead', entity_id: leads.select(:id)).pluck(:entity_id)

        started = 0
        leads.where.not(id: already).find_each do |lead|
          TagAssignment.create!(company_id: @company.id, tag: tag, entity_type: 'Lead', entity_id: lead.id,
                                assigned_by: current_user.id.to_s, assigned_at: Time.current)
          started += 1
        end

        render json: { started: started, already_started: already.size, not_found: ids.size - started - already.size, tag: tag.name }
      end

      private

      def dismissed?(play)
        @dismissed_keys ||= PlayInstallation.dismissed.where(company_id: @company.id).pluck(:play_key)
        @dismissed_keys.include?(play::KEY)
      end

      def dismiss_play!(play)
        PlayInstallation.find_or_create_by!(company_id: @company.id, play_key: play::KEY, status: 'dismissed')
        @dismissed_keys = nil
      end

      def undismiss(play)
        PlayInstallation.dismissed.where(company_id: @company.id, play_key: play::KEY).delete_all
        @dismissed_keys = nil
      end

      # A lead response play tags every lead for the weekly homes email, so setup
      # offers to turn that on in the same step. A notice either way; a failure
      # here must not undo the play that did turn on.
      def turn_on_weekly_homes
        weekly = Plays::WeeklyHomesEmail
        return nil if PlayInstallation.active.exists?(company_id: @company.id, play_key: weekly::KEY)

        weekly.new(company: @company, user: current_user, answers: {}).install!
        undismiss(weekly)
        "#{weekly::NAME} is on too."
      rescue Plays::InstallError => e
        "#{weekly::NAME} was not turned on: #{e.message}"
      end

      def set_play
        @play = Plays::Registry.find(params[:id], company: @company)
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
        (raw || {}).to_h.slice('sources', 'start_tag', 'reps_by_location', 'send_texts', 'content')
      end

      def play_json(play)
        installation = active_installation(play)
        play.definition(@company).merge(installation: installation && play.installation_json(installation),
                                        dismissed: dismissed?(play))
      end
    end
  end
end

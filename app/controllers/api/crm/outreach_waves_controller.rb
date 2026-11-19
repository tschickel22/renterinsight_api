# frozen_string_literal: true

module Api
  module Crm
    # Proactive Outreach waves: audience, review, start, pause and results
    # (backlog E105).
    class OutreachWavesController < ApplicationController
      before_action :set_company_scope
      before_action :set_wave, except: %i[index create]
      rescue_from(ActiveRecord::RecordNotFound) { render json: { error: 'Not found' }, status: :not_found }

      def index
        return unless authorize_action!('company_settings', 'read')
        return unless outreach_allowed!

        render json: { waves: @company.outreach_waves.order(created_at: :desc).limit(50).map { |wave| wave_json(wave) } }
      end

      def show
        return unless authorize_action!('company_settings', 'read')
        return unless outreach_allowed!
        return if performed?

        render json: { wave: wave_json(@wave), targets: @wave.outreach_targets.includes(lead: :source).order(:test_group, :rank).map { |target| target_json(target) } }
      end

      def create
        return unless authorize_action!('company_settings', 'update')
        return unless outreach_allowed!

        wave = @company.outreach_waves.build(wave_params)
        wave.name = wave.name.presence || "Wave #{Time.current.strftime('%b %-d')}"
        wave.created_by_user_id = current_user.id
        return render(json: { error: wave.errors.full_messages.to_sentence }, status: :unprocessable_entity) unless wave.save

        OutreachBuildWaveJob.perform_later(wave.id, current_user.id)
        render json: { wave: wave_json(wave) }, status: :created
      end

      # Leads that match the audience description but were left out, and why.
      def skipped
        return unless authorize_action!('company_settings', 'read')
        return unless outreach_allowed!
        return if performed?
        return render(json: { skipped: [], total: 0 }) if @wave.filter_tree.blank?

        chosen = @wave.outreach_targets.select(:lead_id)
        matching = Audiences::FilterCompiler.new(company: @company, source_type: 'Lead', filter_tree: @wave.filter_tree).scope.where.not(id: chosen)
        eligibility = Outreach::Eligibility.new(@company)
        leads = matching.order(updated_at: :desc).limit(200).to_a
        render json: {
          total: matching.count,
          can_add: ADDABLE.include?(@wave.status),
          skipped: leads.map do |lead|
            found = eligibility.skip_info(lead)
            info = found || { reason: ready_reason(lead), can_add: true }
            { lead_id: lead.id, name: lead.full_name.presence || lead.email, company_name: lead.company_name,
              reason: info[:reason], can_add: info[:can_add], ready: found.nil? }
          end
        }
      rescue Audiences::FilterCompiler::CompilationError => e
        render json: { skipped: [], total: 0, error: e.message }
      end

      # Adds left-out leads by hand. Soft rules (on a nurture, recently active,
      # not New) are overridden and recorded on the target; hard ones (no
      # consent, unsubscribed, an open Quinn conversation, a demo booked, another
      # live wave) still refuse. Added people are always contacted, not held back.
      def add_targets
        return unless authorize_action!('company_settings', 'update')
        return unless outreach_allowed!
        return if performed?
        unless ADDABLE.include?(@wave.status)
          return render(json: { error: 'People can be added only before the wave starts.' }, status: :unprocessable_entity)
        end

        eligibility = Outreach::Eligibility.new(@company)
        matching = Audiences::FilterCompiler.new(company: @company, source_type: 'Lead', filter_tree: @wave.filter_tree).scope
        ids = Array(params[:lead_ids]).map(&:to_i).uniq.first(200)
        added = []
        refused = []
        rank = @wave.outreach_targets.maximum(:rank).to_i
        matching.where(id: ids).where.not(id: @wave.outreach_targets.select(:lead_id)).find_each do |lead|
          info = eligibility.skip_info(lead)
          next refused << { lead_id: lead.id, reason: info[:reason] } if info && !info[:can_add]

          reach = eligibility.reach(lead)
          rank += 1
          @wave.outreach_targets.create!(
            company_id: @company.id, lead_id: lead.id, rank: rank, test_group: 'contact', channel: reach.email ? 'email' : 'text',
            ai_reason: 'Added by you',
            override_reason: info&.dig(:reason), overridden_by_user_id: (current_user.id if info)
          )
          added << lead.id
        end

        if added.any?
          case @wave.status
          when 'failed' then @wave.update!(status: 'audience_ready', build_error: nil)
          when 'review'
            @wave.update!(status: 'drafting')
            OutreachDraftOpenersJob.perform_later(@wave.id)
          end
        end
        render json: { added: added.size, refused: refused, wave: wave_json(@wave.reload) }
      rescue Audiences::FilterCompiler::CompilationError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # Takes a person out before messages are written.
      def remove_target
        return unless authorize_action!('company_settings', 'update')
        return unless outreach_allowed!
        return if performed?
        return render(json: { error: 'This wave has already started' }, status: :unprocessable_entity) if @wave.started_at

        @wave.outreach_targets.find(params[:target_id]).destroy!
        head :no_content
      end

      def draft
        return unless authorize_action!('company_settings', 'update')
        return unless outreach_allowed!
        return if performed?
        return render(json: { error: 'The audience is not ready' }, status: :unprocessable_entity) unless @wave.status == 'audience_ready'

        @wave.update!(status: 'drafting')
        OutreachDraftOpenersJob.perform_later(@wave.id)
        render json: { wave: wave_json(@wave) }
      end

      # Edit, approve or skip one opening message.
      def review_target
        return unless authorize_action!('company_settings', 'update')
        return unless outreach_allowed!
        return if performed?

        target = @wave.contacted.find(params[:target_id])
        return render(json: { error: 'This message has already gone out' }, status: :unprocessable_entity) unless %w[drafted approved skipped].include?(target.status)

        target.assign_attributes(params.require(:target).permit(:draft_body, :draft_subject).to_h)
        target.draft_body = Assistant::Rules.tidy(target.draft_body) if target.draft_body_changed?
        case params.dig(:target, :decision).to_s
        when 'approve'
          problem = Outreach::Guard.violation(target.draft_body, channel: target.channel, lead: target.lead)
          return render(json: { error: "This message cannot be approved: #{problem}" }, status: :unprocessable_entity) if problem

          target.assign_attributes(status: 'approved', approved_by_user_id: current_user.id, approved_at: Time.current, draft_error: nil)
        when 'skip' then target.status = 'skipped'
        when 'unapprove' then target.status = 'drafted'
        end
        target.save!
        render json: { target: target_json(target) }
      end

      def start
        return unless authorize_action!('company_settings', 'update')
        return unless outreach_allowed!
        return if performed?
        return render(json: { error: 'Review the messages first' }, status: :unprocessable_entity) unless @wave.status == 'review'

        settings = Outreach::Settings.for(@company)
        missing = settings.readiness.reject { |_, ready| ready }.keys
        return render(json: { error: "Finish setup first: #{missing.join(', ').tr('_', ' ')}" }, status: :unprocessable_entity) if missing.any?
        return render(json: { error: 'Approve or skip every message first' }, status: :unprocessable_entity) if @wave.contacted.where(status: 'drafted').exists?
        return render(json: { error: 'Approve at least one message' }, status: :unprocessable_entity) unless @wave.contacted.where(status: 'approved').exists?

        settings.update!('enabled' => true)
        @wave.update!(status: 'running', started_at: Time.current, pause_reason: nil)
        render json: { wave: wave_json(@wave) }
      end

      def pause
        return unless authorize_action!('company_settings', 'update')
        return unless outreach_allowed!
        return if performed?

        @wave.update!(status: 'paused', paused_at: Time.current, pause_reason: 'Paused by you') if @wave.status == 'running'
        render json: { wave: wave_json(@wave) }
      end

      def resume
        return unless authorize_action!('company_settings', 'update')
        return unless outreach_allowed!
        return if performed?

        if @wave.status == 'paused'
          Outreach::Settings.for(@company).update!('enabled' => true)
          @wave.update!(status: 'running', pause_reason: nil)
        end
        render json: { wave: wave_json(@wave) }
      end

      def results
        return unless authorize_action!('company_settings', 'read')
        return unless outreach_allowed!
        return if performed?

        render json: { wave: wave_json(@wave) }.merge(Outreach::Results.new(@wave).to_h)
      end

      private

      def outreach_allowed!
        return true if Outreach::Settings.for(@company).add_on?

        render json: { error: 'Proactive Outreach is not part of this subscription' }, status: :forbidden
        false
      end

      ADDABLE = %w[failed audience_ready review].freeze

      # Nothing rules this lead out now: say why they are not in the wave.
      def ready_reason(lead)
        if [lead.created_at, lead.updated_at].compact.max > @wave.created_at
          'Ready to contact. Added or changed after this audience was built'
        else
          "Ready to contact. Not picked because the wave was full at #{@wave.target_size} contacted and #{@wave.target_size} held back"
        end
      end

      def set_wave
        @wave = @company.outreach_waves.find(params[:id])
      end

      def wave_params
        params.require(:wave).permit(:name, :prompt, :target_size, :daily_limit)
      end

      def wave_json(wave)
        wave.as_json(only: %i[id name status prompt target_size daily_limit eligible_count pause_reason build_error started_at created_at]).merge(
          'contact_count' => wave.contacted.count, 'holdout_count' => wave.held_back.count,
          'approved_count' => wave.contacted.where(status: 'approved').count, 'drafted_count' => wave.contacted.where(status: 'drafted').count
        )
      end

      def target_json(target)
        lead = target.lead
        item = target.draft_content_item_id && @company.outreach_content_items.find_by(id: target.draft_content_item_id)
        target.as_json(only: %i[id lead_id test_group status rank ai_reason channel draft_subject draft_body draft_error stop_reason override_reason]).merge(
          'name' => Assistant::Learn.display_name(lead), 'company' => lead.company_name, 'state' => lead.state, 'source' => lead.source&.name,
          'video_title' => item&.title
        )
      end
    end
  end
end

# frozen_string_literal: true

module Api
  module V1
    class ToursController < ApplicationController
      before_action :authenticate_user!
      before_action :require_platform_admin!, only: %i[create update destroy approve unapprove]
      before_action :require_admin_or_checker!, only: %i[for_check check_results]
      before_action :set_tour, only: %i[show start complete step_complete dismiss]
      before_action :set_tour_for_admin, only: %i[update destroy check_results approve unapprove]

      # GET /api/v1/tours
      # Lists active tours the current user hasn't completed yet.
      def index
        # Global master switch: when paused, end users get no tours. Platform
        # admins still do, so the tours can be tested and fixed while paused.
        paused = PlatformSetting.tours_paused?
        return render(json: { tours: [], tours_paused: true }) if paused && !platform_admin_request?

        completions = current_user.user_tour_completions.index_by(&:tour_id)
        completed_ids = completions.values.select(&:completed?).map(&:tour_id)

        # Dealers only get tours a person has played and approved; admins see
        # the rest too, flagged, so they can test and approve them.
        base = platform_admin_request? ? Tour.active : Tour.active.approved
        scope = params[:include_completed] == 'true' ? base : base.where.not(id: completed_ids)
        scope = scope.where(knowledge_module_id: Knowledge::Module.find_by!(key: params[:module]).id) if params[:module].present?

        tours = scope.ordered.includes(:knowledge_module, :steps).map { |t| tour_payload(t, completion: completions[t.id]) }
        render json: { tours: tours, tours_paused: paused }
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'module not found' }, status: :not_found
      end

      # GET /api/v1/tours/pause_state
      # Returns whether tours are globally paused. Any authenticated user may read.
      def pause_state
        render json: { tours_paused: PlatformSetting.tours_paused? }
      end

      # PATCH /api/v1/tours/pause_state  body: { paused: true|false }
      # Master switch — platform admin only.
      def set_pause_state
        return unless require_platform_admin!

        PlatformSetting.tours_paused = ActiveModel::Type::Boolean.new.cast(params[:paused])
        render json: { ok: true, tours_paused: PlatformSetting.tours_paused? }
      end

      # GET /api/v1/tours/:id
      def show
        completion = current_user.user_tour_completions.find_by(tour_id: @tour.id)
        render json: tour_payload(@tour, include_steps: true, completion: completion)
      end

      # POST /api/v1/tours/:id/start
      def start
        return render(json: { ok: true, recorded: false }) if impersonating?

        completion = UserTourCompletion.find_or_initialize_by(user: current_user, tour: @tour)
        completion.steps_completed ||= {}
        completion.save!
        render json: { ok: true, completion_id: completion.id, started_at: completion.updated_at }
      end

      # POST /api/v1/tours/:id/complete
      def complete
        return render(json: { ok: true, recorded: false }) if impersonating?

        completion = UserTourCompletion.find_or_initialize_by(user: current_user, tour: @tour)
        completion.steps_completed ||= {}
        completion.completed_at = Time.current
        completion.save!
        render json: { ok: true, completed_at: completion.completed_at }
      end

      # POST /api/v1/tours/:id/step_complete
      # body: { step_position: 3 }
      def step_complete
        position = params[:step_position].to_i
        return render json: { error: 'step_position required' }, status: :bad_request if position <= 0
        return render(json: { ok: true, recorded: false }) if impersonating?

        completion = UserTourCompletion.find_or_initialize_by(user: current_user, tour: @tour)
        completion.steps_completed ||= {}
        completion.steps_completed[position.to_s] = { 'completed_at' => Time.current.iso8601 }
        # Auto-finalize when every step is done. Only positions that still exist
        # count, so a tour edited down to fewer steps cannot finish early.
        positions = @tour.steps.pluck(:position).map(&:to_s)
        total = positions.size
        done = (completion.steps_completed.keys & positions).size
        completion.completed_at ||= Time.current if total.positive? && done >= total
        completion.save!

        render json: {
          ok: true,
          steps_completed: done,
          total_steps:     total,
          completed_at:    completion.completed_at
        }
      end

      # POST /api/v1/tours/:id/dismiss
      # The user closed the tour early or declined the "take the tour" prompt.
      # It stops being offered automatically but stays in their tour list, and
      # it is not counted as a completion.
      def dismiss
        return render(json: { ok: true, recorded: false }) if impersonating?

        completion = UserTourCompletion.find_or_initialize_by(user: current_user, tour: @tour)
        completion.steps_completed ||= {}
        completion.dismissed_at ||= Time.current
        completion.save!
        render json: { ok: true, dismissed_at: completion.dismissed_at }
      end

      # GET /api/v1/tours/for_check
      # Every active tour with its steps as stored, for the tour check (the
      # nightly run or an admin), whether or not tours are paused.
      def for_check
        tours = Tour.active.ordered.includes(:steps)
        render json: { tours: tours.map { |t| { id: t.id, key: t.key, name: t.name, steps: t.steps.map { |s|
          { position: s.position, route: s.route, selector: s.selector, click_required: s.click_required }
        } } } }
      end

      # POST /api/v1/tours/:id/approve
      # A platform admin played the tour and it teaches the task.
      def approve
        @tour.update!(approved_at: Time.current, approved_by_id: original_user&.id)
        render json: { ok: true, approved_at: @tour.approved_at }
      end

      # POST /api/v1/tours/:id/unapprove
      def unapprove
        @tour.update!(approved_at: nil, approved_by_id: nil)
        render json: { ok: true, approved_at: nil }
      end

      # POST /api/v1/tours/:id/check_results  { results: [{ position, status }] }
      # What a check of the tour against the live app found for each step:
      # found, missing or ambiguous. Platform admins run it from Knowledge admin.
      def check_results
        now = Time.current
        Array(params[:results]).each do |r|
          status = r[:status].to_s
          next unless %w[found missing ambiguous].include?(status)

          @tour.steps.where(position: r[:position].to_i).update_all(check_status: status, checked_at: now)
        end
        failing = @tour.steps.where(check_status: %w[missing ambiguous]).exists?
        @tour.update_columns(checked_at: now, check_status: failing ? 'failing' : 'passing')
        render json: { ok: true, check_status: @tour.check_status, checked_at: @tour.checked_at }
      end

      # POST /api/v1/tours
      # Body: { tour: { key, name, description, module_key, trigger_type,
      #                 trigger_route, is_active, position,
      #                 steps: [{ position, route, selector, title, content,
      #                           placement, highlight_type,
      #                           click_required, input_required }] } }
      # Used by the Tour Recorder frontend to persist a newly-authored tour.
      def create
        attrs = tour_attrs_from_params
        tour  = Tour.new(attrs.except(:module_key, :steps))
        tour.knowledge_module_id = resolve_module_id(attrs[:module_key]) if attrs[:module_key].present?

        if tour.save
          rebuild_steps(tour, attrs[:steps])
          render json: tour_payload(tour, include_steps: true), status: :created
        else
          render json: { errors: tour.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/tours/:id
      # Body shape identical to create. Steps are always fully replaced when
      # the :steps key is present (simpler + avoids position-uniqueness pain).
      def update
        attrs = tour_attrs_from_params
        @tour.knowledge_module_id = resolve_module_id(attrs[:module_key]) if attrs[:module_key].present?

        # New steps are a new tour as far as approval goes: play it again.
        @tour.approved_at = nil if attrs.key?(:steps)
        if @tour.update(attrs.except(:module_key, :steps))
          rebuild_steps(@tour, attrs[:steps]) if attrs.key?(:steps)
          render json: tour_payload(@tour.reload, include_steps: true)
        else
          render json: { errors: @tour.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/tours/:id
      # Soft-delete: flips is_active to false so the tour disappears from the
      # user-facing API without losing history or step-completion data.
      def destroy
        @tour.update!(is_active: false)
        render json: { ok: true, id: @tour.id, is_active: @tour.is_active }
      end

      private

      def require_admin_or_checker!
        return true if platform_admin_request? || Guide::Checker.user?(current_user)

        render json: { error: 'Forbidden' }, status: :forbidden
        false
      end

      def platform_admin_request?
        admin = original_user
        admin&.platform_admin? || admin&.super_admin?
      end

      # ?raw=true (platform admins only) returns the stored copy with its
      # {{brand}} tokens intact, so the recorder saves them back unchanged.
      # The company being viewed (a platform admin switched into a dealer sees
      # that dealer's words), not necessarily the person's own.
      def copy_company
        return @copy_company if defined?(@copy_company)

        @copy_company = ::Company.find_by(id: current_company_id) || current_user&.company
      end

      def copy(text)
        return text if params[:raw] == 'true' && platform_admin_request?

        Guide::Copy.render(text, company: copy_company)
      end

      def set_tour
        # Platform admins can open an inactive tour to test or edit it.
        scope = platform_admin_request? ? Tour.all : Tour.active.approved
        @tour = scope.find_by(id: params[:id])
        render json: { error: 'tour not found' }, status: :not_found unless @tour
      end

      # Admin-side set_tour — includes inactive tours so platform admins can
      # edit or undelete a soft-deleted tour.
      def set_tour_for_admin
        @tour = Tour.find_by(id: params[:id])
        render json: { error: 'tour not found' }, status: :not_found unless @tour
      end

      def tour_attrs_from_params
        params.require(:tour).permit(
          :key, :name, :description, :module_key, :trigger_type,
          :trigger_route, :is_active, :position,
          steps: [
            :position, :route, :selector, :title, :content,
            :placement, :highlight_type, :click_required, :input_required
          ]
        ).to_h.deep_symbolize_keys
      end

      # Resolve module_key directly or via alias table. Returns id or nil.
      def resolve_module_id(key)
        mod = Knowledge::Module.find_by(key: key) ||
              Knowledge::Module.find_by(key: key.to_s.sub(/s\z/, '')) ||
              Knowledge::EntityAlias.find_by(alias_name: key.to_s)&.then { |a|
                Knowledge::Module.find_by(key: a.canonical_key)
              }
        mod&.id
      end

      # Delete-and-recreate. Cheaper than diffing and keeps position uniqueness
      # trivially satisfied. Only called when the request actually supplied steps.
      def rebuild_steps(tour, steps_data)
        return if steps_data.blank?

        tour.steps.destroy_all
        steps_data.each_with_index do |sd, idx|
          tour.steps.create!(
            position:       sd[:position] || (idx + 1),
            route:          sd[:route],
            selector:       sd[:selector],
            title:          sd[:title],
            content:        sd[:content],
            placement:      sd[:placement]       || 'bottom',
            highlight_type: sd[:highlight_type]  || 'outline',
            click_required: sd[:click_required] == true,
            input_required: sd[:input_required] == true
          )
        end
      end

      def tour_payload(tour, include_steps: false, completion: nil)
        payload = {
          id:           tour.id,
          key:          tour.key,
          name:         copy(tour.name),
          description:  copy(tour.description),
          position:     tour.position,
          trigger_type:  tour.trigger_type,
          trigger_route: tour.trigger_route,
          module:        tour.knowledge_module&.key,
          category:      tour.knowledge_module&.category,
          step_count:   tour.steps.size,
          approved:     tour.approved_at.present?,
          completed:    !!completion&.completed_at,
          dismissed:    !!completion&.dismissed_at,
          started:      completion.present?
        }
        if include_steps
          payload[:steps] = tour.steps.ordered.map do |s|
            {
              position:       s.position,
              selector:       s.selector,
              title:          copy(s.title),
              content:        copy(s.content),
              placement:      s.placement,
              highlight_type: s.highlight_type,
              click_required: s.click_required,
              input_required: s.input_required,
              route:          s.route
            }
          end
        end
        payload
      end
    end
  end
end

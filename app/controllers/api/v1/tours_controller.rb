# frozen_string_literal: true

module Api
  module V1
    class ToursController < ApplicationController
      before_action :authenticate_user!
      before_action :require_platform_admin!, only: %i[create update destroy]
      before_action :set_tour, only: %i[show start complete step_complete]
      before_action :set_tour_for_admin, only: %i[update destroy]

      # GET /api/v1/tours
      # Lists active tours the current user hasn't completed yet.
      def index
        # Global master switch: when paused, serve no tours to end users.
        return render(json: { tours: [], tours_paused: true }) if PlatformSetting.tours_paused?

        completed_ids = current_user.user_tour_completions
                                    .where.not(completed_at: nil)
                                    .pluck(:tour_id)

        scope = params[:include_completed] == 'true' ? Tour.active : Tour.active.where.not(id: completed_ids)
        scope = scope.where(knowledge_module_id: Knowledge::Module.find_by!(key: params[:module]).id) if params[:module].present?

        tours = scope.ordered.includes(:knowledge_module).map { |t| tour_payload(t) }
        render json: { tours: tours }
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
        completion = UserTourCompletion.find_or_initialize_by(user: current_user, tour: @tour)
        completion.steps_completed ||= {}
        completion.save!
        render json: { ok: true, completion_id: completion.id, started_at: completion.updated_at }
      end

      # POST /api/v1/tours/:id/complete
      def complete
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

        completion = UserTourCompletion.find_or_initialize_by(user: current_user, tour: @tour)
        completion.steps_completed ||= {}
        completion.steps_completed[position.to_s] = { completed_at: Time.current.iso8601 }
        # Auto-finalize when every step is done.
        total = @tour.steps.count
        completion.completed_at = Time.current if completion.steps_completed.keys.size >= total
        completion.save!

        render json: {
          ok: true,
          steps_completed: completion.steps_completed.keys.size,
          total_steps:     total,
          completed_at:    completion.completed_at
        }
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

      def set_tour
        @tour = Tour.active.find_by(id: params[:id])
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
          name:         tour.name,
          description:  tour.description,
          position:     tour.position,
          trigger_type:  tour.trigger_type,
          trigger_route: tour.trigger_route,
          module:        tour.knowledge_module&.key,
          category:      tour.knowledge_module&.category,
          step_count:   tour.steps.size,
          completed:    !!completion&.completed_at,
          started:      completion.present?
        }
        if include_steps
          payload[:steps] = tour.steps.ordered.map do |s|
            {
              position:       s.position,
              selector:       s.selector,
              title:          s.title,
              content:        s.content,
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

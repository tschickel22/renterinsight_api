# frozen_string_literal: true

module Api
  module V1
    class ToursController < ApplicationController
      before_action :authenticate_user!
      before_action :set_tour, only: %i[show start complete step_complete]

      # GET /api/v1/tours
      # Lists active tours the current user hasn't completed yet.
      def index
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

      private

      def set_tour
        @tour = Tour.active.find_by(id: params[:id])
        render json: { error: 'tour not found' }, status: :not_found unless @tour
      end

      def tour_payload(tour, include_steps: false, completion: nil)
        payload = {
          id:           tour.id,
          key:          tour.key,
          name:         tour.name,
          description:  tour.description,
          trigger_type:  tour.trigger_type,
          trigger_route: tour.trigger_route,
          module:        tour.knowledge_module&.key,
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

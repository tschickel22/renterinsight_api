# frozen_string_literal: true

module Api
  module V1
    # Settings, Training (E88): a company admin requires training videos of
    # their people, picks the ones every new user gets, and sees who is done.
    class TrainingAssignmentsController < ApplicationController
      before_action :set_company_scope
      before_action :require_admin!

      # GET /api/v1/training_assignments
      def index
        videos = TrainingVideo.published.ordered.to_a
        users = @company.users.where(status: 'active').order(:first_name, :last_name).to_a
        assignments = TrainingAssignment.where(company_id: @company.id, user_id: users.map(&:id)).to_a
        views = TrainingVideoView.where(user_id: users.map(&:id), training_video_id: videos.map(&:id))
                                 .index_by { |v| [v.user_id, v.training_video_id] }
        render json: {
          enabled: TrainingVideo.enabled?,
          videos: videos.map { |v| v.as_api_json.slice(:id, :title, :module_key, :duration_seconds, :poster_url) },
          new_user_video_ids: TrainingAssignment.new_user_video_ids(@company.id) & videos.map(&:id),
          users: users.map do |u|
            {
              id: u.id, name: [u.first_name, u.last_name].compact.join(' ').presence || u.email, email: u.email,
              assignments: assignments.select { |a| a.user_id == u.id }.map do |a|
                view = views[[u.id, a.training_video_id]]
                { id: a.id, video_id: a.training_video_id, due_on: a.due_on, source: a.source,
                  completed_at: view&.completed_at, furthest_seconds: view&.furthest_seconds.to_i }
              end
            }
          end
        }
      end

      # POST /api/v1/training_assignments  { user_ids: [], video_ids: [], due_on }
      def create
        users = @company.users.where(id: Array(params[:user_ids]))
        videos = TrainingVideo.published.where(id: Array(params[:video_ids]))
        due_on = (Date.parse(params[:due_on].to_s) rescue nil)
        count = 0
        users.each do |u|
          videos.each do |v|
            a = TrainingAssignment.find_or_initialize_by(user_id: u.id, training_video_id: v.id)
            a.assign_attributes(company_id: @company.id, assigned_by_id: current_user.id, due_on: due_on)
            count += 1 if a.new_record?
            a.save!
          end
        end
        render json: { assigned: count }
      end

      # DELETE /api/v1/training_assignments/:id
      def destroy
        assignment = TrainingAssignment.where(company_id: @company.id).find_by(id: params[:id])
        return render(json: { error: 'Not found' }, status: :not_found) unless assignment

        assignment.destroy!
        head :no_content
      end

      # PUT /api/v1/training_assignments/new_users  { video_ids: [] }
      def new_users
        ids = TrainingVideo.published.where(id: Array(params[:video_ids])).pluck(:id)
        Setting.set('Company', @company.id, TrainingAssignment::NEW_USER_SETTING, ids)
        render json: { new_user_video_ids: ids }
      end

      private

      # Who can open the Settings tabs company admins manage (settingsTabs 'manage').
      def require_admin!
        return if current_user&.effective_admin? || current_user&.role == 'manager'

        render json: { error: 'Only company admins can manage training' }, status: :forbidden
      end
    end
  end
end

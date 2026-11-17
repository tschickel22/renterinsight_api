# frozen_string_literal: true

module Api
  module V1
    # "Share quote details with installers" on a project (ProjectQuoteDetails).
    class ProjectQuoteDetailsController < ApplicationController
      before_action :set_company_scope
      before_action :set_project

      # GET /api/v1/projects/:project_id/quote_details
      def show
        return unless authorize_action!('projects', 'read')

        render json: ProjectQuoteDetails.new(@project).status
      end

      # POST /api/v1/projects/:project_id/quote_details  (on, or remake)
      def create
        return unless authorize_action!('projects', 'update')

        service = ProjectQuoteDetails.new(@project, user: current_user)
        service.enable!
        render json: ProjectQuoteDetails.new(@project).status, status: :created
      rescue ProjectQuoteDetails::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # DELETE /api/v1/projects/:project_id/quote_details  (off)
      def destroy
        return unless authorize_action!('projects', 'update')

        ProjectQuoteDetails.new(@project, user: current_user).disable!
        render json: ProjectQuoteDetails.new(@project).status
      end

      private

      def set_project
        @project = @company.projects.find(params[:project_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end
    end
  end
end

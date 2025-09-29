module Api
  module Crm
    class LeadTasksController < ApplicationController
      before_action :set_lead

      def create
        t = @lead.lead_tasks.create!(task_params)
        render json: task_json(t), status: :created
      end

      def update
        t = @lead.lead_tasks.find(params[:id])
        t.update!(task_params)
        render json: task_json(t)
      end

      def destroy
        t = @lead.lead_tasks.find(params[:id])
        t.destroy!
        head :no_content
      end

      private

      def set_lead
        @lead = Lead.find(params[:lead_id])
      end

      def task_params
        p = params.permit(:title, :dueAt, :done)
        {
          title: p[:title],
          due_at: p[:dueAt],
          done: ActiveModel::Type::Boolean.new.cast(p[:done])
        }.compact
      end

      def task_json(t)
        { id: t.id, title: t.title, dueAt: t.due_at, done: t.done }
      end
    end
  end
end

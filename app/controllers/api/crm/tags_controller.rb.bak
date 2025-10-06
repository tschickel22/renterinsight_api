module Api
  module Crm
    class TagsController < ApplicationController
      before_action :set_tag, only: [:update, :destroy]

      def index
        tags = Tag.active.order(:name)
        render json: tags.map { |t| tag_json(t) }
      end

      def create
        tag = Tag.new(tag_params)
        tag.created_by = current_user&.id&.to_s || 'system'
        
        if tag.save
          render json: tag_json(tag), status: :created
        else
          render json: { errors: tag.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        if @tag.update(tag_params)
          render json: tag_json(@tag)
        else
          render json: { errors: @tag.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        @tag.destroy!
        head :no_content
      end

      def assign
        tag = Tag.find(params[:tag_id])
        assignment = TagAssignment.new(
          tag: tag,
          entity_type: params[:entity_type],
          entity_id: params[:entity_id],
          assigned_by: current_user&.id&.to_s || 'system',
          assigned_at: Time.current
        )
        
        if assignment.save
          render json: assignment_json(assignment), status: :created
        else
          render json: { errors: assignment.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def remove_assignment
        assignment = TagAssignment.find(params[:id])
        assignment.destroy!
        head :no_content
      end

      def entity_tags
        entity_type = params[:entity_type]
        entity_id = params[:entity_id]
        
        assignments = TagAssignment.includes(:tag).for_entity(entity_type, entity_id)
        tags = assignments.map(&:tag)
        
        render json: tags.map { |t| tag_json(t) }
      end

      private

      def set_tag
        @tag = Tag.find(params[:id])
      end

      def tag_params
        p = params.require(:tag).permit(
          :name, :description, :color, :category, :is_active, :is_system, type: []
        )
        
        {
          name: p[:name],
          description: p[:description],
          color: p[:color] || '#6B7280',
          category: p[:category],
          tag_type: p[:type] || [],
          is_active: p[:is_active].nil? ? true : p[:is_active],
          is_system: p[:is_system] || false
        }.compact
      end

      def tag_json(tag)
        {
          id: tag.id,
          name: tag.name,
          description: tag.description,
          color: tag.color,
          category: tag.category,
          type: tag.tag_type,
          isSystem: tag.is_system,
          isActive: tag.is_active,
          usageCount: tag.usage_count,
          createdBy: tag.created_by,
          createdAt: tag.created_at,
          updatedAt: tag.updated_at
        }.compact
      end

      def assignment_json(assignment)
        {
          id: assignment.id,
          tagId: assignment.tag_id,
          entityType: assignment.entity_type,
          entityId: assignment.entity_id,
          assignedBy: assignment.assigned_by,
          assignedAt: assignment.assigned_at
        }.compact
      end
    end
  end
end

module Api
  module Crm
    class TagsController < ApplicationController
      before_action :set_tag, only: [:update, :destroy]

      # ---------- Tag catalog ----------
      def index
        scope = Tag.respond_to?(:active) ? Tag.active : Tag.all
        render json: scope.order(:name).map { |t| tag_json(t) }
      end

      def create
        tag_data = params[:tag] || params
        tag = Tag.new(
          name:        tag_data[:name],
          description: tag_data[:description],
          color:       tag_data[:color].presence || '#6B7280',
          category:    tag_data[:category],
          tag_type:    tag_data[:type] || [],
          is_active:   tag_data.key?(:is_active) ? tag_data[:is_active] : true,
          is_system:   tag_data[:is_system] || false,
          created_by:  current_user&.id&.to_s || 'system'
        )
        if tag.save
          render json: tag_json(tag), status: :created
        else
          render json: { errors: tag.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        tag_data = params[:tag] || params
        updates = {
          name:        tag_data[:name],
          description: tag_data[:description],
          color:       tag_data[:color],
          category:    tag_data[:category],
          tag_type:    tag_data[:type],
          is_active:   tag_data[:is_active],
          is_system:   tag_data[:is_system]
        }.compact
        if @tag.update(updates)
          render json: tag_json(@tag)
        else
          render json: { errors: @tag.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        @tag.destroy!
        head :no_content
      end

      # ---------- Generic entity endpoints ----------
      def assign
        entity = resolve_entity!(params)
        tag    = resolve_tag!(params)
        a = TagAssignment.find_or_create_by!(tag: tag, entity_type: entity[:type], entity_id: entity[:id]) do |rec|
          rec.assigned_by = current_user&.id&.to_s || 'system'
          rec.assigned_at = Time.current
        end
        render json: assignment_json(a), status: :created
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def remove_assignment
        if params[:id]
          TagAssignment.find(params[:id]).destroy!
        else
          entity = resolve_entity!(params)
          tag    = resolve_tag!(params)
          TagAssignment.where(tag_id: tag.id, entity_type: entity[:type], entity_id: entity[:id]).delete_all
        end
        head :no_content
      end

      def entity_tags
        entity = resolve_entity!(params)
        assignments = TagAssignment.includes(:tag).for_entity(entity[:type], entity[:id])
        render json: assignments.map(&:tag).map { |t| tag_json(t) }
      end

      # ---------- Lead-scoped wrappers ----------
      def entity_tags_for_lead
        params[:lead_id] ||= params[:id]
        entity_tags
      end

      def assign_to_lead
        params[:lead_id] ||= params[:id]
        assign
      end

      def remove_from_lead
        params[:lead_id] ||= params[:id]
        params[:tag_id]  ||= params[:tagId]
        remove_assignment
      end

      private

      def set_tag
        @tag = Tag.find(params[:id])
      end

      # Normalize entity inputs and classify the type ("lead" -> "Lead")
      def resolve_entity!(p)
        lead_id = p[:lead_id] || p[:leadId] || p[:id]
        return { type: 'Lead', id: lead_id.to_i } if lead_id

        etype = p[:entity_type] || p[:entityType]
        eid   = p[:entity_id]   || p[:entityId]
        return { type: etype.to_s.classify, id: eid.to_i } if etype && eid

        raise ArgumentError, "Missing entity (lead_id or entity_type/entity_id)"
      end

      def resolve_tag!(p)
        tag_id = p[:tag_id] || p[:tagId] || (p[:tag].is_a?(Hash) && (p[:tag][:id] || p[:tag]['id'])) || p[:id]
        name   = p[:name] || (p[:tag].is_a?(Hash) && (p[:tag][:name] || p[:tag]['name']))
        return Tag.find(tag_id) if tag_id.present?
        return Tag.where('LOWER(name)=?', name.downcase).first || Tag.create!(name: name, color: '#6B7280', is_active: true, created_by: current_user&.id&.to_s || 'system') if name.present?
        raise ArgumentError, "Provide tag_id or name"
      end

      def tag_json(tag)
        {
          id:          tag.id,
          name:        tag.name,
          description: tag.description,
          color:       tag.color,
          category:    tag.category,
          type:        tag.try(:tag_type),
          isSystem:    tag.try(:is_system),
          isActive:    tag.try(:is_active),
          usageCount:  (tag.respond_to?(:usage_count) ? tag.usage_count : 0),
          createdBy:   tag.try(:created_by),
          createdAt:   tag.created_at,
          updatedAt:   tag.updated_at
        }.compact
      end

      def assignment_json(a)
        {
          id:         a.id,
          tagId:      a.tag_id,
          entityType: a.entity_type,
          entityId:   a.entity_id,
          assignedBy: a.assigned_by,
          assignedAt: a.assigned_at
        }.compact
      end
    end
  end
end

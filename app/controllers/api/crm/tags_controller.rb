# Tags are now company-scoped for proper multi-tenant isolation

module Api
  module Crm
    class TagsController < ApplicationController
      include RbacAuthorization
      rbac_resource :crm,
        read_actions: [:index, :entity_tags, :entity_tags_for_lead, :analytics],
        create_actions: [:create, :assign, :assign_to_lead],
        update_actions: [:update],
        delete_actions: [:destroy, :remove_assignment, :remove_from_lead]

      before_action :set_company_scope
      before_action :set_tag, only: [:update, :destroy, :analytics]

      # ---------- Tag catalog ----------
      def index
        # Company-scoped tags (includes company tags + global tags with nil company_id)
        # Eager load tag_assignments to calculate usage_count efficiently
        scope = Tag.for_company(@company.id).includes(:tag_assignments)
        scope = scope.active if Tag.respond_to?(:active)
        render json: scope.order(:name).map { |t| tag_json(t) }
      end

      def create
        tag_data = params[:tag] || params
        # Normalize tag_type: ensure it's always an array
        raw_type = tag_data[:type] || tag_data[:entityType] || tag_data[:tag_type]
        tag_type_arr = case raw_type
                       when Array then raw_type
                       when String then raw_type.present? ? [raw_type] : []
                       else []
                       end

        # Try find_or_create to handle unique constraint gracefully
        tag = @company.tags.find_by(name: tag_data[:name]&.strip)
        if tag
          # Tag exists — update attributes if needed and return it
          tag.update(
            color:     tag_data[:color].presence || tag.color,
            is_active: tag_data.key?(:is_active) ? tag_data[:is_active] : tag.is_active
          )
          render json: tag_json(tag), status: :ok
          return
        end

        tag = @company.tags.new(
          name:        tag_data[:name]&.strip,
          description: tag_data[:description],
          color:       tag_data[:color].presence || '#6B7280',
          category:    tag_data[:category],
          tag_type:    tag_type_arr,
          is_active:   tag_data.key?(:is_active) ? tag_data[:is_active] : true,
          is_system:   tag_data[:is_system] || false,
          created_by:  current_user&.id&.to_s || 'system'
        )
        if tag.save
          render json: tag_json(tag), status: :created
        else
          render json: { errors: tag.errors.full_messages }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotUnique
        # Race condition: tag was created between find_by and save
        tag = @company.tags.find_by!(name: tag_data[:name]&.strip)
        render json: tag_json(tag), status: :ok
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

      # ---------- Analytics ----------
      def analytics
        # Get all assignments for this tag
        assignments = TagAssignment.where(tag_id: @tag.id)
        
        # Calculate entity breakdown
        entity_breakdown = {}
        assignments.group(:entity_type).count.each do |entity_type, count|
          # Normalize entity type to lowercase (Lead -> lead)
          normalized_type = entity_type.to_s.downcase
          entity_breakdown[normalized_type] = count
        end
        
        # Calculate trend data (last 30 days)
        start_date = 30.days.ago.beginning_of_day
        trend_data = (0..29).map do |days_ago|
          date = start_date + days_ago.days
          count = assignments.where('assigned_at >= ? AND assigned_at <= ?', date.beginning_of_day, date.end_of_day).count
          {
            date: date.to_date.iso8601,
            count: count
          }
        end
        
        # Get top tagged entities (limit to 10)
        top_entities = []
        assignments.order(assigned_at: :desc).limit(10).each do |assignment|
          begin
            entity = find_entity_by_type_and_id(assignment.entity_type, assignment.entity_id)
            if entity
              top_entities << {
                entityId: assignment.entity_id,
                entityName: entity_display_name(entity),
                entityType: assignment.entity_type.to_s.downcase
              }
            end
          rescue => e
            Rails.logger.error("Failed to fetch entity #{assignment.entity_type}##{assignment.entity_id}: #{e.message}")
            # Skip this entity and continue
          end
        end
        
        render json: {
          tagId: @tag.id.to_s,
          tagName: @tag.name,
          totalUsage: assignments.count,
          entityBreakdown: entity_breakdown,
          trendData: trend_data,
          topEntities: top_entities
        }
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
      
      # ---------- Account-scoped wrappers ----------
      def entity_tags_for_account
        params[:account_id] ||= params[:id]
        entity_tags
      end

      def assign_to_account
        params[:account_id] ||= params[:id]
        assign
      end

      def remove_from_account
        params[:account_id] ||= params[:id]
        params[:tag_id]  ||= params[:tagId]
        remove_assignment
      end
      
      # ---------- Contact-scoped wrappers ----------
      def entity_tags_for_contact
        params[:contact_id] ||= params[:id]
        entity_tags
      end

      def assign_to_contact
        params[:contact_id] ||= params[:id]
        assign
      end

      def remove_from_contact
        params[:contact_id] ||= params[:id]
        params[:tag_id]  ||= params[:tagId]
        remove_assignment
      end

      private

      def set_company_scope
        unless current_user
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        company_id = current_company_id
        
        unless company_id.present?
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
      end

      def set_tag
        # Company-scoped tags (includes company tags + global tags)
        @tag = Tag.for_company(@company.id).find_by(id: params[:id])
        unless @tag
          render json: { error: 'Tag not found or access denied' }, status: :not_found
          return
        end
      end

      # Normalize entity inputs and classify the type ("lead" -> "Lead")
      def resolve_entity!(p)
        # Check for specific entity ID params first
        lead_id = p[:lead_id] || p[:leadId]
        return { type: 'Lead', id: lead_id.to_i } if lead_id
        
        account_id = p[:account_id] || p[:accountId]
        return { type: 'Account', id: account_id.to_i } if account_id
        
        contact_id = p[:contact_id] || p[:contactId]
        return { type: 'Contact', id: contact_id.to_i } if contact_id
        
        # Fallback to generic entity_type/entity_id
        etype = p[:entity_type] || p[:entityType]
        eid   = p[:entity_id]   || p[:entityId] || p[:id]
        return { type: etype.to_s.classify, id: eid.to_i } if etype && eid

        raise ArgumentError, "Missing entity (lead_id, account_id, contact_id, or entity_type/entity_id)"
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
          usageCount:  tag.usage_count,
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
      
      def find_entity_by_type_and_id(entity_type, entity_id)
        # Ensure entity_id is an integer for queries
        id = entity_id.to_i
        return nil if id.zero?
        
        case entity_type.to_s
        when 'Lead'
          # Leads don't have is_deleted column - just check company
          Lead.where(company_id: @company.id).find_by(id: id)
        when 'Account'
          Account.where(company_id: @company.id, is_deleted: [false, nil]).find_by(id: id)
        when 'Contact'
          Contact.where(company_id: @company.id, is_deleted: [false, nil]).find_by(id: id)
        when 'Deal'
          # Deals use deleted_at for soft deletes
          Deal.where(company_id: @company.id, deleted_at: nil).find_by(id: id)
        when 'Quote'
          Quote.where(company_id: @company.id).find_by(id: id)
        when 'Inventory', 'Vehicle'
          Vehicle.where(company_id: @company.id, is_deleted: [false, nil]).find_by(id: id)
        else
          Rails.logger.warn("Unknown entity type for tag analytics: #{entity_type}")
          nil
        end
      rescue => e
        Rails.logger.error("Error finding entity #{entity_type}##{entity_id}: #{e.message}")
        nil
      end
      
      def entity_display_name(entity)
        case entity
        when Lead
          name = [entity.first_name, entity.last_name].compact.join(' ').presence
          name || entity.email.presence || entity.phone.presence || "Lead ##{entity.id}"
        when Account
          entity.name.presence || entity.company_name.presence || "Account ##{entity.id}"
        when Contact
          name = [entity.first_name, entity.last_name].compact.join(' ').presence
          name || entity.email.presence || "Contact ##{entity.id}"
        when Deal
          # Deal has 'name' and 'customer_name' columns
          entity.name.presence || entity.customer_name.presence || "Deal ##{entity.id}"
        when Quote
          "Quote ##{entity.quote_number || entity.id}"
        when Vehicle
          [entity.year, entity.make, entity.model].compact.join(' ').presence || "Vehicle ##{entity.id}"
        else
          "##{entity.id}"
        end
      rescue => e
        Rails.logger.error("Error getting entity display name: #{e.message}")
        "Unknown ##{entity.id rescue 'N/A'}"
      end
    end
  end
end

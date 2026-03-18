# frozen_string_literal: true

module Api
  module V1
    class OfflineSyncController < ApplicationController
      before_action :set_company_scope

      # POST /api/v1/offline_sync
      def create
        return unless authorize_action!('projects', 'update')

        operations = params[:operations]
        device_id = params[:device_id]

        unless operations.is_a?(Array) && operations.any?
          return render json: { error: 'operations array required' }, status: :bad_request
        end

        sync_log = OfflineSyncLog.create!(
          company: @company,
          user: current_user,
          device_id: device_id,
          sync_status: 'processing',
          total_operations: operations.count,
          started_at: Time.current
        )

        results = []
        successful = 0
        failed = 0

        operations.each_with_index do |op, idx|
          begin
            result = process_operation(op)
            results << { index: idx, status: 'success', result: result }
            successful += 1
          rescue => e
            results << { index: idx, status: 'failed', error: e.message }
            failed += 1
            Rails.logger.error("[OfflineSync] Operation #{idx} failed: #{e.message}")
          end
        end

        sync_log.update!(
          sync_status: 'completed',
          successful_operations: successful,
          failed_operations: failed,
          operations: results,
          completed_at: Time.current
        )

        render json: {
          syncLogId: sync_log.id,
          total: operations.count,
          successful: successful,
          failed: failed,
          results: results
        }
      end

      private

      def process_operation(op)
        action = op['action']
        entity_type = op['entity_type']
        entity_id = op['entity_id']
        data = op['data'] || {}
        offline_timestamp = op['timestamp']

        case "#{entity_type}:#{action}"
        when 'task:update_status'
          task = @company.project_tasks.find(entity_id)
          if offline_timestamp && task.updated_at < Time.parse(offline_timestamp)
            task.update!(status: data['status'])
          end
          { id: task.id, status: task.status }

        when 'task:update_hours'
          task = @company.project_tasks.find(entity_id)
          task.update!(actual_hours: data['actual_hours'])
          { id: task.id, actual_hours: task.actual_hours }

        when 'checklist_item:toggle'
          item = ProjectTaskChecklistItem.joins(project_task_checklist: { project_task: :company })
            .where(companies: { id: @company.id })
            .find(entity_id)
          item.completed_by = current_user unless item.completed?
          item.toggle!
          { id: item.id, completed: item.completed }

        when 'task:add_note'
          task = @company.project_tasks.find(entity_id)
          existing_meta = task.metadata || {}
          notes = existing_meta['notes'] || []
          notes << {
            text: data['note'],
            author_id: current_user.id,
            timestamp: offline_timestamp || Time.current.iso8601
          }
          task.update!(metadata: existing_meta.merge('notes' => notes))
          { id: task.id, notes_count: notes.count }

        when 'task:add_photo'
          task = @company.project_tasks.find(entity_id)
          existing_meta = task.metadata || {}
          photos = existing_meta['offline_photos'] || []
          photos << {
            data: data['photo_base64'],
            filename: data['filename'],
            content_type: data['content_type'],
            captured_at: offline_timestamp || Time.current.iso8601,
            author_id: current_user.id
          }
          task.update!(metadata: existing_meta.merge('offline_photos' => photos))
          { id: task.id, photos_count: photos.count }

        when 'phase:update_status'
          phase = ProjectPhase.joins(:project)
            .where(projects: { company_id: @company.id })
            .find(entity_id)
          phase.update!(status: data['status'])
          { id: phase.id, status: phase.status }

        else
          raise "Unknown operation: #{entity_type}:#{action}"
        end
      end
    end
  end
end

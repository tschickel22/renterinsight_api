# frozen_string_literal: true

module ImportExport
  # Reverses an ImportJob within the rollback window:
  #   - destroys records this job created
  #   - restores updated records to their pre-import attribute snapshots
  class RollbackService
    class NotRollbackable < StandardError; end

    def initialize(import_job)
      @job     = import_job
      @company = import_job.company
    end

    def rollback!
      raise NotRollbackable, 'Job is not rollbackable' unless @job.can_rollback?

      cfg = ModuleRegistry.config_for(@job.module_type)
      raise NotRollbackable, "Unknown module: #{@job.module_type}" unless cfg

      scope = @company.public_send(cfg[:scope])
      destroyed = 0
      restored  = 0

      ActiveRecord::Base.transaction do
        if @job.created_record_ids.is_a?(Array) && @job.created_record_ids.any?
          scope.where(id: @job.created_record_ids).find_each do |record|
            record.destroy!
            destroyed += 1
          end
        end

        if @job.updated_record_snapshots.is_a?(Array) && @job.updated_record_snapshots.any?
          @job.updated_record_snapshots.each do |snap|
            record = scope.find_by(id: snap['id'] || snap[:id])
            next unless record
            before = snap['before'] || snap[:before] || {}
            record.update!(before)
            restored += 1
          end
        end

        @job.update!(status: 'rolled_back')
      end

      { destroyed: destroyed, restored: restored }
    end
  end
end

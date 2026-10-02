# frozen_string_literal: true

module McpTools
  # Projects (home setup and installation jobs): tools, prompts, and how Undo
  # reverses what those tools changed. See ProjectSupport for the two kinds of
  # work a project holds.
  module ProjectArea
    READ_TOOLS = [ListProjects, GetProject, ListProjectTasks].freeze
    WRITE_TOOLS = [UpdateProjectTask, CreateProjectTask].freeze
    PROMPTS = [McpPrompts::ProjectStatus, McpPrompts::MyProjectTasks].freeze

    TASK_UNDO_FIELDS = %w[title status due_date assigned_to_id priority].freeze

    module_function

    def handles?(record)
      record.is_a?(ProjectTask) || record.is_a?(ProjectPhaseTask)
    end

    def label(record_type)
      { 'ProjectTask' => 'project task', 'ProjectPhaseTask' => 'project phase step' }[record_type]
    end

    # A task the AI added is removed the way the app deletes one (soft
    # delete), but only while nobody has worked it.
    def undo_created(change, record)
      return Undo.skipped('This kind of record cannot be undone automatically.') unless record.is_a?(ProjectTask)
      return Undo.skipped('The task was already deleted.') if record.is_deleted

      current = UpdateProjectTask.serialize(record.attributes.slice(*change.after.keys))
      unless Undo.same_value?(current, change.after)
        return Undo.skipped('Someone has worked this task since it was added. Remove it in DealerTide if it should go.')
      end

      record.update!(is_deleted: true)
      Undo.done('Project task removed.')
    end

    def undo_updated(change, record)
      fields = change.after.keys
      current = UpdateProjectTask.serialize(record.attributes.slice(*fields))
      moved = fields.find { |f| !Undo.same_value?(current[f], change.after[f]) }
      if moved
        return Undo.skipped("Changed again since: #{moved.tr('_', ' ').sub(/ id\z/, '')} is now " \
                            "#{current[moved].inspect}. Left as it is.")
      end

      restore = change.before.slice(*fields)
      if record.is_a?(ProjectPhaseTask) && restore['status'] == 'pending' && record.status == 'completed'
        record.reopen!
        restore = restore.except('status', 'completed_at', 'completed_by_id')
      end
      record.update!(restore) if restore.any?

      notes = []
      notes << 'The customer was already notified and that cannot be recalled.' if change.before['_customer_notified']
      notes << 'The phase it started stays in progress; change it on the project if needed.' if change.before['_started_phase']
      Undo.done(["#{label(record.class.name).capitalize} restored.", *notes].join(' '))
    end
  end
end

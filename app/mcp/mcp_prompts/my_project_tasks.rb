# frozen_string_literal: true

module McpPrompts
  class MyProjectTasks < Base
    prompt_name 'my_project_tasks'
    title 'My project work this week'
    description 'Project tasks and checklist steps assigned to me that are overdue or due this week.'

    def self.text_for(_args)
      <<~TEXT
        Call list_project_tasks with assigned="me" and overdue_only=true, then again with assigned="me" and due_within_days=7.
        List what is overdue first, then what is due this week, grouped by project, with the phase each item belongs to.
        If nothing is assigned to me, say so and offer to show the open work on my projects instead (list_projects with owner="me").
        Offer to mark items done or move a due date, and only do it if I say yes.
      TEXT
    end
  end
end

# frozen_string_literal: true

module McpPrompts
  class ProjectStatus < Base
    prompt_name 'project_status'
    title 'Where every project stands'
    description 'Every active setup project: current phase, what is late, and who owns it.'

    def self.text_for(_args)
      <<~TEXT
        Show me where every active project stands. Call list_projects, then list_projects with behind_schedule=true.
        For each project give one line: customer, home, current phase, percent done, owner, and the next due date.
        Call get_project on any that are behind or have overdue items, and say which phase or step is late and by how many days.
        If a project has no estimated dates, say that it cannot be judged as late rather than calling it on time.
        Finish with the three projects that need attention first and why. Include each project's link.
        Do not change anything.
      TEXT
    end
  end
end

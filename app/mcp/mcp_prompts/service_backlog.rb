# frozen_string_literal: true

module McpPrompts
  class ServiceBacklog < Base
    prompt_name 'service_backlog'
    title 'Service backlog'
    description 'Open service tickets by priority, the ones waiting longest, and what is blocking them.'

    def self.text_for(_args)
      <<~TEXT
        Review the open service tickets. Call list_service_tickets for each priority, urgent first.
        List the urgent and high ones, the ones waiting on parts or the manufacturer, and anything open longer than 30 days.
        Fetch the oldest few to read their notes, and say what is blocking each and who should act.
      TEXT
    end
  end
end

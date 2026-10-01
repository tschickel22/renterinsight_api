# frozen_string_literal: true

module McpPrompts
  class CustomerFollowUp < Base
    prompt_name 'customer_follow_up'
    title 'Follow up with a customer'
    description 'Everything we know about one customer, and a follow-up message ready to send.'
    arguments [MCP::Prompt::Argument.new(name: 'customer', description: 'Name, email or phone', required: true)]

    def self.text_for(args)
      name = (args[:customer] || args['customer']).to_s.strip.first(100)
      <<~TEXT
        Look up #{name.presence || 'this customer'} with search, then fetch the best match (ask me if more than one fits).
        Summarize who they are, what they want, where they are in the process and our last few touches.
        Draft a short follow-up message in a friendly, professional tone that moves them one step forward.
        #{NO_DASHES}
        Then offer to create a follow-up task or add a note, and only do it if I say yes.
      TEXT
    end
  end
end

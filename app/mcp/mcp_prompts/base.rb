# frozen_string_literal: true

module McpPrompts
  # Ready-made requests a dealer picks from the prompt menu in Claude or
  # ChatGPT (the "cookbook"). A prompt is only text handed to the AI: every
  # record it then reads still goes through the tools and the user's own
  # permissions, so a prompt cannot reach anything the user could not.
  #
  # Anything the AI drafts for a customer must not use em or en dashes
  # (CLAUDE.md, WRITING STYLE), so every prompt that drafts says so.
  class Base < MCP::Prompt
    NO_DASHES = 'When you draft anything a customer will read, write plainly and never use em dashes or en dashes.'

    class << self
      def template(args, server_context: nil)
        MCP::Prompt::Result.new(
          description: description_value,
          messages: [MCP::Prompt::Message.new(role: 'user', content: MCP::Content::Text.new(text_for(args || {})))]
        )
      end

      def days(args, key, default)
        value = args[key.to_sym] || args[key.to_s]
        value.to_s.match?(/\A\d+\z/) ? value.to_i.clamp(1, 365) : default
      end
    end
  end
end

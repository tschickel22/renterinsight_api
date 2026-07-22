# frozen_string_literal: true

# AiModel — single source of truth for which Claude model each class of AI work
# uses. Keyed by ROLE, not call site, so a whole class of work can be re-pointed
# at once (e.g. a future Sonnet 5 migration) instead of a 20-file sweep.
#
# Per-environment override via ENV, no deploy needed beyond the Render restart
# an ENV change already triggers: AI_MODEL_GENERATION=claude-sonnet-5, etc.
module AiModel
  DEFAULTS = {
    classification: 'claude-sonnet-4-6',
    generation:     'claude-sonnet-4-6',
    refine:         'claude-haiku-4-5-20251001',
    vision:         'claude-sonnet-4-6',
    analysis:       'claude-sonnet-4-6'
  }.freeze

  def self.for(role)
    role = role.to_sym
    raise ArgumentError, "unknown AI model role: #{role}" unless DEFAULTS.key?(role)

    ENV.fetch("AI_MODEL_#{role.to_s.upcase}") { DEFAULTS[role] }
  end
end

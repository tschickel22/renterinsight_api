# frozen_string_literal: true

module Deals
  # Rewrites every deal's stored probability from the company's current
  # pipeline stages. A deal's probability is derived from its stage
  # (Deal#sync_probability_from_stage), but only when the stage changes, so
  # editing a stage's % in Settings, Pipeline left the stored values stale and
  # the forecast and the probability sort read old numbers.
  #
  # One update_all per stage, only for stages the pipeline has, only rows that
  # differ. Deals whose stage the pipeline does not know are left alone.
  # Deleted deals are skipped. Safe to run any number of times. Callbacks and
  # updated_at are deliberately untouched: this is a recalculation, not an edit.
  class ProbabilitySync
    def initialize(company)
      @company = company
    end

    # Returns the number of deals changed.
    def call
      changed = 0
      @company.pipeline_stage_keys.uniq.each do |key|
        prob = @company.pipeline_stage_probability(key)
        next if prob.nil?

        changed += @company.deals
                           .where(deleted_at: nil, stage: key)
                           .where('probability IS DISTINCT FROM ?', prob)
                           .update_all(probability: prob)
      end
      changed
    end
  end
end

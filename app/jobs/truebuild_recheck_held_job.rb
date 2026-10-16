# frozen_string_literal: true

# Judges held-back drawings again without drawing them again
# (Truebuild::Trueview::Recheck). Started by hand for a factory's held work.
class TruebuildRecheckHeldJob < ApplicationJob
  queue_as :low
  limits_concurrency to: 1, key: 'truebuild-recheck-held', duration: 3.hours

  def perform(render_ids, budget_usd)
    tally = Truebuild::Trueview::Recheck.call(TruebuildRender.where(id: render_ids), budget_usd: budget_usd.to_f)
    Rails.logger.info("[TrueView] recheck held: #{tally.to_json}")
  end
end

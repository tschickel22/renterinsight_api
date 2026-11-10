class ExpireAgreementsJob < ApplicationJob
  queue_as :default

  def perform
    expired_count = 0

    Agreement.expired_unprocessed.find_each do |agreement|
      # expire! fires agreement.expired through Agreement#trigger_webhooks.
      # This used to call WebhookService.trigger, which does not exist, so the
      # job raised after the first agreement it expired.
      expired_count += 1 if agreement.expire!
    end

    Rails.logger.info("[ExpireAgreementsJob] Expired #{expired_count} agreements")
  end
end

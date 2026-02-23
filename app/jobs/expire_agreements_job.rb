class ExpireAgreementsJob < ApplicationJob
  queue_as :default

  def perform
    expired_count = 0

    Agreement.expired_unprocessed.find_each do |agreement|
      agreement.expire!
      expired_count += 1

      # Trigger webhook
      if defined?(WebhookService)
        WebhookService.trigger(
          company: agreement.company,
          event: 'agreement.expired',
          payload: agreement.as_json(only: [:id, :title, :agreement_number, :status, :expires_at])
        )
      end
    end

    Rails.logger.info("[ExpireAgreementsJob] Expired #{expired_count} agreements")
  end
end

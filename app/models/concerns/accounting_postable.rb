# frozen_string_literal: true

# Mixin for models that should auto-post a GL journal entry on create.
# Not yet included in Invoice or Payment — wire it in only after the
# posting services have been smoke-tested manually.

module AccountingPostable
  extend ActiveSupport::Concern

  included do
    after_commit :post_to_gl, on: [:create], if: :should_auto_post_to_gl?
  end

  private

  def should_auto_post_to_gl?
    respond_to?(:company) && company&.accounting_settings.present?
  end

  def post_to_gl
    case self.class.name
    when 'Invoice'
      Accounting::InvoicePostingService.new(self).post!
    when 'Payment'
      Accounting::PaymentPostingService.new(self).post!
    end
  rescue => e
    Rails.logger.error("[Accounting] Auto-post failed for #{self.class.name}##{id}: #{e.message}")
    Rails.logger.error(e.backtrace.first(5).join("\n"))
  end
end

# frozen_string_literal: true

# Keeps an approved deal's books and invoice in step with edits (E78 step 7).
#
# Approval posts what the deal is worth; the deal's invoice bills it. An edit
# after that (a product added, a price or cost changed) used to change the
# deal only, so the ledger and the invoice kept the approval-day figures.
# Around an edit to a posted deal this posts the difference (the same entry a
# change order posts) and recalculates the invoice and its unpaid draws. When
# the difference can't be posted (a closed period), the edit is undone and
# the request answers with why.
module PostedDealChanges
  extend ActiveSupport::Concern

  private

  # Use as an around_action. `posted_deal` is the deal the action edits.
  def keep_posted_deal_in_step
    deal = posted_deal
    unless deal&.gl_posted?
      yield
      return
    end

    before = Accounting::DealAccountingService.new(deal).posting_lines
    failure = nil
    ActiveRecord::Base.transaction do
      yield
      next unless response.successful?

      deal.reload
      # nil when the edit moved no money (notes, dates): nothing to post, and
      # the invoice is left alone.
      adjustment = Accounting::DealAccountingService.new(deal)
                   .post_change_adjustment!(before: before, memo: 'Deal changed after approval', user: current_user)
      invoice = deal.company.invoices.find_by(id: deal.deal_invoice_id) if adjustment && deal.deal_invoice_id
      if invoice
        DealInvoiceService.new(deal, user: current_user).sync_invoice!(invoice)
        invoice.reload.update_status_based_on_payments
        DealInvoiceService.refresh_draws!(invoice.reload)
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      failure = e.message
      raise ActiveRecord::Rollback
    end
    return unless failure

    response.status = :unprocessable_entity
    response.body = { error: "This deal is approved, and the change could not be posted to the books (#{failure}). Nothing was changed." }.to_json
    response.content_type = 'application/json'
  end
end

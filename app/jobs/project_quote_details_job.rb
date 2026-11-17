# frozen_string_literal: true

# A quote's items changed: remake the installer scope sheet on its projects.
class ProjectQuoteDetailsJob < ApplicationJob
  queue_as :default

  def perform(quote_id)
    quote = Quote.find_by(id: quote_id)
    ProjectQuoteDetails.quote_changed(quote) if quote
  end
end

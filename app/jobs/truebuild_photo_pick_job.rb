# frozen_string_literal: true

# Claude picks a model's kitchen, bath and exterior photos for TrueView, then
# the model's layers are drawn on them (Truebuild::Trueview::PhotoChoice).
class TruebuildPhotoPickJob < ApplicationJob
  queue_as :low

  def perform(company_id, variant_id)
    company = Company.find_by(id: company_id)
    variant = CatalogPlanVariant.find_by(id: variant_id)
    return unless company && variant

    Truebuild::Trueview::PhotoChoice.pick!(variant)
    Truebuild::Trueview::Buyer.new(company, variant.reload).predraw!(force: true)
  end
end

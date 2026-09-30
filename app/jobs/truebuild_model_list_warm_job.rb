# frozen_string_literal: true

# Prices a dealer's Design Your Home model list ahead of the first buyer
# (Truebuild::ModelList), after their rules, terms or price books change.
class TruebuildModelListWarmJob < ApplicationJob
  queue_as :low

  def perform(company_id)
    company = Company.find_by(id: company_id)
    Truebuild::ModelList.new(company).call if company
  end
end

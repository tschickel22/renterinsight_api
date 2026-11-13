# frozen_string_literal: true

# Brings a company's stored deal probabilities in line with its pipeline
# stages after the stages are saved (Settings, Pipeline). See
# Deals::ProbabilitySync.
class DealProbabilitySyncJob < ApplicationJob
  queue_as :default

  def perform(company_id)
    company = Company.find_by(id: company_id)
    return unless company

    Deals::ProbabilitySync.new(company).call
  end
end

# frozen_string_literal: true

module Plays
  # The starter plays, by key. Hidden plays are no longer offered but stay
  # registered so an install that is already on can be managed.
  module Registry
    def self.all
      [Plays::NewFacebookLead, Plays::WalkInVisit, Plays::PromoLandingPage, Plays::WeeklyHomesEmail, Plays::WakeUpColdLeads,
       Plays::DealToSold, Plays::NewLeadAnyChannel]
    end

    def self.offered
      all.reject(&:hidden?)
    end

    # Every play a company can see: the catalog, plus the company's own copies.
    def self.all_for(company)
      all + Plays::PlayCopy.all(company&.id)
    end

    # A copy belongs to one company, so finding one needs the company (a
    # Company or its id). Catalog plays are found without it.
    def self.find(key, company: nil)
      if Plays::PlayCopy.copy_key?(key)
        company_id = company.respond_to?(:id) ? company.id : company
        return Plays::PlayCopy.find(company_id, key)
      end

      all.find { |play| play::KEY == key.to_s }
    end
  end
end

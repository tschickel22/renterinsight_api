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

    def self.find(key)
      all.find { |play| play::KEY == key.to_s }
    end
  end
end

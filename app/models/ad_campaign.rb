# frozen_string_literal: true

class AdCampaign < ApplicationRecord
  belongs_to :company

  validates :external_campaign_id, presence: true

  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :for_status, ->(status) { where(status: status) }

  # Recompute leads_count / deals_count / revenue / cost metrics from our own
  # attribution data + the cached Meta spend/impressions. Safe to call often.
  def calculate_roi!
    matched_leads = matched_leads_scope
    self.leads_count = matched_leads.count

    converted_account_ids = matched_leads.where(is_converted: true)
                                         .where.not(converted_account_id: nil)
                                         .pluck(:converted_account_id).uniq

    if converted_account_ids.any?
      deals = Deal.where(account_id: converted_account_ids)
      self.deals_count = deals.count
      self.revenue     = deals.where(stage: 'closed_won').sum(:value)
    else
      self.deals_count = 0
      self.revenue     = 0
    end

    self.cost_per_lead  = leads_count.positive? ? (spend.to_f / leads_count).round(2) : 0
    self.cost_per_deal  = deals_count.positive? ? (spend.to_f / deals_count).round(2) : 0
    self.roi_percentage = spend.to_f.positive? ? (((revenue.to_f - spend.to_f) / spend.to_f) * 100).round(2) : 0

    save!
  end

  private

  # Leads are attributed to this campaign when either their utm_campaign
  # matches the human-readable name, OR their utm_content matches the Meta
  # campaign id (which we also auto-tag on scheduled posts).
  def matched_leads_scope
    company.leads
           .where('utm_campaign = :n OR utm_content = :e', n: name.to_s, e: external_campaign_id.to_s)
  end
end

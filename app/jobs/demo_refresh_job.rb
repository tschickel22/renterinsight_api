# frozen_string_literal: true

# Keeps each staging demo account's Workqueue warm overnight, for the person
# who last pressed "Refresh demo data" there. Does nothing where
# DEMO_REFRESH_COMPANY_IDS is unset, which is everywhere but staging.
class DemoRefreshJob < ApplicationJob
  queue_as :low

  def perform
    DemoRefresh.company_ids.each do |company_id|
      company = Company.find_by(id: company_id)
      next unless DemoRefresh.available?(company)

      user = User.find_by(id: DemoRefresh.last_user_id(company))
      next unless user

      DemoRefresh.new(company: company, user: user).call
    rescue => e
      Rails.logger.error "[DemoRefreshJob] company=#{company_id} failed: #{e.message}"
    end
  end
end

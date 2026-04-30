class CampaignGoalCheckJob < ApplicationJob
  queue_as :default

  def perform
    Campaign.running.find_each do |c|
      Campaigns::GoalChecker.new(campaign: c).run
    end
  end
end

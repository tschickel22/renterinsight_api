# frozen_string_literal: true

# Runs every Proactive Outreach wave that is under way (backlog E105).
class OutreachTickJob < ApplicationJob
  queue_as :low

  def perform
    Outreach::WaveRunner.run_all
  end
end

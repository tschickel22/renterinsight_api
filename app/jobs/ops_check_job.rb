# frozen_string_literal: true

# Every few minutes (config/recurring.yml): Ops::Watch.check!.
class OpsCheckJob < ApplicationJob
  queue_as :default

  def perform
    Ops::Watch.check!
  end
end

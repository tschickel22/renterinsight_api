# frozen_string_literal: true

# Turns off a home's sale once its end date has passed (Vehicle.expire_sales!).
class ExpireSalePricesJob < ApplicationJob
  queue_as :low

  def perform
    Vehicle.expire_sales!
  end
end

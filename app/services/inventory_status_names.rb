# frozen_string_literal: true

# What a dealer calls each inventory status (Company Settings, Customize,
# Labels). Only the words change: vehicles.status keeps its stored value, so
# filters, feeds, rules and the API never see the dealer's wording.
class InventoryStatusNames
  def initialize(company)
    @labels = company&.resolved_labels || {}
  end

  def for(status)
    return nil if status.blank?

    @labels["status_#{status}"].presence || status.to_s.titleize
  end
end

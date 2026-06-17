# frozen_string_literal: true

# When a deal is marked closed_won on a specific vehicle ("home"), every OTHER
# open deal on that same vehicle has lost the home. Notify the rep on each of
# those losing deals so they reach out to their customer to choose a new one.
#
# In-app by default; reps opt into email/SMS via the per-type notification
# preference (home_sold_choose_new_home). One notification per losing deal.
class NotifyHomeSoldOtherDealsService
  # Canonical list of "still open" pipeline stages.
  OPEN_STAGES = Reports::InventoryDealQuery::OPEN_STAGES

  def self.call(won_deal)
    new(won_deal).call
  end

  def initialize(won_deal)
    @won_deal = won_deal
  end

  def call
    return unless @won_deal.vehicle_id.present?

    vehicle_label = build_vehicle_label(@won_deal.vehicle)

    losing_deals.find_each do |losing|
      recipient = losing.owner || losing.primary_salesperson
      next if recipient.nil?

      NotificationService.create(
        recipient: recipient,
        notification_type: :home_sold_choose_new_home,
        notifiable: losing,
        actor: Current.user,
        message: build_message(vehicle_label, losing.customer_display_name),
        deliver_now: true,
        company_id: losing.company_id,
        location_id: losing.location_id
      )
    end
  end

  private

  def losing_deals
    Deal.where(vehicle_id: @won_deal.vehicle_id)
        .where(stage: OPEN_STAGES)
        .where.not(id: @won_deal.id)
        .where(deleted_at: nil)
        .includes(:owner, :primary_salesperson)
  end

  def build_vehicle_label(vehicle)
    return 'home' if vehicle.nil?

    ymm = "#{vehicle.year} #{vehicle.make} #{vehicle.model}".strip
    ymm.presence || vehicle.stock_number.presence || vehicle.serial_number.presence || 'home'
  end

  def build_message(vehicle_label, customer)
    "The #{vehicle_label} on #{customer}'s deal was just sold to another buyer. " \
      "#{customer} will need to choose a new home."
  end
end

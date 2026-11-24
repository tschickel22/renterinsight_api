# frozen_string_literal: true

# Changing a plan deals already use. usage says what a change would move; a new
# version is a copy (components included) that takes over on a date, while the
# plan itself ends the day before, so deals already on it keep what they were
# sold under.
class CommissionPlanVersion
  class Refused < StandardError; end

  def self.usage(plan)
    company = plan.company
    deals = company.deals.where(commission_plan_id: plan.id, deleted_at: nil)
    closed = company.won_stage_keys + company.lost_stage_keys
    open_deals = deals.where.not('LOWER(deals.stage) IN (?)', closed.presence || ['__none__'])
    payments = plan.commission_payments.where(is_deleted: [false, nil])
    {
      planId: plan.id,
      openDeals: open_deals.count,
      wonDeals: deals.where('LOWER(deals.stage) IN (?)', company.won_stage_keys.presence || ['__none__']).count,
      unpaidPayments: payments.where(status: %w[pending approved]).count,
      paidPayments: payments.where(status: %w[paid partially_paid]).count
    }
  end

  def initialize(plan)
    @plan = plan
  end

  def start_on(date)
    raise Refused, 'The new version must start after this plan starts' if @plan.effective_date && date <= @plan.effective_date
    raise Refused, 'This plan has already ended' if @plan.expiration_date && date > @plan.expiration_date + 1

    CommissionPlan.transaction do
      copy = @plan.dup
      copy.assign_attributes(effective_date: date, expiration_date: @plan.expiration_date, name: @plan.name)
      copy.save!
      ids = {}
      @plan.commission_components.order(:sequence, :id).each do |component|
        clone = component.dup
        clone.commission_plan_id = copy.id
        clone.save!
        ids[component.id] = clone.id
      end
      fees = copy.metadata.to_h.dig('before_commission', 'fee_component_ids')
      if fees.present?
        meta = copy.metadata.to_h.deep_dup
        meta['before_commission']['fee_component_ids'] = Array(fees).map { |id| ids[id.to_i] }.compact
        meta['previous_version_id'] = @plan.id
        copy.update!(metadata: meta.deep_stringify_keys)
      else
        copy.update!(metadata: copy.metadata.to_h.merge('previous_version_id' => @plan.id).deep_stringify_keys)
      end
      @plan.update!(expiration_date: date - 1)
      copy
    end
  end
end

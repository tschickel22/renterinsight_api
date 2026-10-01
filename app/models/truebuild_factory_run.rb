# frozen_string_literal: true

# A run drawing every price book finish on every model of a factory or series
# (Truebuild::Trueview::FactoryRun). Its drawings carry its id in usage.
#
# running: models are being queued, or their drawings drawn.
# budget_reached: stopped before a model that would have gone over budget.
# stopped: a platform admin stopped it; drawings not yet started were cancelled.
class TruebuildFactoryRun < ApplicationRecord
  STATUSES = %w[running budget_reached stopped].freeze

  belongs_to :manufacturer

  validates :status, inclusion: { in: STATUSES }
  validates :budget_usd, numericality: { greater_than: 0 }

  def renders
    TruebuildRender.where(purpose: 'layer').where("usage->>'factory_run_id' = ?", id.to_s)
  end

  def models_queued = progress['models_queued'].to_i
  def committed_usd = progress['committed_usd'].to_f

  def stop!
    update!(status: 'stopped', stopped_at: Time.current)
    renders.where(status: 'queued').update_all(status: 'cancelled', updated_at: Time.current)
  end
end

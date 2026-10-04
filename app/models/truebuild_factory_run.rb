# frozen_string_literal: true

# A run drawing every price book finish on every model of a factory or series
# (Truebuild::Trueview::FactoryRun). Its drawings carry its id in usage.
#
# scheduled: waiting for scheduled_at; a recurring job starts it.
# running: models are being queued, or their drawings drawn.
# budget_reached: stopped before a model that would have gone over budget.
# stopped: a platform admin stopped it; drawings not yet started were cancelled.
# finished: everything drawn and its repair rounds done.
#
# mode now: one call per drawing, as a buyer's drawings are made.
# mode batch: drawings go to Gemini's batch mode at half price and come back
# within hours (Truebuild::Trueview::Batch).
class TruebuildFactoryRun < ApplicationRecord
  STATUSES = %w[scheduled running budget_reached stopped finished].freeze
  MODES = %w[now batch].freeze

  belongs_to :manufacturer
  belongs_to :created_by, class_name: 'User', optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :mode, inclusion: { in: MODES }
  validates :budget_usd, numericality: { greater_than: 0 }

  scope :due, -> { where(status: 'scheduled').where(scheduled_at: ..Time.current) }

  def renders
    TruebuildRender.where(purpose: 'layer').where("usage->>'factory_run_id' = ?", id.to_s)
  end

  def batch? = mode == 'batch'

  # Everything the run has cost: its drawings and checks, and the outlines
  # made for its photos while it ran. Outlines were left out until run 4
  # (34 of them, $3.17), so a run reported $6.84 and spent about $10.
  def spent_usd
    renders.sum(:cost_usd).to_f + outline_usd
  end

  def outline_usd
    photos = renders.distinct.pluck(:source_url)
    return 0.0 if photos.empty?

    TruebuildSurfaceMask.where(source_url: photos, created_at: created_at..(stopped_at || Time.current))
                        .sum(Arel.sql("COALESCE((usage->>'cost_usd')::numeric, 0)")).to_f
  end
  def models_queued = progress['models_queued'].to_i
  def committed_usd = progress['committed_usd'].to_f

  def stop!
    update!(status: 'stopped', stopped_at: Time.current)
    # Drawings not started yet are not drawn now. Ones already at Google are
    # paid for, so they are still collected and checked (TruebuildFactoryRunTickJob).
    renders.where(status: 'queued').update_all(status: 'cancelled', updated_at: Time.current)
    notify_end
  end

  def continuable? = %w[stopped budget_reached].include?(status)

  # Picks up where the run stopped, with a new budget: the next model, and the
  # drawings it cancelled. Nothing it drew or outlined is paid for again.
  def continue!(budget_usd)
    raise ArgumentError, 'This run cannot be continued' unless continuable?

    spent = spent_usd
    raise ArgumentError, "Set a budget above the #{format('$%.2f', spent)} already spent" unless budget_usd.to_f > spent

    update!(status: 'running', budget_usd: budget_usd, stopped_at: nil)
    renders.where(status: 'cancelled').find_each do |row|
      row.update!(status: 'queued')
      Truebuild::Trueview::FactoryRun.dispatch(row, self)
    end
    TruebuildFactoryRunJob.perform_later(id)
  end

  # Tells the admin who started the run how it ended.
  def notify_end
    return unless created_by

    spent = spent_usd
    counts = renders.group(:status).count
    what = { 'finished' => 'finished', 'stopped' => 'was stopped', 'budget_reached' => 'reached its budget' }[status] || status
    NotificationService.create(
      recipient: created_by, notification_type: :truebuild_factory_run,
      title: "TrueView factory run #{what}",
      message: "#{manufacturer&.name} #{series}".squish + " #{what}: #{counts['done'].to_i} drawn, #{counts['rejected'].to_i} held back, " \
               "#{format('$%.2f', spent)} of #{format('$%.2f', budget_usd)} spent.",
      action_url: '/settings?tab=integrations', action_text: 'Open the runs', company_id: created_by.company_id
    )
  rescue StandardError => e
    Rails.logger.warn("TruebuildFactoryRun #{id} notify_end: #{e.message}")
  end
end

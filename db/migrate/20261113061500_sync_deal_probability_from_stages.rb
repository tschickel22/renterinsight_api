# A deal stores its stage's probability, set only when the stage changes, so a
# stage % edited in Settings, Pipeline (or a remap, which moves deals with
# update_all) left the stored values stale and the forecast read old numbers.
# Saves now resync in the background (DealProbabilitySyncJob); this brings
# every company's existing deals in line once.
#
# Runs inline rather than enqueueing a job: during a release the jobs worker
# may still be on the old code, which has no DealProbabilitySyncJob. No DDL,
# and no single transaction around the loop, so each company's few
# update_all statements commit on their own and hold row locks only briefly.
# Idempotent: only rows whose value differs are written.
class SyncDealProbabilityFromStages < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    Company.find_each do |company|
      company.pipeline_stage_keys.uniq.each do |key|
        prob = company.pipeline_stage_probability(key)
        next if prob.nil?

        Deal.where(company_id: company.id, deleted_at: nil, stage: key)
            .where('probability IS DISTINCT FROM ?', prob)
            .update_all(probability: prob)
      end
    end
  end

  def down; end
end

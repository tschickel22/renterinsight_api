# frozen_string_literal: true

namespace :leads do
  desc 'Copy tags, notes and activities that earlier conversions left on the lead (APPLY=1 writes)'
  task backfill_conversions: :environment do
    result = LeadConversionBackfill.call(apply: ENV['APPLY'] == '1')
    puts result.to_json
  end
end

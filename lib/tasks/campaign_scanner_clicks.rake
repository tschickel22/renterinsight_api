# frozen_string_literal: true

namespace :campaigns do
  # Clears clicks that were email security scanners (see Campaigns::ScannerClick).
  #   bin/rails "campaigns:reclassify_scanner_clicks[42]"         preview one campaign
  #   bin/rails "campaigns:reclassify_scanner_clicks[42,apply]"   change it
  #   bin/rails "campaigns:reclassify_scanner_clicks[all,apply]"  every campaign
  desc 'Un-count campaign clicks that were email security scanners'
  task :reclassify_scanner_clicks, %i[campaign_id mode] => :environment do |_, args|
    sends = CampaignSend.all
    sends = sends.where(campaign_id: args[:campaign_id]) unless args[:campaign_id].to_s == 'all'
    ids = Campaigns::ScannerClick.scanner_only_send_ids(sends)
    puts "#{ids.size} send(s) whose clicks were all one scanner burst"
    if args[:mode] == 'apply'
      puts "Reclassified #{Campaigns::ScannerClick.reclassify!(sends)}"
      CampaignStatsRollupJob.perform_now
      puts 'Campaign stats refreshed'
    else
      puts 'Preview only. Add ,apply to change them.'
    end
  end
end

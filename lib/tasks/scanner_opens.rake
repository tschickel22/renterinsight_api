# frozen_string_literal: true

namespace :scanner_opens do
  # Clears opens that were mail scanners (see ScannerOpen), so "Read", open
  # counts and open rates show only people. Without APPLY=1 it only reports.
  desc 'Report (or with APPLY=1 clear) email opens that were mail scanners'
  task reclassify: :environment do
    ids = ScannerOpen.scanner_event_ids
    comms = CommunicationEvent.where(id: ids).distinct.count(:communication_id)
    puts "Scanner opens: #{ids.size} on #{comms} emails"
    if ENV['APPLY'] == '1'
      puts "Changed: #{ScannerOpen.reclassify!.inspect}"
    else
      puts 'Report only. Run with APPLY=1 to clear them.'
    end
  end
end

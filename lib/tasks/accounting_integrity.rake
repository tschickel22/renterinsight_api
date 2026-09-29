# frozen_string_literal: true

namespace :accounting do
  desc 'Run the accounting integrity check now (read-only; emails the platform if any books need attention)'
  task integrity_check: :environment do
    results = AccountingIntegrityCheckJob.perform_now
    if results.empty?
      puts 'All companies OK'
    else
      results.each do |r|
        puts "#{r[:company_name]} (id #{r[:company_id]})"
        r[:issues].each { |i| puts "  [#{i[:severity]}] #{i[:message]}" }
      end
    end
  end
end

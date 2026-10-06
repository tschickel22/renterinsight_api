# frozen_string_literal: true

namespace :truebuild do
  # Links lot homes whose model text carries a priced model number
  # (Truebuild::HomeMatcher#link_all). DRY_RUN=1 lists without linking;
  # COMPANY_ID limits it to one dealer.
  desc 'Link lot homes to their TrueBuild model by model number'
  task link_homes: :environment do
    scope = Vehicle.where(is_deleted: [false, nil])
    scope = scope.where(company_id: ENV['COMPANY_ID']) if ENV['COMPANY_ID'].present?
    dry = ENV['DRY_RUN'].present?
    linked = Truebuild::HomeMatcher.new.link_all(scope, dry_run: dry)
    linked.each { |id, number| puts "vehicle #{id} -> #{number}" }
    puts "#{dry ? 'Would link' : 'Linked'} #{linked.size} homes"
  end
end

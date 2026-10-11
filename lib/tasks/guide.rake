# frozen_string_literal: true

namespace :guide do
  desc 'Replace the literal platform name in tour and help copy with the {{brand}} token. DRY_RUN=1 to preview.'
  task brand_tokens: :environment do
    dry_run = ENV['DRY_RUN'].present?
    literals = ['Renter Insight', 'RenterInsight']
    targets = {
      Tour               => %i[name description],
      TourStep           => %i[title content],
      Knowledge::Article => %i[title excerpt content content_html]
    }

    targets.each do |klass, columns|
      changed = 0
      klass.find_each do |record|
        updates = columns.each_with_object({}) do |col, h|
          value = record.public_send(col)
          next if value.blank?

          replaced = literals.reduce(value) { |v, lit| v.gsub(lit, Guide::Copy::BRAND_TOKEN) }
          h[col] = replaced unless replaced == value
        end
        next if updates.empty?

        changed += 1
        puts "#{klass.name} ##{record.id}: #{updates.keys.join(', ')}"
        record.update_columns(updates.merge(updated_at: Time.current)) unless dry_run
      end
      puts "#{klass.name}: #{changed} #{dry_run ? 'would change' : 'changed'}"
    end
  end
end

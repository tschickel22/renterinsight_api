# frozen_string_literal: true
# Backfill default project templates for all existing companies that don't have any yet.
# Run with: bin/rails runner "load 'db/seeds/backfill_project_templates.rb'"

puts "🔍 Checking companies for missing project templates..."

seeded = 0
skipped = 0

Company.find_each do |company|
  if company.project_templates.where(is_deleted: [false, nil]).count == 0
    begin
      ProjectTemplate.seed_defaults!(company)
      puts "  ✅ #{company.name} (ID: #{company.id}) — seeded 3 templates"
      seeded += 1
    rescue => e
      puts "  ❌ #{company.name} (ID: #{company.id}) — FAILED: #{e.message}"
    end
  else
    puts "  ⏭  #{company.name} (ID: #{company.id}) — already has templates, skipping"
    skipped += 1
  end
end

puts "\nDone. Seeded: #{seeded}, Skipped: #{skipped}"

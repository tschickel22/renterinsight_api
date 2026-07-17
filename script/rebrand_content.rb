# script/rebrand_content.rb
#
# Substitutes Renter Insight → DealerTide across knowledge base articles
# and campaign templates. Idempotent; safe to run more than once.
#
# Usage (from Render shell or local):
#   bin/rails runner script/rebrand_content.rb           # DRY RUN (safe — no writes)
#   DO_IT=1 bin/rails runner script/rebrand_content.rb   # execute (commits changes)

DO_IT = ENV['DO_IT'] == '1'

# Ordered longest-first so "renterinsight.com" gets swapped before the
# shorter "renterinsight" catches it.
SUBSTITUTIONS = [
  ['renterinsight.com', 'dealertide.com'],
  ['RenterInsight',     'DealerTide'],
  ['Renter Insight',    'DealerTide'],
  ['renterinsight',     'dealertide']
].freeze

def swap(text)
  return text unless text.is_a?(String)
  out = text.dup
  SUBSTITUTIONS.each { |from, to| out.gsub!(from, to) }
  out
end

def swap_deep(value)
  case value
  when String then swap(value)
  when Array  then value.map { |v| swap_deep(v) }
  when Hash   then value.transform_values { |v| swap_deep(v) }
  else             value
  end
end

def compute_changes(record, columns)
  changes = {}
  columns.each do |col|
    before = record[col]
    after  = (before.is_a?(Hash) || before.is_a?(Array)) ? swap_deep(before) : swap(before)
    changes[col] = [before, after] if before != after
  end
  changes.empty? ? nil : changes
end

def print_change(col, before, after)
  if before.is_a?(Hash) || before.is_a?(Array)
    puts "    #{col}: JSONB (recursively substituted, size=#{before.to_json.bytesize} → #{after.to_json.bytesize})"
  else
    b = before.to_s.gsub(/\s+/, ' ')[0, 100]
    a = after.to_s.gsub(/\s+/, ' ')[0, 100]
    puts "    #{col}:"
    puts "      before: #{b}"
    puts "      after:  #{a}"
  end
end

puts '=' * 70
puts 'Rebrand content script'
puts "  Rails env:  #{Rails.env}"
puts "  Database:   #{ActiveRecord::Base.connection_db_config.configuration_hash[:host] || '(local)'}"
puts "  Mode:       #{DO_IT ? 'EXECUTE (WILL SAVE)' : 'DRY RUN (no writes)'}"
puts '  Substitutions:'
SUBSTITUTIONS.each { |f, t| puts "    #{f.inspect} -> #{t.inspect}" }
puts '=' * 70
puts

# ---------- Knowledge::Article ----------
puts 'Knowledge::Article'
puts '-' * 70
kb_updated = 0
kb_cols = %w[title content content_html excerpt]
Knowledge::Article.find_each do |article|
  changes = compute_changes(article, kb_cols)
  next unless changes

  puts "  Article ##{article.id} - #{article.title}"
  changes.each { |col, (b, a)| print_change(col, b, a) }
  if DO_IT
    changes.each { |col, (_, after)| article[col] = after }
    article.save!
    puts '    saved'
  end
  puts
  kb_updated += 1
end
puts "  -> #{kb_updated} article(s) #{DO_IT ? 'updated' : 'would be updated'}"
puts

# ---------- CampaignTemplate ----------
puts 'CampaignTemplate'
puts '-' * 70
ct_updated = 0
ct_cols = %w[name description steps_template]
CampaignTemplate.find_each do |template|
  changes = compute_changes(template, ct_cols)
  next unless changes

  puts "  Template ##{template.id} (company_id=#{template.company_id}) - #{template.name}"
  changes.each { |col, (b, a)| print_change(col, b, a) }
  if DO_IT
    changes.each { |col, (_, after)| template[col] = after }
    template.save!
    puts '    saved'
  end
  puts
  ct_updated += 1
end
puts "  -> #{ct_updated} template(s) #{DO_IT ? 'updated' : 'would be updated'}"
puts

# ---------- Summary ----------
puts '=' * 70
puts 'Summary'
puts '=' * 70
puts "  Knowledge::Article: #{kb_updated}"
puts "  CampaignTemplate:   #{ct_updated}"
puts
if DO_IT
  puts '  Changes SAVED to the database.'
else
  puts '  DRY RUN - no changes saved.'
  puts '  Re-run with DO_IT=1 to commit:'
  puts '    DO_IT=1 bin/rails runner script/rebrand_content.rb'
end
puts '=' * 70

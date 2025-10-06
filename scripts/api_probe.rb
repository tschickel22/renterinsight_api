# frozen_string_literal: true
require "active_record"

def say(t); puts "\e[36m#{t}\e[0m"; end
def ok(t="OK"); puts "\e[32m#{t}\e[0m"; end
def warn(t); puts "\e[33m#{t}\e[0m"; end
def bad(t); puts "\e[31m#{t}\e[0m"; end

def src_for(klass_name, meth)
  k = klass_name.constantize
  if k.instance_methods(false).include?(meth.to_sym)
    loc = k.instance_method(meth.to_sym).source_location
    puts "  #{klass_name}##{meth} -> #{loc.inspect}"
    if loc && File.file?(loc[0])
      file, line = loc
      line = line.to_i
      puts "  --- snippet #{File.basename(file)}:#{line}-#{line+40} ---"
      IO.readlines(file)[(line-1)...(line+40)].each{|l| print "  #{l}"}
      puts "  --- end snippet ---"
    end
  else
    warn "  #{klass_name}##{meth} not defined on this class (maybe inherited?)"
  end
rescue NameError
  bad "  Controller missing: #{klass_name}"
end

def table?(name)
  ActiveRecord::Base.connection.data_source_exists?(name)
end

def columns(name)
  ActiveRecord::Base.connection.columns(name).map(&:name)
rescue
  []
end

say "Controllers & actions"
[
  ["Api::Crm::AiInsightsController", :index],
  ["Api::Crm::AiInsightsController", :generate],
  ["Api::Crm::AiInsightsController", :mark_read],
  ["Api::Crm::RemindersController", :index],
  ["Api::Crm::RemindersController", :create],
  ["Api::Crm::RemindersController", :complete],
  ["Api::Crm::RemindersController", :destroy],
  ["Api::Crm::TagsController", :entity_tags],
  ["Api::Crm::TagsController", :index],
  ["Api::Crm::TagsController", :create],
  ["Api::Crm::TagsController", :assign],
  ["Api::Crm::LeadScoresController", :show],
  ["Api::Crm::LeadScoresController", :calculate],
  ["Api::Crm::CommunicationsController", :index],
  ["Api::Crm::CommunicationsController", :history],
  ["Api::Crm::CommunicationsController", :settings],
].each{|(k,m)| src_for(k,m) }

puts
say "Models present?"
%w[Lead Activity Reminder Tag Tagging LeadScore Communication AiInsight].each do |const|
  begin
    Object.const_get(const)
    puts "  #{const} -> present"
  rescue NameError
    warn  "  #{const} -> MISSING"
  end
end

puts
say "Lead associations?"
lead_assocs = Lead.reflect_on_all_associations.map{|a| [a.macro, a.name]}.to_h { |m,n| [n, m] }
%i[activities reminders tags communications ai_insights].each do |assoc|
  macro = Lead.reflect_on_association(assoc)&.macro
  puts "  Lead.#{assoc} -> #{macro || 'nil'}"
end

puts
say "DB tables & columns (key ones)"
{
  "activities"    => %w[lead_id activity_type description metadata],
  "reminders"     => %w[lead_id title due_at completed_at notes],
  "tags"          => %w[name],
  "taggings"      => %w[tag_id entity_type entity_id],
  "communications"=> %w[lead_id channel direction subject body],
  "ai_insights"   => %w[lead_id content read_at],
  "lead_scores"   => %w[lead_id score reason],
}.each do |tbl, must|
  exists = table?(tbl)
  print "  #{tbl.ljust(16)} -> "
  if !exists
    bad "MISSING"
  else
    cols = columns(tbl)
    missing_cols = must - cols
    if missing_cols.empty?
      ok "present (#{cols.size} cols)"
    else
      warn "present but missing cols: #{missing_cols.inspect}  (has: #{cols.inspect})"
    end
  end
end

puts
say "Routes snapshot (api/crm only)"
puts `bin/rails routes | grep -E 'api/crm'`

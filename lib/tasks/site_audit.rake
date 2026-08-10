# frozen_string_literal: true

# Grade a site we built, published or not.
#
# Websites::SelfAudit renders the pages in process rather than crawling them, so
# this works on a draft that has no live URL and no DNS. It is the same set of
# checks the prospect scan uses, minus the four that come from the React shell,
# which is not ours to render here.
#
#   bin/rails site_audit:list
#   bin/rails "site_audit:run[9]"
#   bin/rails site_audit:all
namespace :site_audit do
  desc 'List the sites that can be graded'
  task list: :environment do
    Website.where(is_deleted: [false, nil]).order(:id).each do |site|
      state = Website.statuses.key(site.status) || site.status
      puts format('%<id>4s  %<state>-11s  %<name>-36s  company %<company>s',
                  id: site.id, state: state, name: site.name.to_s.truncate(34),
                  company: site.company_id)
    end
  end

  desc 'Grade one site by id'
  task :run, [:website_id] => :environment do |_t, args|
    site = Website.find_by(id: args[:website_id])
    abort "No website #{args[:website_id]}. Try: bin/rails site_audit:list" if site.nil?

    report = Websites::SelfAudit.new(website: site).call
    if report.nil?
      puts "#{site.name}: nothing to grade yet, no pages and no listings."
      next
    end

    state = Website.statuses.key(site.status) || site.status
    puts "#{site.name} (#{state})"
    puts "  score #{report['score']} out of 100, #{report['gap_count']} to fix, " \
         "#{report['pages_checked']} pages rendered"
    puts

    report['checks'].each do |check|
      next if check['status'] == 'pass'

      puts "  #{check['status'].upcase.ljust(4)} #{check['label']}"
      puts "       #{check['headline']}"
      puts "       #{check['detail']}" if check['detail'].present?
    end

    passed = report['checks'].select { |c| c['status'] == 'pass' }.map { |c| c['label'] }
    puts
    puts "  PASS #{passed.join(', ')}" if passed.any?
    # Said explicitly, because a check that simply vanished from a report reads
    # as one the site passed.
    puts "  NOT JUDGED HERE (the app shell provides these, and it is fetched at request time): " \
         "#{Websites::SelfAudit::SHELL_DEPENDENT.join(', ')}"
  end

  desc 'Grade every site'
  task all: :environment do
    Website.where(is_deleted: [false, nil]).order(:id).each do |site|
      report = Websites::SelfAudit.new(website: site).call
      next if report.nil?

      state = Website.statuses.key(site.status) || site.status
      worst = report['checks'].reject { |c| c['status'] == 'pass' }.first
      puts format('%<id>4s  %<state>-11s  score %<score>3s  gaps %<gaps>2s  %<name>-32s  %<worst>s',
                  id: site.id, state: state, score: report['score'], gaps: report['gap_count'],
                  name: site.name.to_s.truncate(30),
                  worst: worst ? "worst: #{worst['label']}" : 'nothing to fix')
    end
  end
end

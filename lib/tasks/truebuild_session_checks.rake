# frozen_string_literal: true

# A Claude Code session checking a factory run's drawings (Truebuild::Trueview::SessionChecks).
# Lists and verdicts pass through platform settings, read and written by the session.
namespace :truebuild do
  namespace :session_checks do
    desc 'List drawings waiting on a session check into the session_checks:pending setting'
    task :pending, %i[run_id limit] => :environment do |_, args|
      run = args[:run_id].present? ? TruebuildFactoryRun.find(args[:run_id]) : nil
      list = Truebuild::Trueview::SessionChecks.pending(run, limit: (args[:limit] || 200).to_i)
      Setting.set('platform', nil, 'session_checks:pending', list)
      puts "SESSION_CHECKS pending=#{list.size} waiting=#{Truebuild::Trueview::SessionChecks.waiting(run).count}"
    end

    desc 'Apply the verdicts in the session_checks:verdicts setting ({ id => { score, note } })'
    task apply: :environment do
      verdicts = Setting.get('platform', nil, 'session_checks:verdicts', {})
      tally = Hash.new(0)
      verdicts.each do |id, verdict|
        row = TruebuildRender.find_by(id: id) or next
        Truebuild::Trueview::SessionChecks.apply!(row, verdict)
        tally[row.reload.status] += 1
      end
      Setting.where(scope_type: 'platform', scope_id: nil, key: 'session_checks:verdicts').delete_all
      puts "SESSION_CHECKS applied=#{verdicts.size} #{tally.to_json}"
    end
  end
end

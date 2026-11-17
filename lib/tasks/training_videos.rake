# frozen_string_literal: true

# Intro timings for "Watch all" (it skips each video's intro). Rather than
# scrub every video by hand, guess: the intro ends where the second chapter
# starts. Right when the first chapter is the intro, wrong when it is already
# content, so a guess past MAX_GUESS seconds is reported for a person to set
# in Knowledge admin, Videos, and never written.
#
#   bin/rails training_videos:prefill_intros           # report only
#   bin/rails training_videos:prefill_intros WRITE=1   # save the guesses
#   bin/rails training_videos:intro_report             # what is set now
#
# Outros are not guessed: nothing in the data marks one.
namespace :training_videos do
  MAX_GUESS = 45

  desc 'Guess intro_ends_at from the second chapter (WRITE=1 saves; only fills blanks)'
  task prefill_intros: :environment do
    write = ENV['WRITE'] == '1'
    counts = Hash.new(0)
    TrainingVideo.order(:module_key, :position, :id).find_each do |v|
      label = "##{v.id} #{v.module_key || 'other'} / #{v.title}"
      if v.intro_ends_at.present?
        counts[:already_set] += 1
        next
      end
      second = Array(v.chapters).map { |c| c['start'].to_i }.sort.reject(&:zero?).first
      if second.nil?
        puts "  no guess   #{label}: fewer than two chapters"
        counts[:no_guess] += 1
      elsif second > MAX_GUESS
        puts "  set by hand #{label}: second chapter starts at #{second}s"
        counts[:by_hand] += 1
      else
        puts "  #{write ? 'saved' : 'would save'} #{second}s  #{label}"
        v.update_columns(intro_ends_at: second, updated_at: Time.current) if write
        counts[:guessed] += 1
      end
    end
    puts "\n#{write ? 'Saved' : 'Would save'} #{counts[:guessed]}, set by hand #{counts[:by_hand]}, " \
         "no guess #{counts[:no_guess]}, already set #{counts[:already_set]}."
    puts 'Nothing written. Run again with WRITE=1 to save.' unless write
  end

  desc 'List every video with its intro and outro timings'
  task intro_report: :environment do
    fmt = ->(s) { s.nil? ? '-' : format('%d:%02d', s / 60, s % 60) }
    TrainingVideo.order(:module_key, :position, :id).each do |v|
      puts format('%-6s %-14s intro ends %-6s outro starts %-6s %s',
                  "##{v.id}", v.module_key || 'other', fmt.(v.intro_ends_at), fmt.(v.outro_starts_at), v.title)
    end
  end
end

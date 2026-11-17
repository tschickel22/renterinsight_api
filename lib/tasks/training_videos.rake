# frozen_string_literal: true

# Intro timings for "Watch all" (it skips each video's intro). Rather than
# scrub every video by hand, guess: the intro is the title card before anyone
# speaks, so it ends at the first narration line or the first chapter after
# 0:00, whichever comes first. (Not "the second chapter": our chapters start
# after the title card, so that would skip the whole first chapter.) A guess
# past MAX_GUESS seconds is reported for a person to set in Knowledge admin,
# Videos, and never written.
#
#   bin/rails training_videos:prefill_intros           # report only
#   bin/rails training_videos:prefill_intros WRITE=1   # save the guesses
#   bin/rails training_videos:intro_report             # what is set now
#
# Outros are not guessed: nothing in the data marks one.
namespace :training_videos do
  MAX_GUESS = 45

  # Seconds of the first "m:ss" narration line, and of the first chapter after 0:00.
  def self.intro_guess(video)
    spoken = video.transcript.to_s[/^\s*(\d+):(\d{2})\b/] && (Regexp.last_match(1).to_i * 60) + Regexp.last_match(2).to_i
    chapter = Array(video.chapters).map { |c| c['start'].to_i }.reject(&:zero?).min
    [spoken, chapter].compact.reject(&:zero?).min
  end

  desc 'Guess intro_ends_at from the first narration line or chapter (WRITE=1 saves; only fills blanks)'
  task prefill_intros: :environment do
    write = ENV['WRITE'] == '1'
    counts = Hash.new(0)
    TrainingVideo.order(:module_key, :position, :id).find_each do |v|
      label = "##{v.id} #{v.module_key || 'other'} / #{v.title}"
      if v.intro_ends_at.present?
        counts[:already_set] += 1
        next
      end
      guess = intro_guess(v)
      if guess.nil?
        puts "  no guess   #{label}: no timed narration or chapters"
        counts[:no_guess] += 1
      elsif guess > MAX_GUESS
        puts "  set by hand #{label}: first words or chapter at #{guess}s"
        counts[:by_hand] += 1
      else
        puts "  #{write ? 'saved' : 'would save'} #{guess}s  #{label}"
        v.update_columns(intro_ends_at: guess, updated_at: Time.current) if write
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

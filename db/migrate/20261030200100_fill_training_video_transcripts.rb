# frozen_string_literal: true

# The videos already uploaded get their narration from their captions file,
# so the help assistant can find them. Later uploads fill it on upload.
class FillTrainingVideoTranscripts < ActiveRecord::Migration[8.0]
  def up
    TrainingVideo.reset_column_information
    TrainingVideo.where(transcript: [nil, '']).where.not(captions_url: [nil, '']).find_each do |video|
      video.fill_transcript_from_url!
    end
  end

  def down; end
end

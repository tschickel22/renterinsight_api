# frozen_string_literal: true

# Questions buyers ask Quinn AI (E96), so dealers can add answers it did not
# have and DealerTide can see what buyers ask across dealers.
class CreateAssistantQuestions < ActiveRecord::Migration[8.0]
  def change
    create_table :assistant_questions do |t|
      t.bigint :company_id, null: false
      t.bigint :conversation_id
      t.bigint :communication_id
      t.text :question, null: false
      # answered: from the dealer's facts. unanswered: it did not know.
      # handed_off: a person took it. dismissed: the dealer chose to ignore it.
      t.string :status, null: false, default: 'answered'
      t.string :topic
      t.text :reply
      t.text :dealer_answer
      t.bigint :answered_by_user_id
      t.datetime :answered_at
      t.timestamps
    end
    add_index :assistant_questions, [:company_id, :status, :created_at]
    add_index :assistant_questions, :conversation_id
  end
end

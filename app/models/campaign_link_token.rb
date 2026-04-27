class CampaignLinkToken < ApplicationRecord
  belongs_to :campaign
  belongs_to :campaign_send

  validates :token, :target_url, presence: true
  validates :token, uniqueness: true

  before_validation :generate_token, on: :create

  def record_click!
    now = Time.current
    self.class.where(id: id).update_all(
      'click_count = click_count + 1, ' \
      "first_clicked_at = COALESCE(first_clicked_at, '#{now.utc.iso8601}'), " \
      "last_clicked_at = '#{now.utc.iso8601}'"
    )
  end

  private

  def generate_token
    self.token ||= loop do
      candidate = SecureRandom.urlsafe_base64(12)
      break candidate unless self.class.exists?(token: candidate)
    end
  end
end

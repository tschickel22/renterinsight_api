# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BuyerPortalAccess, type: :model do
  describe 'associations' do
    it { should belong_to(:buyer) }
  end

  describe 'validations' do
    subject { build(:buyer_portal_access) }

    it { should validate_presence_of(:email) }
    it { should validate_uniqueness_of(:email).case_insensitive }
    it { should have_secure_password }

    it 'validates email format' do
      access = build(:buyer_portal_access, email: 'invalid-email')
      expect(access).not_to be_valid
      expect(access.errors[:email]).to include('is invalid')
    end

    it 'downcases email before save' do
      access = create(:buyer_portal_access, email: 'TEST@EXAMPLE.COM')
      expect(access.email).to eq('test@example.com')
    end
  end

  describe '#generate_reset_token' do
    let(:access) { create(:buyer_portal_access) }

    it 'generates a reset token' do
      expect { access.generate_reset_token }.to change { access.reset_token }.from(nil)
    end

    it 'sets reset token expiration to 1 hour from now' do
      access.generate_reset_token
      expect(access.reset_token_expires_at).to be_within(2.seconds).of(1.hour.from_now)
    end

    it 'saves the record' do
      access.generate_reset_token
      access.reload
      expect(access.reset_token).to be_present
    end
  end

  describe '#generate_login_token' do
    let(:access) { create(:buyer_portal_access) }

    it 'generates a login token' do
      expect { access.generate_login_token }.to change { access.login_token }.from(nil)
    end

    it 'sets login token expiration to 15 minutes from now' do
      access.generate_login_token
      expect(access.login_token_expires_at).to be_within(2.seconds).of(15.minutes.from_now)
    end

    it 'saves the record' do
      access.generate_login_token
      access.reload
      expect(access.login_token).to be_present
    end
  end

  describe '#reset_token_valid?' do
    let(:access) { create(:buyer_portal_access) }

    context 'when reset token is valid' do
      before { access.generate_reset_token }

      it 'returns true' do
        expect(access.reset_token_valid?).to be true
      end
    end

    context 'when reset token is expired' do
      before do
        access.generate_reset_token
        access.update!(reset_token_expires_at: 1.hour.ago)
      end

      it 'returns false' do
        expect(access.reset_token_valid?).to be false
      end
    end

    context 'when reset token is not set' do
      it 'returns false' do
        expect(access.reset_token_valid?).to be false
      end
    end
  end

  describe '#login_token_valid?' do
    let(:access) { create(:buyer_portal_access) }

    context 'when login token is valid' do
      before { access.generate_login_token }

      it 'returns true' do
        expect(access.login_token_valid?).to be true
      end
    end

    context 'when login token is expired' do
      before do
        access.generate_login_token
        access.update!(login_token_expires_at: 16.minutes.ago)
      end

      it 'returns false' do
        expect(access.login_token_valid?).to be false
      end
    end

    context 'when login token is not set' do
      it 'returns false' do
        expect(access.login_token_valid?).to be false
      end
    end
  end

  describe '#record_login!' do
    let(:access) { create(:buyer_portal_access) }
    let(:ip_address) { '192.168.1.1' }

    it 'updates last_login_at' do
      access.record_login!(ip_address)
      expect(access.last_login_at).to be_within(2.seconds).of(Time.current)
    end

    it 'increments login_count' do
      expect { access.record_login!(ip_address) }
        .to change { access.login_count }.by(1)
    end

    it 'updates last_login_ip' do
      expect { access.record_login!(ip_address) }
        .to change { access.last_login_ip }.to(ip_address)
    end
  end
end

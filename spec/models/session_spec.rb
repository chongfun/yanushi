require 'rails_helper'

RSpec.describe Session, type: :model do
  describe 'associations' do
    it { should belong_to(:user) }
  end

  describe 'session properties' do
    it 'belongs to a user' do
      user = create(:user)
      session = create(:session, user: user)
      expect(session.user).to eq(user)
    end
  end
end

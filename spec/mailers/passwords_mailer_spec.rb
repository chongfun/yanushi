require 'rails_helper'

RSpec.describe PasswordsMailer, type: :mailer do
  describe 'reset' do
    let(:user) { create(:user) }
    let(:mail) { PasswordsMailer.reset(user) }

    it 'renders the headers' do
      expect(mail.subject).to eq("Reset your password")
      expect(mail.to).to eq([ user.email ])
      expect(mail.from).to eq([ "from@example.com" ])
    end

    it 'renders the body' do
      expect(mail.body.encoded).to match("reset your password")
    end
  end
end

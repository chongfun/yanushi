require "rails_helper"

RSpec.describe User, type: :model do
  describe "associations" do
    it { is_expected.to have_many(:sessions).dependent(:destroy) }
    it { is_expected.to have_many(:properties).dependent(:destroy) }
    it { is_expected.to have_many(:rentable_units).through(:properties) }
    it { is_expected.to have_many(:tenancies).through(:rentable_units) }
    it { is_expected.to have_many(:expenses).through(:properties) }
    it { is_expected.to have_many(:charges).through(:tenancies) }
    it { is_expected.to have_many(:receipts).dependent(:restrict_with_error) }
    it { is_expected.to have_many(:parties).dependent(:destroy) }
    it { is_expected.to have_many(:payment_ingestions).dependent(:destroy) }
    it { is_expected.to have_many(:payment_documents).dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:user) }

    it { is_expected.to validate_presence_of(:email) }
    it { is_expected.to validate_uniqueness_of(:email).case_insensitive }
    it { is_expected.to validate_presence_of(:password_digest) }
  end

  describe "email normalization" do
    it "downcases and strips email" do
      user = User.new(email: " DOWNCASED@EXAMPLE.COM ")
      expect(user.email).to eq("downcased@example.com")
    end
  end

  describe "#accounting_user" do
    it "returns self" do
      user = create(:user)
      expect(user.accounting_user).to eq(user)
    end
  end
end

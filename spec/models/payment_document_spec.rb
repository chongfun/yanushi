require 'rails_helper'

RSpec.describe PaymentDocument, type: :model do
  describe 'associations' do
    it { should belong_to(:user) }
    it { should have_many(:payment_ingestions).dependent(:destroy) }
  end

  describe 'validations' do
    it { should validate_presence_of(:attachment_file) }
    it { should validate_presence_of(:attachment_filename) }
    it { should validate_presence_of(:attachment_content_type) }
    it { should validate_presence_of(:status) }

    context 'with all required fields' do
      it 'is valid' do
        doc = build(:payment_document)
        expect(doc).to be_valid
      end
    end

    context 'without required fields' do
      it 'is invalid' do
        doc = PaymentDocument.new
        expect(doc).not_to be_valid
        expect(doc.errors[:user]).to include("must exist")
        expect(doc.errors[:attachment_file]).to include("can't be blank")
        expect(doc.errors[:attachment_filename]).to include("can't be blank")
        expect(doc.errors[:attachment_content_type]).to include("can't be blank")
      end
    end
  end

  describe 'enums' do
    it { should define_enum_for(:status).with_values(
      processing: "processing",
      success: "success",
      failed: "failed"
    ).backed_by_column_of_type(:string) }
  end
end
